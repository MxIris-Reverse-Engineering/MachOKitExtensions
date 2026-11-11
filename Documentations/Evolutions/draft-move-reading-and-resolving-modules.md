# Draft - 把 MachOReading 与 MachOResolving 迁入本包

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-11
- **最后更新**: 2026-11-11
- **所属愿景**: 无
- **关联提案**: MachOSwiftSection [0018 self-contained-abi-layer](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0018-self-contained-abi-layer.md)（定下 `MachOBase` 这一层能看到什么）、[0057 reading-context-migration](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0057-reading-context-migration.md)（废弃读取写法的删除计划）、[0075 wrapped-reader-recognition](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0075-wrapped-reader-recognition.md)（`MachOReaderWrapper` 放进本包）；MachOObjCSection [0001 objc-rendering-and-indexing-downstreaming](https://github.com/MxIris-Reverse-Engineering/MachOObjCSection/blob/main/Documentations/Evolutions/0001-objc-rendering-and-indexing-downstreaming.md)（本包的来历，当时决定不抽这一栈）；本包 [0001 cached-view](0001-cached-view.md)（用大版本号挡住旧下游的先例）
- **实现分支 / PR**: 四个仓库同名的 `feature/move-reading-and-resolving-modules`（本包、MachOSwiftSection、MachOObjCSection、swift-decompiler），各在自己的 `.worktrees/<项目名>-MoveReadingAndResolvingModules`
- **配套文档**: 待定 —— 落地时登记从 MachOSwiftSection 搬来的实现说明 `Internal/ReadingContextAbstraction.md`

## 摘要

把 MachOSwiftSection 的 `MachOReading`（`Readable`、`ReadingContext`、`MachOContext`、`InProcessContext` 与文件映射）和 `MachOResolving`（`Resolvable`、`SymbolOrElement`、`Symbol`、`Symbols`）原名迁进本包，作为两个独立模块，各带一个同名 library product；`MachOKitExtensions` 模块本身不变。本包为此发 2.0.0：不删任何东西，大版本号只用来防止「旧版 MachOSwiftSection 自带的同名模块」和新版本包被一起解析。迁移与 MachOSwiftSection 删除已废弃的读取写法放在同一个版本，废弃写法不进本包。目的是让不依赖 MachOSwiftSection 的包——首先是关掉 SwiftSection trait 的 MachOKitUI——也能用这套读取层。

## 动机

- **MachOKitUI 关掉 SwiftSection trait 时拿不到读取层。** MachOKitUI 把 MachOSwiftSection 做成可选 trait（`SwiftSection`）。关掉它时，`MachOKitUICore` 仍依赖 MachOKit 与本包，但 `Readable`、`ReadingContext` 只在 MachOSwiftSection 里。它对 `MachOFileSource` / `MachOImageSource` 的 `Readable` 转发因此整段包在 `#if SwiftSection` 里（MachOKitUI `Sources/MachOKitUICore/Core/MachOFileSource+Traits.swift:22`、`:66-124`）。
- **trait 之外已经长出了第二份读取代码。** `DyldCacheByteResolver` 按虚拟地址找到 dyld cache 的哪个子文件，并懒映射每个子文件一次（`Core/DyldCacheByteResolver.swift`）；`MachOByteFile` 自己映射文件；section 里的指针与字面量从 `Data` 手工解码（`Builder/MachOSectionContentBuilder.swift:489`、`:547`、`:601`）。这和 `MachOReading` 的文件映射加本包的子 cache 查表做的是同一件事，修一处要记得修另一处。
- **读取层本来就站在本包上，边界却把它切成两半。** `ReadingContext` 的要求用到的 `RuntimeProtocol`、`LocatableLayoutWrapper`、`MachOBindRebaseResolving`、`MachOTargetIdentifier`、`MachOReaderWrapper` 都在本包。两包之间还有一条只写在注释里的约定：`DyldCache.fileIO` 按子 cache 实例缓存映射，靠的是本包每次交回同一个子 cache 实例（MachOSwiftSection `Package.swift` 里对本包 1.1.1 的说明）。
- **当初不抽的理由已经变了。** MachOObjCSection 0001 抽出本包时决定不抽这一栈，理由是「本轮用不到，且 MachOSwiftSection 伤面过大」。现在有了用得到的一方；伤面见下文，MachOSwiftSection 的源码基本不用改。

## 前期调研

下面「要搬的代码」一段是调研时 MachOSwiftSection 0.24.0 的情况；实际搬的 `next` 已有变化，见决策日志 2026-11-11「读取层以 `next` 为准」。

**要搬的代码**

- MachOSwiftSection 的 `Sources/MachO/MachOReading`（14 个文件）与 `Sources/MachO/MachOResolving`（6 个文件），共约 2,100 行，在其 `Package.swift:367-386` 声明。`MachOReading` 依赖 MachOKit、本包、`Utilities`（MachOSwiftSection 内部 target）与 FileIO；`MachOResolving` 依赖 MachOKit、本包与 `MachOReading`。
- 对 `Utilities` 与 FrameworkToolbox 的实际用量很小：
  - `@Mutex` 与 `withLockUnchecked`：`MachOReading/Extensions/MachOFile+.swift:16`、`DyldCache+.swift:19`，各保护一次文件句柄与映射的创建。
  - `box.bitPattern.int`：`MachOReading/Readable/UnsafeRawPointer+Readable.swift:66`、`:74`。
  - 会抛错的 `UnsafeRawPointer(bitPattern:)`（`Utilities/ThrowingBitPatternInitializers.swift`）：只有 `MachOReading/ReadingContext/InProcessContext.swift` 用，3 处。
- FrameworkToolbox 的 platforms 只列 Apple 平台，MachOObjCSection 0001 当年因此把它从本包去掉（该提案 2026-08-10 的决策日志）。本包 README 承诺支持 Linux。
- FileIO 已经在本包的依赖图里：MachOKit 依赖它（`from: "0.13.0"`），本包 `Package.resolved` 锁在 0.14.0。
- `MachOImage.current()` 只在 Darwin 上有（MachOKit `Sources/MachOKit/MachOImage+static.swift:11` 的 `#if canImport(Darwin)`），`InProcessContext` 用它算地址掩码。
- `package` 级声明：`Symbols.init(offset:symbols:)` 被留在 MachOSwiftSection 的 `MachOSymbols` 调用（`Sources/MachO/MachOSymbols/SymbolIndexStore.swift:1391`），跨包后必须公开；`DataSequence` / `MemorySequence` 只在 `MachOReading` 内部用；`asMachOWrapper(in:)` 没有任何调用方。
- 抛错类型：改用本包已有的 `init(nonZeroBitPattern:)` 后，空地址抛 `NullPointerError` 而不是 `UnsafeRawPointer.Error.initFailed`。MachOSwiftSection 的源码与测试里没有按这个类型匹配的代码。

**同名模块**

- SwiftPM 把依赖图里所有包的所有模块名放进一个集合，重名就报错，不管那个模块有没有被用到（swiftpm `Sources/PackageGraph/ModulesGraph+Loading.swift:664-672`，报错在 `:802-869`）。所以本包一旦带上 `MachOReading`，只要它和 0.24.x 及更早的 MachOSwiftSection 出现在同一张图里，解析就失败。
- 本机检出的仓库里，直接依赖本包的只有三个：MachOSwiftSection（`from: "1.3.0"`）、MachOObjCSection（`from: "1.2.0"`）、MachOKitUI（`from: "1.3.0"`）。RuntimeViewer 与 swift-decompiler 经 MachOSwiftSection 间接依赖。三者的范围都止于 2.0.0 之前。
- 先例：本包 1.0.0 删掉公开的抛错版初始化方法时，就用大版本号挡住旧下游（本包 0001）。

**废弃写法**

- `MachOResolving` 带着 MachOSwiftSection 0.22.0 起废弃的写法：`Resolvable` 及其约束扩展上的 `resolve(from:in:)` 与 `resolve(from:)`，`SymbolOrElement` 上的同名写法，以及整个 `AsyncResolvable`。0057 计划在 0.25.0 删除，已经两次推迟。`MachOReading` 里没有废弃写法。
- MachOSwiftSection 2026-10-26 的记录里，还没迁的下游只有 MachOKitUI 与 swift-decompiler。MachOKitUI 的 `main` 现已改用 `ReadingContext`；swift-decompiler 跟 MachOSwiftSection 的 `next` 分支，它的 `main`（`0e186ec`）还有 7 行旧写法，在 `Sources/Decompiler/SwiftMetadata/SwiftCallResultLayout.swift:147` 与 `SwiftMetadataProvider.swift:384-717`。

**测试**

- `Tests/MachOSwiftSectionTests/ConcurrentFileMappingTests.swift` 只测 `MachOReading` 的文件句柄与映射在并发首读下只建一次，样本用 MachOSwiftSection 的 `SymbolTestsCore` 与本机 dyld cache。任何 Mach-O 文件都能替代前者，本包测试已经用 `/usr/bin/curl` 当样本（`Tests/MachOKitExtensionsTests/Support/ChainedFixupsFixture.swift:11`）。
- `Tests/SwiftInterfaceTests/ReaderKindCastScanTests.swift` 扫描 MachOSwiftSection 的 `Sources/`，禁止 `as? MachOImage` 一类写死读取器类型的判断（0075）。模块搬走后，它就扫不到这两个模块了。
- 其余碰到 `MachOContext` / `InProcessContext` 的测试都靠 MachOSwiftSection 的样本或上层模块，留在原处。

**其它**

- 2026-08-11 到 2026-11-11 之间有 10 个提交改过这两个模块（缓存范围、并发首读、包装读取器等）。搬过来以后，这类改动要先在本包发版，MachOSwiftSection 才能用上。
- MachOSwiftSection 规定，改到读取器一层的大重构必须做渲染 A/B：三条读取路径的 `dump` 与 `interface` 输出逐字节一致（其 `Documentations/Internal/SystemFrameworkRenderingVerification.md`）。
- 本机没有装 Linux 的 Swift SDK（`swift sdk list` 为空），Linux 能否编译这次验证不了（未验证）。

## 提议方案

1. 本包新增 `MachOReading`、`MachOResolving` 两个 target，各带一个同名 library product；`MachOKitExtensions` 模块只把 internal 的 `init(nonZeroBitPattern:)` 提为 `package`，对外一行不改。
2. 搬来的代码只做为了在本包编译而必须做的修改：
   - 锁换成本包惯用的 `NSLock`；
   - `box.bitPattern.int` 换成标准库的 `Int(bitPattern:)`；
   - `InProcessContext` 改用本包已有的 `init(nonZeroBitPattern:)`，该初始化方法从 internal 提为 `package`；
   - `InProcessContext` 只在 Darwin 上编译；
   - `Symbols.init(offset:symbols:)` 改为 `public`。

   之后另起一个提交，把单字母泛型参数改成全名。
3. 本包发 2.0.0，只新增、不删除。
4. MachOObjCSection 把对本包的范围放宽到 `"1.2.0"..<"3.0.0"` 并打 tag，代码不动。
5. MachOSwiftSection 删掉自己的两个 target，改依赖本包的同名 product，下限提到 2.0.0。`MachOBase` 的再导出不变，源码里的 `import MachOReading` / `import MachOResolving` 不变。这一步与删除废弃写法放在 MachOSwiftSection 的同一个版本（原定 0.25.0），前提是 swift-decompiler 先迁完。
6. 测试与文档跟着代码走：`ConcurrentFileMappingTests` 搬来并换样本；本包补一份读取器类型扫描；读取层的实现说明搬来，MachOSwiftSection 只留 ABI 层怎么用它。
7. 本包合入 `main` 并打 2.0.0 的同一天，MachOSwiftSection 的 `next` 切过去。

### 非目标

- MachOKitUI 怎么用这两个模块（升级依赖、去掉 trait 门、换掉自己的读取代码）：另写 MachOKitUI 的提案。
- 不搬 `MachOPointers`、`MachOSymbols`、`MachODependencies`、`MachOCaches`、`Utilities`。
- 不改两个模块的 API 与行为。例外只有两处：`Symbols.init` 公开；`InProcessContext` 在 Linux 上不提供（这两个模块以前在 Linux 上根本不存在）。
- 不把 MachOObjCSection 自己的读取代码换成这一套：它是上游 fork，改那些文件会让每次合并上游都冲突。
- 不加 Linux CI。
- 废弃写法不进本包。

## 详细设计

### 本包的 `Package.swift`

```swift
products: [
    .library(name: "MachOKitExtensions", targets: ["MachOKitExtensions"]),
    .library(name: "MachOReading", targets: ["MachOReading"]),
    .library(name: "MachOResolving", targets: ["MachOResolving"]),
],
dependencies: [
    // MachOKit: `from: "0.55.102"`, the first release with `fileBytes`.
    // AssociatedObject unchanged.
    .package(url: "https://github.com/p-x9/swift-fileio.git", from: "0.13.0"),
],
targets: [
    // MachOKitExtensions and MachOKitExtensionsTests unchanged.
    .target(
        name: "MachOReading",
        dependencies: [
            "MachOKit",
            "MachOKitExtensions",
            .product(name: "FileIO", package: "swift-fileio"),
        ]
    ),
    .target(
        name: "MachOResolving",
        dependencies: [
            "MachOKit",
            "MachOKitExtensions",
            "MachOReading",
        ]
    ),
    .testTarget(
        name: "MachOReadingTests",
        dependencies: [
            "MachOReading",
            "MachOKitExtensions",
            "MachOKit",
        ]
    ),
]
```

FileIO 的下限与 MachOKit 一致，不额外收窄。源码沿用 SwiftPM 的默认布局：`Sources/MachOReading/`、`Sources/MachOResolving/`，子目录（`Extensions`、`Models`、`Readable`、`ReadingContext`）保持原样。

### 搬的是哪个版本

搬的是 MachOSwiftSection 按 0057 删掉废弃写法之后的 `next`。所以 `AsyncResolvable.swift` 不搬，`Resolvable.swift`、`SymbolOrElement.swift` 里的 `resolve(from:…)` 也不在其中。

### 代码改动（第二个提交）

| 文件 | 改动 |
|---|---|
| `Package.swift` | 两个 target 与同名 product；swift-fileio 依赖；MachOKit 下限从 0.54.101 提到 0.55.102（`fileBytes`） |
| `MachOReading/Extensions/FileHandle+.swift` | `FileHandle` 遵循 `MachONamespacing` 去掉 `@retroactive`：协议在本包声明 |
| `MachOReading/Readable/UnsafeRawPointer+Readable.swift` | `box.bitPattern.int` 换成 `Int(bitPattern: self)`；去掉 `import FoundationToolbox` |
| `MachOReading/ReadingContext/InProcessContext.swift` | 整个文件包进 `#if canImport(Darwin)`；`try UnsafeRawPointer(bitPattern:)` 换成 `try UnsafeRawPointer(nonZeroBitPattern:)`；去掉 `import Utilities`；`addressMask` 从 `package` 改为 `public` |
| `MachOKitExtensions/UnsafeRawPointer+.swift` | `init(nonZeroBitPattern:)` 的两个重载从 internal 提为 `package`，仍不对外公开 |
| `MachOResolving/Symbols.swift` | `init(offset:symbols:)` 从 `package` 改为 `public` |
| `MachOResolving/Resolvable.swift` | `asMachOWrapper(in:)` 里的 `machO.ptr.bitPattern.uint` 换成 `UInt(bitPattern: machO.ptr)`，访问级别保持 `package` |

跨包以后，MachOSwiftSection 的同包传递可见性会断开（MachOObjCSection 0001 抽本包时遇到过同样的事）。其余因此编译不过的地方，一律换成标准库或本包已有的写法，并在提交说明里逐条列出。`package` 在本包的模块之间仍然有效，所以 `DataSequence`、`MemorySequence` 保持 `package`。

第三个提交只改单字母泛型参数的名字（`readElement<T>` → `readElement<Element>`、`SymbolOrElement.map<T, E>` → `map<TransformedElement, Failure>` 之类），调用方的写法不受影响。

### MachOSwiftSection 的改动

```swift
static let MachOKitExtensions = Package.Dependency.package(
    local: .package(
        path: "../MachOKitExtensions",
        isRelative: true,
    ),
    remote: .package(
        url: "https://github.com/MxIris-Reverse-Engineering/MachOKitExtensions",
        // 2.0.0 is the first release that carries MachOReading and
        // MachOResolving, which used to be targets of this package.
        from: "2.0.0",
    ),
)
```

- 删掉 `Target.MachOReading`、`Target.MachOResolving` 的定义；所有 `.target(.MachOReading)` / `.target(.MachOResolving)` 换成本包的 product（`MachOResolving`、`MachOSymbols`、`MachOPointers`、`MachOBase` 等，实现时以 `grep` 为准）。
- MachOObjCSection 的下限提到放宽了范围的那个 tag：否则图里的旧版 MachOObjCSection 要求本包低于 2.0.0，与 MachOSwiftSection 的 2.0.0 以上冲突，整张图解不出来。
- 源码不动；`Tests/MachOSwiftSectionTests/FileMappingTests.swift` 只留在描述符上限内读 400 个 Swift 镜像的那个测试，其余三个搬到本包。`ReaderKindCastScanTests` 不变，它本来就只扫 MachOSwiftSection 自己的 `Sources/`。

### MachOObjCSection 的改动

```swift
remote: .package(
    url: "https://github.com/MxIris-Reverse-Engineering/MachOKitExtensions",
    // 2.0.0 only adds the MachOReading and MachOResolving modules, which this
    // package does not use, so it builds against either major version.
    "1.2.0"..<"3.0.0"
),
```

原有的注释保留，在后面补上这一段。

### 测试

新 test target `MachOReadingTests`：

- `FileMappingTests`：从 MachOSwiftSection 的同名测试搬来只测读取层的三个——同一个 cache 文件的各个读者共用一份映射、打开后被删除的文件照样读得到、越界读取抛错。本机 cache 的路径改用 MachOKit 的 `DyldCache.host`，整个文件包在 `#if canImport(Darwin)` 里，与本包已有的测试一致。
- `ReaderKindCastScanTests`：照 MachOSwiftSection 的写法，扫本包的 `Sources/MachOReading` 与 `Sources/MachOResolving`，另加一条：一个文件都没扫到时测试失败，免得路径写错后扫描悄悄通过。`Sources/MachOKitExtensions/MachOReaderWrapper.swift` 里的 `asMachOImage` 等取法本身就要做类型转换，不在扫描范围内。

本包已有的 `MachOKitExtensionsTests` 不变。

### 文档

- 本包新建 `Documentations/Internal/ReadingContextAbstraction.md`：从 MachOSwiftSection 的同名文档搬来读取层本身的部分（协议层次、`MachOContext`、`InProcessContext`、缓存范围、`Resolvable`、包装读取器），开头指回本提案，登记进 `Documentations/README.md`。
- MachOSwiftSection 的 `Documentations/Internal/ReadingContextAbstraction.md` 只留 ABI 层怎么用它（`RelativePointerProtocol` 的接入、模型覆盖、单一实现、缓存范围在上层的用法），开头链接到本包那份。
- 本包 README：新增「Products」一节说明三个 product；Usage 改成 `from: "2.0.0"`，补一个经 `ReadingContext` 读取的例子，并说明为什么只新增也要升大版本；Platforms 一段补上 FileIO 依赖与「`InProcessContext` 只在 Darwin 上有」。
- MachOSwiftSection：`AGENTS.md` 的模块层次图与模块说明（这两个模块改为外部依赖）、`Documentations/README.md`、`Glossary.md` 相关词条的链接、`Internal/Modules/README.md`、提案索引的跨仓库行；发版的 Changelog 写明搬迁。

## 替代方案考量

- **维持现状**：MachOKitUI 不开 trait 时继续用自己那套读取代码。否：同一件事两份实现，读取层还被切在两个包里。
- **只迁 `MachOReading`**：迁移不受删除废弃写法的牵制。否：`Resolvable`（按地址读出一个值）与 `SymbolOrElement`（认出绑定到别的镜像的符号）同样是通用读取层，不开 trait 的 MachOKitUI 也用得上；`MachOResolving` 只依赖 `MachOReading` 与本包，分开放没有好处。
- **原名、发 1.4.0**：否：旧版 MachOSwiftSection 的 `from: "1.3.0"` 会解析到 1.4.0，同名模块让 SwiftPM 直接报错。
- **改名、发 1.4.0，MachOSwiftSection 留原名的转发模块**：不用协调别的仓库，切换也平滑。否：同一个模块从此有两个名字，转发模块还得择期删除。
- **并进 `MachOKitExtensions` 模块**：一个 import 就能拿到全部。否：`Symbol`、`Readable` 这类泛名与 FileIO 依赖会带给 MachOObjCSection 等所有下游；而且旧版 MachOSwiftSection 自己的 `ReadingContext` 会和本包的同名类型撞成歧义，照样要升大版本。
- **另起一个仓库放读取层**：否：同名问题一样存在，还多一个要发版的仓库；读取层依赖的协议本来就在本包。
- **先迁，废弃写法留在 MachOSwiftSection、改成对迁走类型的扩展**：不受 swift-decompiler 牵制。否：要多维护一段跨包的转发，还要靠 `DeprecatedReadingFormsTests` 确认重载结果不变。
- **废弃写法跟着搬进本包**：否：以后删掉就是本包的破坏性改动，又要升 3.0.0。
- **`Symbols.init` 用 `@_spi` 挡在公开 API 外**：否：调用方要多记一个 SPI 名字；MachOObjCSection 0001 抽本包时也是把 `package` 直接提为 `public`（53 个符号）。

## 影响

### 源码兼容性（source compatibility）

- **本包现有使用方**：纯新增，`MachOKitExtensions` 模块对外不变。
- **MachOSwiftSection 及其下游**：源码不用改。`import MachOReading` / `import MachOResolving`、类型名、`MachOResolving.Symbol` 这样的限定写法都不变；要改的只有 `Package.swift`（见详细设计）。
- **两处可见变化**：`Symbols.init(offset:symbols:)` 变为公开，是纯新增；Linux 上没有 `InProcessContext`，而这两个模块以前在 Linux 上根本不存在，不算破坏。
- 同一版 MachOSwiftSection 删除废弃写法，是 0057 的破坏性改动，不是本提案引入的。

### ABI 兼容性

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

- **本仓库**：新增两个 target 与一个 test target；`MachOKitExtensions` target 只把 `init(nonZeroBitPattern:)` 提为 `package`。
- **MachOSwiftSection**：`Package.swift`、文档，一个测试文件移走。
- **MachOObjCSection**：只放宽版本范围并打 tag。
- **MachOKitUI**：在它升级依赖之前，解析器会停在 MachOSwiftSection 0.24.x 加本包 1.x，照常编译；升级放进它自己的提案。
- **swift-decompiler**：跟 MachOSwiftSection 的 `next`，要先迁掉 7 行旧写法；之后经 MachOSwiftSection 自动解析到本包 2.0.0。
- **RuntimeViewer**：不直接依赖本包，升级到新版 MachOSwiftSection 时自动拿到 2.0.0。
- **本地联调**：Xcode 工作区（`MxIris-Reverse-Engineering.xcworkspace` 等）与 `USING_LOCAL_DEPENDENCIES=1` 用本地检出，不看版本号。本包已带上两个模块、MachOSwiftSection 还没切换的那段时间里，任何同时用到两者本地检出的构建都会报模块重名，所以两边要同一天切。

### 文档与示例

见详细设计的「文档」一节：本包 README、新的实现说明，MachOSwiftSection 的 `AGENTS.md`、文档索引、术语表链接与 Changelog。

## API 演进与废弃策略

- 本提案不废弃任何 API。0057 的废弃写法在 MachOSwiftSection 里删除，删除与搬迁在同一个版本，不进本包。
- 本包升 2.0.0，尽管只新增：理由同 1.0.0（本包 0001），让写着 `from: "1.x"` 的旧下游不会被解析到带同名模块的版本。MachOObjCSection 不用这两个模块，放宽到 `..<3.0.0` 后两个大版本都能用。
- 以后改这两个模块按本包的 semver 发版；MachOSwiftSection 要用新能力时，先等本包发版（0075 时 MachOSwiftSection 就为等本包 1.3.0 错过了一次发版）。

## 落地步骤

1. **前置**：swift-decompiler 迁掉 7 行废弃写法（属于 0057 的下游迁移）。**已完成**：编译器报出的是两个文件里的 13 处，比按文本搜到的多 3 处 `dumpName(using:in:)`；迁完后没有读取写法的废弃警告，732 个测试通过。
2. **MachOSwiftSection**：按 0057 删除废弃写法，合入 `next`。**已完成删除**（在功能分支上；合入 `next` 留到切换当天）：344 个转发、`AsyncResolvable` 与 `implementationAddress(in: machO)` 旧名；覆盖率登记表去掉 15 个键，基线用 Xcode 26.6 编的样本重新生成。全量测试 2840 个里只有基线上同样失败的 `readersOfOneCacheFileShareOneMapping`（见决策日志）。
3. **本包，提交一**：把两个模块的文件原样复制到 `Sources/MachOReading`、`Sources/MachOResolving`，暂不在 `Package.swift` 声明，构建不受影响。复制后与 MachOSwiftSection `next` 上的原文件做 `diff -r`，应完全一致。**已完成**：复制的是 MachOSwiftSection 功能分支上删去废弃写法之后的版本，`diff -r` 一致。
4. **本包，提交二**：声明 target、product 与 FileIO 依赖，做「代码改动」一节的修改；`swift build` 通过。**已完成**：本地依赖与纯远端依赖（MachOKit 0.55.102、swift-fileio 0.15.1）下都编译通过。
5. **本包，提交三**：单字母泛型参数改为全名，不改任何调用方写法；`swift build` 通过。**已完成**：顺带把两处单字母参数名 `i` 与 `InProcessContext` 的参数名 `ptr` 改成全名，同样只是内部名字。
6. **本包，测试与文档**：建 `MachOReadingTests`（两个测试），跑本包全部测试；搬实现说明，改 README 与索引。**已完成**：`MachOReadingTests` 的 5 个测试与原有的 30 个全部通过；实现说明见 `Internal/ReadingContextAbstraction.md`。
7. **MachOSwiftSection 功能分支**（本地依赖指向本包的功能分支）：删两个 target、改依赖、删 `ConcurrentFileMappingTests.swift`、改文档。跑全部测试（不含 `IntegrationTests`），再做渲染 A/B：以切换前的 `next` 为基线，三条读取路径的输出逐字节一致。
8. **MachOObjCSection**：放宽版本范围，打 tag。**范围已放宽**（功能分支，本地依赖下编译通过）；打 tag 属于发版，留到收尾。
9. **切换当天**：本包合入 `main` 并打 2.0.0；MachOSwiftSection 把下限改为远端 2.0.0 与第 8 步的 tag，合入 `next`；本提案在本包落地编号，MachOSwiftSection 的提案索引加跨仓库行。
10. **MachOSwiftSection 发版**（原定 0.25.0），Changelog 写明搬迁。
11. **后续**：MachOKitUI 的提案。

**收尾时必须判断两件事**（判断结果写进决策日志）：

- **配套文档**：搬来的 `ReadingContextAbstraction.md` 就是实现说明，落地时登记到头部的「配套文档」。
- **新术语**：本包还没有术语表。落地时判断是新建 `Documentations/Glossary.md`，还是链接 MachOSwiftSection 术语表里已有的 `ReadingContext`、reader wrapper 等词条。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-11 | Created as Draft | MachOKitUI 关掉 SwiftSection trait 时也要用读取层，而 `MachOReading` / `MachOResolving` 只在 MachOSwiftSection 里。最初的评估以「没有第二个使用方」为由建议不迁；用户指出 SwiftSection 是可以不装的 trait，评估改为值得迁，按完整档走提案。 |
| 2026-11-11 | 两个模块都迁 | 用户选择。`Resolvable` 与 `SymbolOrElement` 同样是通用读取层；`MachOPointers`、`MachOSymbols` 留在 MachOSwiftSection。否决：只迁 `MachOReading`。 |
| 2026-11-11 | 原名迁入，作为两个独立模块，本包发 2.0.0 | 用户选择。原名让各处 `import` 不变；2.0.0 防止旧版 MachOSwiftSection 与新版本包被一起解析时模块重名。否决：改名并发 1.4.0（一个模块两个名字）、并进 `MachOKitExtensions` 模块（泛名与 FileIO 依赖带给所有下游）、原名发 1.4.0（旧下游直接解析失败）。 |
| 2026-11-11 | 提案放在本仓库 | 用户选择。代码迁到这里，以后维护在这里找；MachOSwiftSection 的提案索引在落地时加一行跨仓库链接。 |
| 2026-11-11 | MachOKitUI 的改造另起提案 | 用户选择。本提案只管迁移本身，外加让各下游照常编译所需的版本号调整。 |
| 2026-11-11 | 与删除废弃写法放在 MachOSwiftSection 的同一版 | 用户选择。废弃写法不进本包；前提是 swift-decompiler 先迁完。否决：先迁、把废弃转发留在 MachOSwiftSection。 |
| 2026-11-11 | 默认做法 | 用户批准：2.0.0 只新增；MachOObjCSection 只放宽范围；锁换成 `NSLock`；`InProcessContext` 只在 Darwin 上提供；`Symbols.init` 公开；先原样搬、再改泛型参数名；搬 `ConcurrentFileMappingTests` 并换样本；补读取器类型扫描；实现说明搬来、两边互链；先给 MachOObjCSection 打 tag 再发本包 2.0.0，MachOSwiftSection 的 `next` 同一天切换；本包维持 Swift 6.2 工具版本，搬来的代码若必须用 6.3 再议。 |
| 2026-11-11 | 抛错版指针初始化方法改用本包已有的 | 写提案时决定：`InProcessContext` 改用本包的 `init(nonZeroBitPattern:)`（提为 `package`），不在 `MachOReading` 里再复制一份。空地址抛出的错误类型随之改变，已核实没有代码按类型匹配它。 |
| 2026-11-11 | 状态 → Accepted | 用户批准。暂不开工；开工时按落地步骤执行，第一步是迁掉 swift-decompiler 的旧读取写法。 |
| 2026-11-11 | 开始实现 | 用户批准开工。四个仓库各建同名功能分支，按落地步骤推进；合入集成分支、打 tag 与发版留到收尾。 |
| 2026-11-11 | MachOSwiftSection 的功能分支从 `origin/next` 切 | 本地 `next` 比远端多 15 个提交：另一个功能（`feature/observable-macro`）在本地合入、还没推送，等用户验收。从本地 `next` 切会把它带进本分支并随推送公开；它不碰这次要改的文件，所以从已发布的 `origin/next` 切。 |
| 2026-11-11 | swift-decompiler 用本地依赖验证 | 只用远端依赖时，它跟踪的 MachOSwiftSection `next` 编不过：`next` 用了 swift-demangling 尚未发版的 `DemangleOptions.useExistentialAny`。这是基线上已有的问题，与本提案无关；按 worktree 规则补齐本地依赖链接后验证。 |
| 2026-11-11 | 读取层以 `next` 为准，与调研时看的 0.24.0 不同 | 调研时读的是 MachOSwiftSection 的 `main`（0.24.0）。`next` 上 0088（machofile-performance）已让 `MachOFile` 的读取直接用 MachOKit 打开文件时做好的映射（MachOKit 0.55.102 起的 `fileBytes`，SPI Support）：带 `@Mutex` 的 `MachOFile+.swift`、`DyldCache+.swift` 与 `FileIO+.swift` 都已删除，`ConcurrentFileMappingTests` 也已删除，换成 `FileMappingTests`。所以「锁换成 `NSLock`」不再需要；本包对 MachOKit 的下限要提到 0.55.102；测试改为搬 `FileMappingTests` 里只测读取层的三个，读整个 cache 的 Swift 镜像、检查描述符上限的那个依赖 MachOSwiftSection，留在原处。 |
| 2026-11-11 | `InProcessContext.addressMask` 也改为 `public` | `next` 上 CrossReferenceAnalysis 用它剥本进程指针的标签位（`StoredPointer.swift`），`AddressMaskScanTests` 还要求剥标签只用它、不写常量。它原是 `package`，跨包后 MachOSwiftSection 看不到，所以和 `Symbols.init` 一样提为公开。 |
| 2026-11-11 | 去掉 `FileHandle` 遵循 `MachONamespacing` 上的 `@retroactive` | `MachONamespacing` 声明在本包，搬进来后遵循方与协议同包，编译器要求去掉。 |
| 2026-11-11 | 删除废弃写法时多删两个登记键与两个测试 | `MetadataWrapper.metadata` 与 `TargetGenericContext.uniqueCurrentRequirementsInProcess` 是名字独一份的指针版写法，删后连键一起消失，MachOSwiftSection 的覆盖率不变式报为多余登记。按它的要求从登记表删去，并删掉对着这两个键的测试：它们测的是替代写法的本进程路径，`asMetadata` 另有自己的测试，顶层类型的 `uniqueCurrentRequirements` 也不读内存。详细记在 0057 的决策日志。 |
| 2026-11-11 | `readersOfOneCacheFileShareOneMapping` 的失败归为基线已有 | MachOSwiftSection 的全量测试里它失败了（跨文件读取拿到的 sub-cache 实例与本次打开的映射不是同一份，跑了 216 秒）；同一批测试在 `origin/next` 的基线检出上也同样失败，所以不是本提案引入的。单独在本包的测试里它通过；用「先打开一次本机 cache 并让它的子 cache 表常驻」的探针也复现不了，原因没查清，列为后续项。 |
| 2026-11-11 | MachOSwiftSection 不再依赖 swift-fileio，`ObjCClass64` 遵循 `Resolvable` 补 `@retroactive` | swift-fileio 原本只有 MachOReading 用，模块搬走后它在 MachOSwiftSection 里没有用处。`ClassHierarchyDumper` 让 MachOObjCSection 的 `ObjCClass64` 遵循 `Resolvable`，协议搬到本包后双方都来自别的包，编译器提示补上 `@retroactive`。 |
| 2026-11-11 | 本地联调要用名字正好是 `MachOKitExtensions` 的真实目录 | SwiftPM 会把本地依赖的路径解析成真实路径，并以真实目录名作为包的身份：直接指向本包的功能 worktree（目录名带后缀）时，`package: "MachOKitExtensions"` 对不上。验证 MachOSwiftSection 时，在 agent 自己的目录里放了从本包与 MachOObjCSection 功能分支导出的同名快照，并临时（不提交）把 MachOSwiftSection 的两条本地依赖指向它们；共享的 `.worktrees/` 链接一律没动。这一条也写进了 MachOSwiftSection 的 `AGENTS.md`。 |
