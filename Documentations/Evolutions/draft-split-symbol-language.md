# Draft - 符号语言的判断归各自的包：本包只认 C 与 C++，Swift 与 Objective-C 在加载时注册

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-19
- **最后更新**: 2026-11-19
- **所属愿景**: 无
- **关联提案**: 本包 [0003 move-macho-infrastructure-modules](0003-move-macho-infrastructure-modules.md)（引入 `SymbolLanguage`、`SymbolTableRouting` 与 C/C++ 符号索引）；C++ 符号的结构化归类（尚未创建，与本提案同随 3.0.0 落地，见决策日志）
- **实现分支 / PR**: 本包、MachOSwiftSection、MachOObjCSection 各一条 `feature/split-symbol-language`，worktree 在各自的 `.worktrees/<项目名>-SplitSymbolLanguage`
- **配套文档**: 待定 —— 落地时登记实现说明（预计改写 [Internal/SymbolIndex.md](../Internal/SymbolIndex.md)）
- **网页版**: 同目录同名的 `.html`

## 摘要

本包的 `SymbolLanguage` 只认 C 与 C++。`.swift` 与 Swift 名字的判断搬到 MachOSwiftSection 的 `SwiftSymbols`，`.objectiveC` 与 Objective-C 名字的判断搬到 MachOObjCSection。`SymbolLanguage` 改成能从外部扩展的字符串类型（照 `Notification.Name`），本包新增进程级的 `SymbolLanguageRegistry`：别的包在自己的镜像被 dyld 加载时，由一个 C target 的 constructor 注册自己的语言和识别闭包。名字的语言按「C++ → 已注册的语言（按注册顺序）→ C」判定。`SymbolIndexStore` 只收 C 与 C++ 的名字；已注册语言的名字只留下偏移作为边界，地址落在别的语言的代码里时 `closestSymbols` 答 `nil`，不再答前面一个不相干的 C 符号。索引建好之后才有新语言注册时，已建的索引作废、下次查询重建。这是破坏性改动，与 C++ 符号的结构化归类一起发本包 3.0.0，MachOSwiftSection 与 MachOObjCSection 同日各发新版。

## 动机

- **本包硬编码了两门不归它管的语言。** `Sources/MachOSymbols/SymbolLanguage.swift:78-115` 按前缀判断 Swift 与 Objective-C。Swift 的前缀表必须和 swift-demangling 的 `isSwiftSymbol` 一致，而本包不依赖 demangler，只能靠 MachOSwiftSection 的 `SymbolTableEquivalenceTests` 跨包钉住（`SymbolLanguage.swift:45-48` 的注释）；Objective-C 运行时符号的前缀（`_OBJC_`、`l_OBJC_`、`_objc_msgSend$`……）属于 MachOObjCSection 的领域。任何一门语言的规则要改，都得改本包、发本包的版本。
- **类型号称可扩展，别的包却扩展不了。** `SymbolLanguage` 用 struct 加静态成员，注释说是为了以后加语言（`SymbolLanguage.swift:11-13`），但内部是私有的 `Kind` 枚举、构造方法也是私有的，别的包造不出新值。能加语言的只有本包自己。
- **用户的决定**：语言的定义和判断归各自的包，本包只处理 C 与 C++。
- **顺带修掉 2.0.0 已有的一个错答。** C/C++ 索引不收 Swift 名字，`closestSymbols` 只在 C/C++ 名字的偏移里找「不大于目标的最后一个」（`Sources/MachOSymbols/SymbolIndexStore.swift` 的 `Storage.closestSymbols`），所以地址落在 Swift 函数里时，它答出前面某个不相干的 C 函数。按本提案把 Objective-C 也排除后，ObjC 方法里的地址同样会错答，所以这次一并给出边界。

## 前期调研

**现状代码**

- `SymbolLanguage`（`Sources/MachOSymbols/SymbolLanguage.swift`）：四个静态成员 `.c`、`.cPlusPlus`、`.objectiveC`、`.swift`；`init(ofSymbolNamed:)` 公开，`init(ofSymbolNameBytes:)` 是 `@_spi(Internals)`；判断只看名字开头几个字节，不认识的算 `.c`。
- `SymbolSweep`（`Sources/MachOSymbols/SymbolSweep.swift:63`、`:101`、`:124`）：三条采集路径（已加载镜像的符号表、其他读取器的符号表、导出表）对每个名字调一次 `SymbolLanguage(ofSymbolNameBytes:)`，把结果交给 routing。
- `SymbolIndexStore` 的 routing `NonSwiftSymbolTableRouting`（`SymbolIndexStore.swift` 末尾）：`.swift` 以外的名字全进一张表，`.byOffsetWithSortedOffsets`，Objective-C 名字当 C 收。
- `SymbolOffsetIndexing`（`Sources/MachOSymbols/SymbolTableRouting.swift:43-75`）：`.nameOnly`、`.byOffset`、`.byOffsetWithSortedOffsets`；struct 加私有枚举，加一档不破坏别人的 `switch`。
- 缓存：`SharedCache.removeAll()`（`Sources/MachOCaches/SharedCache.swift:141`）能一次清掉一个 store 的全部镜像。
- 锁：本包最低 macOS 10.15，`Synchronization.Mutex` 要 macOS 15，本包一律用 `NSLock`（`SharedCache.swift:58`、`SharedCacheRegistry.swift:57` 等）。

**谁在用**（查过各仓库的 `origin/main` 与 `origin/next`）

- MachOSwiftSection：`Sources/Symbols/SwiftSymbols/SwiftSymbolTableRouting.swift:18-21` 用 `language == .swift` 挑出 Swift 名字；测试 `SwiftSymbolTableRoutingTests`、`SymbolTableEquivalenceTests.swift:35` 也用 `.swift`。
- `.objectiveC` 只在本包自己的测试里出现（`SymbolLanguageTests`、`SymbolSweepTests`）。MachOObjCSection 目前不依赖 `MachOSymbols`。
- RuntimeViewer、MachOKitUI、swift-decompiler、REAgent 都没有用 `SymbolLanguage` 或 C/C++ 索引。

**版本约束**

- MachOSwiftSection 0.25.0 对本包是 `from: "2.0.0"`，MachOObjCSection 0.8.207 是 `"2.0.0"..<"3.0.0"`，RuntimeViewer 的 `next` 是 `from: "2.0.0"`。
- MachOSwiftSection 0.25.0 的 Swift 索引靠本包把名字判成 `.swift`。2.x 里一旦不再这样判，它解析到新版本后 Swift 索引会悄悄变空。所以只能发 3.0.0。
- 也不能在本包留一个废弃的 `.swift` 过渡：MachOSwiftSection 要在扩展里声明同名的 `static let swift`，两个同名成员会让 `.swift` 在调用点产生歧义。

**工具链**

- 本包与 MachOObjCSection 的 `swift-tools-version` 是 6.2，MachOSwiftSection 是 6.3。
- SE-0495（`@c`，C 兼容函数）与 SE-0492（`@section` / `@used`）都在 Swift 6.3 实现。6.2 只有下划线版的 `@_cdecl`。
- MachOObjCSection 已有 C target `MachOObjCSectionC`，主模块 `MachOObjCSection` 依赖它（MachOObjCSection `Package.swift:203-216`）。

**原型（2026-11-19，公司那台 Mac Studio，Swift 6.4.2 / Xcode 27.2，macOS 27.2）**

一个独立的小 package，探针程序只依赖注册模块、不引用其中任何符号，打印加载时注册到的名字：

- **C target 的 constructor 调用 Swift 的 `@c` 函数：可行。** `swift build` 的 debug、release，以及 `xcodebuild` 的 Release（Xcode 的构建系统，与 App 链接 package 的方式相同）三种都打印出 `["constructor"]`。Swift target 依赖 C target，C 文件里 `extern` 声明那个 Swift 函数——正是本提案的接线方式。
- **纯 Swift 用 SE-0492 把闭包放进 `__mod_init_func`：链接失败。** `@section("__DATA,__mod_init_func,mod_init_funcs") @used let …: @convention(c) () -> Void = { … }` 报 `ld: fixup error (kind=arm64_adrp_lo12) … ADRP out of range … to 0x00000000`，变量改成 `private` 也一样。推测是新链接器把 `__mod_init_func` 改写成 `__init_offsets`，而编译器给这个全局变量生成的访问器（`…vau`）仍按 ADRP 引用原地址。debug、release 都失败。
- **ObjC 的 `+load`：没有测。** 它要 Objective-C 运行时，而 C constructor 已验证可行，不再需要。
- 原型是用完即弃的独立小包，不在任何仓库里；结论记在这里，代码已删除。

**先例**

- `Notification.Name`、`NSAttributedString.Key`：以 `String` 为 `rawValue` 的 struct，别的模块在扩展里加静态成员。
- `URLProtocol.registerClass(_:)`、App Intents 的 `AppDependencyManager.shared`：进程级注册，之后的所有查询都看到它。
- API Design Guidelines：谓词闭包的参数标签用 `where:`（`first(where:)`、`removeAll(where:)`）。

## 提议方案

1. **`SymbolLanguage` 只保留 C 与 C++，并可从外部扩展。** 改为 `RawRepresentable`，`rawValue` 是给人看的语言名（`"C"`、`"C++"`），`init(rawValue:)` 公开，`description` 即 `rawValue`。删掉 `.objectiveC`、`.swift` 及其前缀判断。
2. **新增 `SymbolLanguageRegistry`。** 带 `.shared` 的 `final class`。`register(_:where:)` 登记一门语言和一个识别闭包；`registeredLanguages` 列出已登记的。名字的语言按顺序判定：本包内置的 C++ 判断 → 已注册的识别闭包（按注册顺序，第一个认领的胜出）→ 都不认领算 `.c`。`SymbolLanguage(ofSymbolNamed:)` 与采集默认用 `.shared`。
3. **采集按注册表判语言，并能只留偏移。** `SymbolSweep` 开始时取一份注册表快照，逐名字判定时不再加锁。`SymbolOffsetIndexing` 新增 `.sortedOffsetsOnly`：这一档的表不存名字、不建行，只留升序去重的规范化偏移。
4. **C/C++ 索引排除已注册的语言，但留边界。** routing 改为两张表：`.c` 与 `.cPlusPlus` 进 `.symbols`（照旧），其余（即已注册的语言）进 `.boundaries`（`.sortedOffsetsOnly`）。`closestSymbols` 同时在两张表的偏移里找；最近的是边界、且比最近的 C/C++ 偏移更靠后时答 `nil`。同一偏移两边都有时，C/C++ 符号胜出。
5. **晚注册时清掉重建。** 注册表每次登记新语言都把「代数」加一，`.shared` 上的登记同时清空 `SymbolIndexStore.shared`。每个镜像的索引记下建它时的代数，查询时代数不符就丢弃重建——这样也覆盖「建索引途中有人注册」的竞态。
6. **MachOSwiftSection**：`SwiftSymbols` 里新增 `SymbolLanguage.swift`、从本包搬来的 Swift 前缀判断，以及一个 `@c` 注册函数；新增 C target `SwiftSymbolsRegistration`，其 constructor 调用该函数，`SwiftSymbols` 依赖它。`SwiftSymbolTableRouting` 直接调用自己的判断，不经注册表。
7. **MachOObjCSection**：`MachOObjCSection` 模块新增 `SymbolLanguage.objectiveC`、从本包搬来的 Objective-C 前缀判断与一个 `@_cdecl` 注册函数，并新增对本包 `MachOSymbols` 的依赖；constructor 放进已有的 C target `MachOObjCSectionC`。工具版本保持 6.2。
8. **发版**：与 C++ 结构化归类（另写一份提案）一起发本包 3.0.0。同一天 MachOObjCSection 发一个要求本包 3.x 的 tag，MachOSwiftSection 发一个新的小版本，RuntimeViewer 的 `next` 把本包下限改为 3.0.0。

### 非目标

- C++ 符号的结构化归类：另写提案，与本提案同日随 3.0.0 落地。
- Objective-C 的符号索引，以及把 MachOObjCSection 的 `ObjCExportIndex` 改为走本包的采集（用户选择这次只搬定义与判断）。
- 改变 `SwiftSymbolIndexStore` 的行为：它收哪些名字、怎么 demangle 都不变。
- 撤销注册：没有使用场景，不提供。
- 本包代替别人注册其他语言（Rust 的 `__R…` 之类）：以后有包需要时由那个包注册。
- 在 Linux（ELF）上验证加载时注册：constructor 在 ELF 上同样有效，但这次只验证 Darwin。

## 改动地图

本包（MachOKitExtensions）：

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `Sources/MachOSymbols/SymbolLanguage.swift` · `SymbolLanguage` | 修改 | 改为 `RawRepresentable`（`String`），公开 `init(rawValue:)`；删 `.objectiveC`、`.swift` 与它们的前缀判断，只留 C++ 判断；`init(ofSymbolNamed:registry:)` 与 SPI 的字节版构造经注册表判定；`description` 返回 `rawValue` | 语言归各自的包；让别的包能造新值 | 1 |
| `Sources/MachOSymbols/SymbolLanguageRegistry.swift` · `SymbolLanguageRegistry` | 新增 | `.shared`、`init()`、`register(_:where:)`、`registeredLanguages`；SPI 的快照与按字节判定；代数；`.shared` 登记时清空 `SymbolIndexStore.shared` | 别的包注册语言的入口 | 1 |
| `Sources/MachOSymbols/SymbolTableRouting.swift` · `SymbolOffsetIndexing` | 修改 | 新增 `.sortedOffsetsOnly`；`SymbolTableRouting` 的文档改为「`language` 由注册表判出」 | 边界只要偏移、不要名字 | 2 |
| `Sources/MachOSymbols/SymbolSweep.swift` · `SymbolSweep`、`TableAccumulator` | 修改 | `init(sweeping:routing:languageRegistry:)`（默认 `.shared`）；开始时取快照；`.sortedOffsetsOnly` 的表跳过建行，只记规范化偏移（调试条目不记） | 采集按注册表判语言；边界表不付名字的内存 | 2 |
| `Sources/MachOSymbols/SymbolIndexStore.swift` · `SymbolIndexStore`、`Storage`、`NonSwiftSymbolTableRouting` | 修改 | routing 改名 `CAndCPlusPlusSymbolTableRouting`，分 `.symbols` 与 `.boundaries` 两张表；`closestSymbols` 遇边界答 `nil`；`Storage` 记代数，`storage(in:)` 代数不符就重建；测试用的 `internal init(languageRegistry:)`；类型与方法的文档注释改为「C 与 C++」 | 排除已注册语言、留边界、晚注册重建 | 3 |
| `Tests/MachOSymbolsTests/SymbolLanguageTests.swift` | 修改 | 删 Swift / ObjC 的期望；用独立注册表实例测注册、顺序、重复注册、内置语言；真实镜像上两种入口一致，只见 C 与 C++ | 新语义 | 1 |
| `Tests/MachOSymbolsTests/SymbolSweepTests.swift` | 修改 | `LanguageRouting` 改用测试里注册的假语言；新增只留偏移的表 | `.objectiveC` 已不在本包 | 2 |
| `Tests/MachOSymbolsTests/SymbolIndexStoreTests.swift` | 修改 | `storeNeverContainsSwiftNames` 改为用独立注册表登记假语言后验证排除；新增边界与重建用例 | 本包测试进程里没有 Swift 注册 | 3 |
| `Tests/MachOKitExtensionsTests/WrappedReaderSymbolIndexTests.swift` | 修改 | 用 `SymbolLanguage(…) == .c` 筛名字的地方按新语义调整（没有注册时 Swift 名字也是 `.c`） | 语义变化 | 3 |
| `Documentations/Internal/SymbolIndex.md` | 修改 | 「语言」一节改为注册表与判定顺序；store 一节改为两张表与边界；测试清单 | 实现说明随代码 | 4 |
| `README.md` | 修改 | `MachOSymbols` 一行与示例：只认 C/C++，Swift、ObjC 由各自的包注册 | 对外说明 | 4 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案 | 索引 | 4 |

MachOSwiftSection（下表路径前缀 `MSS:`）：

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `MSS:Package.swift` · `SwiftSymbols`、`SwiftSymbolsRegistration` | 修改 / 新增 | 新增 C target `SwiftSymbolsRegistration`（`Sources/Symbols/SwiftSymbolsRegistration`）；`SwiftSymbols` 依赖它；本包远端下限改为 3.0.0 | 加载时注册 | 5 |
| `MSS:Sources/Symbols/SwiftSymbolsRegistration/SwiftSymbolsRegistration.c`、`include/SwiftSymbolsRegistration.h` | 新增 | `__attribute__((constructor))` 调用 `swift_symbols_register_symbol_language()` | 同上 | 5 |
| `MSS:Sources/Symbols/SwiftSymbols/SymbolLanguage+Swift.swift` · `SymbolLanguage.swift`、`SwiftSymbolNameRecognition` | 新增 | `.swift`（`rawValue` `"Swift"`）；从本包搬来的 Swift 前缀判断；`@c(swift_symbols_register_symbol_language)` 注册函数 | Swift 的判断归 MachOSwiftSection | 5 |
| `MSS:Sources/Symbols/SwiftSymbols/SwiftSymbolTableRouting.swift` | 修改 | 直接调用 `SwiftSymbolNameRecognition`，不看传入的 `language` | Swift 索引不依赖注册是否发生 | 5 |
| `MSS:Tests/SwiftSymbolsTests/SymbolTableEquivalenceTests.swift` | 修改 | 钉住 `SwiftSymbolNameRecognition` 与 `isSwiftSymbol`、`_symbolic` 前缀判断等价 | 判断搬家，等价测试跟着走 | 5 |
| `MSS:Tests/SwiftSymbolsTests/SwiftSymbolLanguageRegistrationTests.swift` | 新增 | 加载时已注册；本包的 C/C++ 索引在 libswiftCore 上不含 Swift 名字、Swift 函数里的地址答 `nil` | 端到端验证 | 5 |
| `MSS:Documentations/Internal/Modules/SwiftSymbols.md`、术语表 | 修改 | 记下 `.swift` 在这里定义、加载时注册 | 文档随代码 | 5 |

MachOObjCSection（下表路径前缀 `MOS:`）：

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `MOS:Package.swift` · `MachOObjCSection` | 修改 | 新增 `.product(name: "MachOSymbols", package: "MachOKitExtensions")`；本包范围改为 `"3.0.0"..<"4.0.0"` | 扩展 `SymbolLanguage` 并注册 | 6 |
| `MOS:Sources/MachOObjCSectionC/symbol_language_registration.c` | 新增 | constructor 调用 `objc_section_register_symbol_language()` | 加载时注册；复用已被主模块依赖的 C target | 6 |
| `MOS:Sources/MachOObjCSection/SymbolLanguage+ObjectiveC.swift` · `SymbolLanguage.objectiveC`、`ObjectiveCSymbolNameRecognition` | 新增 | `.objectiveC`（`rawValue` `"Objective-C"`）；从本包搬来的前缀判断；`@_cdecl("objc_section_register_symbol_language")` 注册函数 | Objective-C 的判断归 MachOObjCSection | 6 |
| `MOS:Tests/…/ObjectiveCSymbolLanguageTests.swift` | 新增 | 加载时已注册；代表名字的判定；本包的 C/C++ 索引不含 ObjC 名字 | 端到端验证 | 6 |
| MachOObjCSection 的文档 | 修改 | 记下 `.objectiveC` 在这里定义、加载时注册 | 文档随代码 | 6 |

下游（落地当天）：

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| RuntimeViewer `RuntimeViewerCore/Package.swift` 与各 `Package.resolved` | 修改 | 本包远端下限改为 `from: "3.0.0"` | 它跟 MachOSwiftSection 的 `next`，后者会要求 3.x | 7 |

## 架构图

改了什么：

```text
MachOKitExtensions / MachOSymbols
  SymbolLanguage                       ~ RawRepresentable (String), public init(rawValue:)
    static let c, cPlusPlus              (kept, built in)
  - static let objectiveC              -> moved to MachOObjCSection
  - static let swift                   -> moved to MachOSwiftSection (SwiftSymbols)
  + SymbolLanguageRegistry (.shared)     register(_:where:), registeredLanguages
                                         order: C++ (built in) -> registered, in order -> .c
  SymbolOffsetIndexing                 + .sortedOffsetsOnly
  SymbolSweep                          ~ classifies through a registry snapshot
  SymbolIndexStore                     ~ routing: .symbols    <- .c, .cPlusPlus (rows + offsets)
                                       +          .boundaries <- registered languages (offsets only)
                                       ~ closestSymbols -> nil inside another language's code
                                       ~ index rebuilt when the registry generation moved

MachOSwiftSection
  + SwiftSymbolsRegistration (C)       constructor -> swift_symbols_register_symbol_language()
  SwiftSymbols                         -> depends on SwiftSymbolsRegistration
    + SymbolLanguage.swift
    + SwiftSymbolNameRecognition       (prefix rules moved from MachOSymbols)
    + @c registerSwiftSymbolLanguage   -> SymbolLanguageRegistry.shared.register(.swift, where:)
    ~ SwiftSymbolTableRouting          uses SwiftSymbolNameRecognition directly

MachOObjCSection
  ~ MachOObjCSectionC (C)              + constructor -> objc_section_register_symbol_language()
  MachOObjCSection                     + depends on MachOKitExtensions' MachOSymbols
    + SymbolLanguage.objectiveC
    + ObjectiveCSymbolNameRecognition  (prefix rules moved from MachOSymbols)
    + @_cdecl registerObjectiveCSymbolLanguage
```

注册与查询的流程：

```text
dyld loads an image that links SwiftSymbols
 └─ SwiftSymbolsRegistration's constructor
     └─ registerSwiftSymbolLanguage()                      (Swift, @c)
         └─ SymbolLanguageRegistry.shared.register(.swift, where: recognizes)
             ├─ generation += 1
             └─ SymbolIndexStore.shared drops every built index

SymbolIndexStore.shared.closestSymbols(at: offset, in: image)
 └─ storage(in: image)            built with an older generation? drop it, build again
     └─ SymbolSweep(sweeping: image, routing: CAndCPlusPlusSymbolTableRouting)
         └─ for each name: language = C++ ? .cPlusPlus
                                    : first registered recognizer that claims it
                                    ?? .c
             .c, .cPlusPlus     -> .symbols     (rows, offsets)
             any other          -> .boundaries  (offsets only)
 └─ s = last .symbols offset <= target,  b = last .boundaries offset <= target
     b exists and b > s  -> nil       (target lies in another language's code)
     otherwise           -> symbols at s
```

## 详细设计

### 本包：`SymbolLanguage`

```swift
/// The language a symbol name was mangled for, told from the name's leading
/// bytes.
///
/// This package tells C++ (Itanium) names apart and calls every name nobody
/// claims C. Other languages are other packages' to define and recognize:
/// MachOSwiftSection registers `.swift`, MachOObjCSection `.objectiveC`, each
/// when its image loads (see ``SymbolLanguageRegistry``).
public struct SymbolLanguage: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// The language's name as a person reads it — `"C"`, `"C++"`, `"Swift"`.
    /// Two values with the same name are the same language.
    public let rawValue: String

    public init(rawValue: String)

    /// A name no registered language and no C++ mangling claims: plain C,
    /// assembler labels, and anything unrecognized.
    public static let c = SymbolLanguage(rawValue: "C")

    /// An Itanium-mangled name: `__Z…`, or `___Z…` for a block inside a C++
    /// function. Decided before any registered language is asked.
    public static let cPlusPlus = SymbolLanguage(rawValue: "C++")

    public var description: String { rawValue }

    /// The language of `name`, a symbol name as the symbol table spells it
    /// (with the leading underscore C names carry on Darwin), as `registry`
    /// tells languages apart.
    public init(ofSymbolNamed name: String, registry: SymbolLanguageRegistry = .shared)

    /// The same, read in place from a NUL-terminated name.
    @_spi(Internals)
    public init(ofSymbolNameBytes name: UnsafePointer<CChar>, registry: SymbolLanguageRegistry = .shared)
}
```

调用点：

```swift
SymbolLanguage(ofSymbolNamed: "__ZN4llvm5Value4dumpEv")      // .cPlusPlus
SymbolLanguage(ofSymbolNamed: "_malloc")                     // .c
SymbolLanguage(ofSymbolNamed: "$s7SwiftUI4TextVMn")          // .swift when SwiftSymbols is linked, .c otherwise
```

### 本包：`SymbolLanguageRegistry`

```swift
/// The languages other packages taught this package to tell apart.
///
/// A package that owns a language registers it once, when its image loads —
/// a C target's constructor calling into Swift is the way that runs with no
/// caller involved. Every classification after that sees the language, and
/// ``SymbolIndexStore`` leaves its names out.
public final class SymbolLanguageRegistry: Sendable {
    /// The registry every classification and ``SymbolIndexStore/shared`` use.
    public static let shared = SymbolLanguageRegistry()

    /// An empty registry, for classifying apart from the shared one — a test,
    /// say.
    public init()

    /// Teaches the registry `language`: from now on a name `recognizes`
    /// accepts is `language`, unless C++ mangling or a language registered
    /// earlier claims it first.
    ///
    /// `recognizes` gets a NUL-terminated name as the symbol table spells it,
    /// valid only for the call, and is asked once for every name a sweep
    /// files, so it should read no more than the name's leading bytes.
    /// Registering a language a second time keeps the first recognizer.
    /// Registering ``SymbolLanguage/c`` or ``SymbolLanguage/cPlusPlus`` is a
    /// programmer error.
    ///
    /// On the shared registry, every index ``SymbolIndexStore/shared`` built
    /// before is dropped and built again on its next query.
    public func register(
        _ language: SymbolLanguage,
        where recognizes: @escaping @Sendable (UnsafePointer<CChar>) -> Bool
    )

    /// The registered languages, in registration order.
    public var registeredLanguages: [SymbolLanguage] { get }
}
```

- 内部存 `[(SymbolLanguage, recognizer)]` 与 `generation: Int`，由一把 `NSLock` 保护。
- SPI：`snapshot() -> SymbolLanguageClassifier`，一个值类型，持有识别闭包数组的拷贝与当时的代数；`language(ofSymbolNameBytes:)` 先做内置的 C++ 判断，再依次问闭包，都不认领返回 `.c`。采集在开始时取一份，循环里不碰锁。
- 重复注册同一语言时保留第一次的识别器，因为同一个包可能被两个镜像各带一份（静态库进了两个 framework），两次注册的是同一个判断。
- 注册 `.c` 或 `.cPlusPlus` 触发 `precondition`：它们是内置的判定顺序本身，不能被顶替。

### 本包：采集与 `SymbolOffsetIndexing.sortedOffsetsOnly`

```swift
extension SymbolOffsetIndexing {
    /// No rows: only every canonical offset a name is filed under, ascending
    /// and without repeats — ``SweptSymbolTable/sortedCanonicalOffsets`` — so
    /// a store can tell where some other family's symbols begin without
    /// paying for their names.
    public static let sortedOffsetsOnly: SymbolOffsetIndexing
}

extension SymbolSweep {
    public init(
        sweeping machO: some MachORepresentableWithCache,
        routing: Routing,
        languageRegistry: SymbolLanguageRegistry = .shared
    )
}
```

- `.sortedOffsetsOnly` 的表：`symbolTable` 为空、`rowsByOffset` 为空、`hasLocalSymbols` 为 `false`；导出表一路不登记它。调试条目不决定偏移，同样不记。文件的原始符号值（虚拟地址）不进 `sortedCanonicalOffsets`，与现有规则一致。
- 每个名字多一次闭包调用。落地步骤 3 量一次 AppKit 的建索引耗时，与 2.0.0 对比，记进实现说明。

### 本包：`SymbolIndexStore`

```swift
/// Files C and C++ names into one offset-indexed table, and the offsets of
/// every registered language's names into a table of boundaries.
struct CAndCPlusPlusSymbolTableRouting: SymbolTableRouting {
    enum Table: Hashable, Sendable {
        case symbols
        case boundaries
    }

    func table(forSymbolNamed name: UnsafePointer<CChar>, language: SymbolLanguage) -> Table? {
        language == .c || language == .cPlusPlus ? .symbols : .boundaries
    }

    func offsetIndexing(in table: Table) -> SymbolOffsetIndexing {
        switch table {
        case .symbols: .byOffsetWithSortedOffsets
        case .boundaries: .sortedOffsetsOnly
        }
    }

    var mayReferenceStringTablesOfLoadedImages: Bool { false }
}
```

- `closestSymbols(at:in:)`：在 `.symbols` 的偏移里找不大于目标的最后一个 `s`，在 `.boundaries` 里找 `b`。`b` 存在且 `b > s`（或没有 `s`）时答 `nil`，否则答 `s` 处的符号。同一偏移两边都有（别名、相同代码折叠）时答 C/C++ 符号。文档注释写明：`nil` 也可能表示目标落在别的语言的代码里。
- `symbols(for:in:)`、`offset(ofSymbolNamed:in:)`、`containsSymbol(named:in:)`、`isExported(name:in:)` 只看 `.symbols`，已注册语言的名字一律答「没有」。
- `Storage` 记下建它时注册表快照的代数；`storage(in:)` 取到代数不符的旧索引时先 `remove(for:)` 再建。`.shared` 上的注册另外调用 `removeAll()`，立刻释放内存。
- `internal init(languageRegistry:)` 只给测试用，`shared` 用 `.shared`。

### MachOSwiftSection

```swift
// Sources/Symbols/SwiftSymbols/SymbolLanguage+Swift.swift
@_spi(Internals) import MachOSymbols

extension SymbolLanguage {
    /// A Swift-mangled name (`$s`, `_$s`, `$S`, `_$S`, `$e`, `_$e`, `_T0`,
    /// `@__swiftmacro_`) or a name the Swift compiler emits for the linker to
    /// de-duplicate (`_symbolic `, `_default assoc type `). Registered when
    /// the image holding SwiftSymbols loads.
    public static let swift = SymbolLanguage(rawValue: "Swift")
}

/// The prefix rules, which `SymbolTableEquivalenceTests` pins to
/// swift-demangling's `isSwiftSymbol`.
enum SwiftSymbolNameRecognition {
    static func recognizes(_ name: UnsafePointer<CChar>) -> Bool
}

@c(swift_symbols_register_symbol_language)
func registerSwiftSymbolLanguage() {
    SymbolLanguageRegistry.shared.register(.swift, where: SwiftSymbolNameRecognition.recognizes)
}
```

```c
// Sources/Symbols/SwiftSymbolsRegistration/SwiftSymbolsRegistration.c
#include "SwiftSymbolsRegistration.h"

// Defined in SwiftSymbols with `@c`.
extern void swift_symbols_register_symbol_language(void);

__attribute__((constructor))
static void registerSymbolLanguageAtLoad(void) {
    swift_symbols_register_symbol_language();
}
```

- 注册函数用能链接成功的最低访问级别；原型用的是 `public`，实现时先试 `internal`，不行再升，并在实现说明里记下结论。
- `SwiftSymbolTableRouting.table(forSymbolNamed:language:)` 改为 `SwiftSymbolNameRecognition.recognizes(name)`，不看 `language`：Swift 索引不应因为注册没发生（例如某种链接方式漏掉了 constructor）而悄悄变空。

### MachOObjCSection

```swift
// Sources/MachOObjCSection/SymbolLanguage+ObjectiveC.swift
@_spi(Internals) import MachOSymbols

extension SymbolLanguage {
    /// An Objective-C method implementation (`-[…]`, `+[…]`) or a symbol of
    /// the Objective-C runtime (`_OBJC_…`, `__OBJC_…`, `l_OBJC_…`,
    /// `L_OBJC_…`, `_objc_msgSend$…`). Registered when the image holding
    /// MachOObjCSection loads.
    public static let objectiveC = SymbolLanguage(rawValue: "Objective-C")
}

enum ObjectiveCSymbolNameRecognition {
    static func recognizes(_ name: UnsafePointer<CChar>) -> Bool
}

@_cdecl("objc_section_register_symbol_language")
func registerObjectiveCSymbolLanguage() {
    SymbolLanguageRegistry.shared.register(.objectiveC, where: ObjectiveCSymbolNameRecognition.recognizes)
}
```

constructor 写进 `Sources/MachOObjCSectionC/symbol_language_registration.c`，形状与 MachOSwiftSection 的相同。

## 替代方案考量

- **不认识的都算 C**：本包只认 C++，Swift、ObjC 名字也按 C 收进索引。结果确定、不靠注册；但索引会收进别的语言的名字，与「本包只处理 C 与 C++」相悖。用户否决。
- **按 C 语法正面识别**：只收长得像 C 标识符或 Itanium 名字的。不依赖别的包，但边界难划：`_open$NOCANCEL` 这类带 `$` 变体后缀的系统 C 符号、`_OBJC_CLASS_$_…` 这类 ObjC 运行时符号都会判错。用户否决。
- **调用方启动时显式注册**：行为明确，但忘了注册就悄悄判错。否决，改为加载时自动注册。
- **各包在自己入口第一次被用到时注册**：调用方不用管，但只链接了、还没碰过入口时不生效，结果取决于调用顺序。否决。
- **纯 Swift 用 `@section` 写进 `__mod_init_func`**：不需要 C target，但实测链接失败（见前期调研）。否决。
- **ObjC 的 `+load`**：用户提出的另一条路。要 Objective-C 运行时；C constructor 已实测可行，不需要它。
- **晚注册不处理、文档要求先注册**，或**晚注册直接 `precondition` 失败**：前者会留下含有别的语言名字的旧索引，后者在 `dlopen` 插件这类合理场景里崩溃。用户选择清掉重建。
- **被排除的名字完全不收**：最省内存，但 `closestSymbols` 会在 Swift 函数、ObjC 方法里答出不相干的 C 符号。用户选择只留偏移作边界。
- **拆分单独发 3.0.0，C++ 归类以后发 3.1.0**：拆分能早发，但三个仓库短期内要再切一次大版本。用户选择合成一个 3.0.0。
- **本包保留废弃的 `.swift` / `.objectiveC` 过渡一版**：MachOSwiftSection、MachOObjCSection 在扩展里声明同名静态成员后，调用点的 `.swift` 会有歧义。做不到。
- **注册表做成 `SymbolLanguage` 上的静态方法**：调用更短，但测试无法用独立实例，注册一门假语言会影响同进程里并行跑的其他测试。改为带 `.shared` 的类。
- **识别器做成协议（`SymbolLanguageRecognizer`）**：目前只需要「一个名字是不是我的」这一个判断，一个闭包就够；以后真需要更多能力再抽协议。

## 影响

### 源码兼容性（source compatibility）

**有破坏**：

- `SymbolLanguage.swift`、`SymbolLanguage.objectiveC` 不再在 `MachOSymbols` 里。用到它们的代码要多 import 一个模块：

  ```swift
  // Before (2.x)
  import MachOSymbols
  if SymbolLanguage(ofSymbolNamed: name) == .swift { … }

  // After (3.0.0)
  import MachOSymbols
  import SwiftSymbols            // defines .swift and registers it at load
  if SymbolLanguage(ofSymbolNamed: name) == .swift { … }
  ```

- `SymbolLanguage(ofSymbolNamed:)` 的语义：进程里没有链接 SwiftSymbols / MachOObjCSection 时，Swift 与 ObjC 名字判成 `.c`。
- `SymbolIndexStore` 的内容随进程里注册了哪些语言而变：链接了 MachOObjCSection 时不再含 ObjC 名字；没链接 SwiftSymbols 时含有 Swift 名字（例如 MachOKitUI 关掉 SwiftSection trait 的构建）。
- `closestSymbols(at:in:)` 在别的语言的代码里答 `nil`，以前答前面一个 C 符号。
- `SymbolLanguage` 新增 `RawRepresentable` 遵循与 `rawValue`；`description` 的值不变（`"C"`、`"C++"`）。
- SPI：`SymbolSweep.init` 多一个带默认值的参数；`SymbolOffsetIndexing` 多一档。

不能用 `@available(*, deprecated, renamed:)` 过渡，理由见替代方案「本包保留废弃的 `.swift` / `.objectiveC` 过渡一版」。

### ABI 兼容性

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

- **本包内**：`MachOSymbolsTests`、`MachOKitExtensionsTests` 的相关测试改写（见改动地图）。
- **MachOSwiftSection**：`SwiftSymbols` 新增一个 C target 依赖与一个文件，routing 与两个测试改写；本包下限 3.0.0，随之发一个新的小版本。
- **MachOObjCSection**：主模块新增对 `MachOSymbols` 的依赖与一个文件，C target 新增一个文件；本包范围改为 3.x，随之发新 tag。
- **RuntimeViewer**：`next` 跟 MachOSwiftSection 的 `next` 分支，后者一要求本包 3.x，它的 `from: "2.0.0"` 就解析失败。落地当天改为 `from: "3.0.0"` 并更新 `Package.resolved`，编译确认。
- **swift-decompiler**：跟 MachOSwiftSection 的 `next`，不直接依赖本包的这些 API。落地当天编译确认。
- **MachOKitUI**：还停在 MachOSwiftSection 0.24 与本包 1.x，不受影响；它的改造提案采用本包时要知道「关掉 SwiftSection trait 的配置不会注册 Swift」。
- **REAgent**：钉死旧版 MachOSwiftSection，不受影响。

### 文档与示例

- 本包：`README.md` 的 `MachOSymbols` 一行与示例代码；`Documentations/Internal/SymbolIndex.md` 的「语言」与 store 两节、测试清单。
- MachOSwiftSection：`SwiftSymbols` 的模块文档与术语表。
- MachOObjCSection：说明 `.objectiveC` 在这里定义、加载时注册。

## API 演进与废弃策略

- `.objectiveC`、`.swift` 直接从本包删除，不留废弃期（做不到，见上）。
- semver major：本包 3.0.0，与 C++ 结构化归类同一个版本。
- `rawValue` 字符串成为语言的身份：`"Swift"`、`"Objective-C"` 以后改名就是破坏性改动，写进各自的文档注释。
- `SymbolLanguageRegistry.register(_:where:)` 的闭包签名一经发布就改不回来；以后要给识别器加能力，新增一个接收协议的重载，保留闭包版。

## 落地步骤

1. **`SymbolLanguage` 与注册表**（已完成；采集按注册表判语言、store 可指定注册表两项也在这一步，见决策日志） —— 改动地图本包第 1、2、6 行。
   - 行为：`cPlusPlusNamesAreRecognizedWithoutRegistration`
   - 行为：`unclaimedNamesAreC`
   - 行为：`registeredLanguageClaimsTheNamesItRecognizes`
   - 行为：`cPlusPlusIsDecidedBeforeRegisteredRecognizers`
   - 行为：`earlierRegistrationWinsAnOverlap`
   - 行为：`registeringALanguageTwiceKeepsTheFirstRecognizer`
   - 行为：`registeringABuiltInLanguageIsAProgrammerError`（exit test）
   - 行为：`descriptionIsTheRawValue`
   - 行为：`stringAndByteClassificationAgreeOnEveryNameOfARealImage`（未注册时只见 C 与 C++）
2. **采集按注册表判语言，新增只留偏移的一档**（已完成；按注册表判语言已在第 1 步做完） —— 本包第 3、4、7 行。
   - 行为：`sweepClassifiesThroughTheRegistryItIsGiven`
   - 行为：`sortedOffsetsOnlyTableKeepsOffsetsButNoRows`
   - 行为：`sortedOffsetsOnlyTableSkipsDebugEntriesAndRawAddresses`
   - 行为：`sweepFilesEachNameIntoTheTableItsRoutingChooses`（改写后照旧通过）
3. **C/C++ 索引：排除、边界、重建** —— 本包第 5、8、9 行。
   - 行为：`storeLeavesRegisteredLanguagesOut`
   - 行为：`storeFilesUnregisteredLanguagesAsC`
   - 行为：`closestSymbolsAnswersNilInsideAnotherLanguagesCode`
   - 行为：`closestSymbolsPrefersCAtAnOffsetSharedWithABoundary`
   - 行为：`registeringOnTheSharedRegistryDropsBuiltIndexes`
   - 行为：`indexBuiltBeforeARegistrationIsRebuiltOnItsNextQuery`
   - 行为：本包全量测试与 `swift test -c release` 通过；AppKit 建索引耗时与 2.0.0 对比并记录。
4. **本包文档** —— 本包第 10–12 行。
5. **MachOSwiftSection** —— MSS 各行。本地联调照旧：依赖目录必须真叫 `MachOKitExtensions`，设 `USING_LOCAL_DEPENDENCIES=1`。
   - 行为：`swiftLanguageIsRegisteredAtLoad`
   - 行为：`swiftRecognitionMatchesDemanglingIsSwiftSymbol`
   - 行为：`cAndCPlusPlusStoreLeavesSwiftNamesOut`（libswiftCore）
   - 行为：`cAndCPlusPlusStoreAnswersNilInsideASwiftFunction`
   - 行为：`SwiftSymbolTableRoutingTests` 照旧通过
   - 行为：MachOSwiftSection 全量测试（`--skip IntegrationTests`）与 release 配置测试通过；渲染 A/B 与改动前逐字节一致。
6. **MachOObjCSection** —— MOS 各行。
   - 行为：`objectiveCLanguageIsRegisteredAtLoad`
   - 行为：`objectiveCRecognitionClaimsMethodsAndRuntimeSymbols`
   - 行为：`cAndCPlusPlusStoreLeavesObjectiveCNamesOut`
   - 行为：MachOObjCSection 全部测试照旧（已知基线问题除外，见 0002 决策日志 2026-11-12）。
7. **落地（与 C++ 结构化归类同一天，3.0.0）** —— 下游一行。顺序：本包 3.0.0 → MachOObjCSection 新 tag → MachOSwiftSection 新版本 → RuntimeViewer `next` 改下限；swift-decompiler 编译确认；两份提案各自取号、改 Implemented。

**收尾时必须判断两件事**（判断结果写进决策日志）：

- 要不要配套专题文章：计划改写 `Internal/SymbolIndex.md` 作为实现说明。调用方契约（判定顺序、`rawValue` 即身份、`closestSymbols` 的 `nil` 含义、索引内容随注册而变）写进类型的文档注释；是否另写使用指南在收尾时判断。
- 有没有引入新术语：「注册的语言（registered language）」「边界（boundary）」是否进术语表在收尾时判断；本包目前没有术语表。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-19 | Created as Draft | 用户决定：`SymbolLanguage` 的 Swift 与 Objective-C 成员及其判断移到各自的包，本包只处理 C 与 C++，并指出这个类型本就设计成可扩展。这是破坏性 API 改动，按完整档提问三轮、做一次原型后写成本提案。 |
| 2026-11-19 | C/C++ 索引排除别的包注册的语言 | 用户选择。否决：不认识的都算 C（索引会收进 Swift、ObjC 名字）；按 C 语法正面识别（`_open$NOCANCEL`、`_OBJC_CLASS_$_…` 这类边界难划）。 |
| 2026-11-19 | 与 C++ 结构化归类合成一个 3.0.0 | 用户选择。只升一次大版本、三个仓库只切一次。C++ 归类原定 2.1.0、另写提案，现在改为与本提案同日随 3.0.0 落地，仍是另一份提案。否决：拆分单独发 3.0.0。 |
| 2026-11-19 | MachOObjCSection 只接收定义与判断 | 用户选择。否决：顺便把 `ObjCExportIndex` 改为走本包的采集。 |
| 2026-11-19 | 各包在镜像加载时由 C target 的 constructor 注册 | 用户提出两种做法：C target 的 library entry（constructor），或 ObjC 类的 `+load`。提问时给出的其余选项被否决：调用方启动时显式注册（忘了就悄悄判错）、各包在入口第一次被用到时注册（生效时机取决于调用顺序）。 |
| 2026-11-19 | 晚注册时清掉已建的索引并重建 | 用户选择。否决：不处理、文档要求先注册；晚注册直接 `precondition` 失败。 |
| 2026-11-19 | 被排除的名字只留偏移作边界 | 用户选择。地址落在别的语言的代码里时 `closestSymbols` 答 `nil`，不再答前面一个不相干的 C 符号（2.0.0 对 Swift 名字已有这个错答）。否决：完全不收。 |
| 2026-11-19 | 原型：C constructor 可行，Swift `@section` 链接失败 | 为判断「加载时注册」能否不经调用方、在 release 与 Xcode 构建系统下照样生效而做；结果见前期调研。原型是 `/tmp` 下的独立小包、不在任何仓库里，结论记在这里后删除，不另推废弃分支。 |
| 2026-11-19 | 共识确认，开始写提案 | 用户确认上述决策，并接受这些默认做法：用 C constructor 而不用 `+load`；MachOSwiftSection 用 `@c`，MachOObjCSection 保持 6.2 工具版本、用 `@_cdecl`；`SymbolLanguage` 以字符串 `rawValue` 开放构造；先判 C++、再按注册顺序问识别器、都不认领算 C；C++ 归类另写提案、同日落地；原型确认后删除。 |
| 2026-11-19 | 写提案时定下的做法 | 未单独提问、写进简报供用户推翻：注册表是带 `.shared` 的类（测试用独立实例），API 为 `register(_:where:)`；同一语言重复注册保留第一次的识别器；注册 `.c`、`.cPlusPlus` 视为程序员错误；Swift 索引直接用自己的判断、不经注册表；索引记下注册表代数、查询时不符就重建，`.shared` 上注册时另外立即清空；`SymbolOffsetIndexing` 新增 `.sortedOffsetsOnly`；ObjC 的 constructor 放进已有的 `MachOObjCSectionC`。 |
| 2026-11-19 | 状态 → Accepted | 用户批准，开始实现。 |
| 2026-11-19 | 开始实现 | 三个仓库各从 `next` 切 `feature/split-symbol-language`。本包的 `next` 只在公司那台本地、上面还有别的会话未推送的提交，提案提交在 `next` 上但不推送 `next`，随功能分支推到远端。 |
| 2026-11-19 | 「采集按注册表判语言」与「store 可指定注册表」提前到第 1 步 | `SymbolSweepTests` 与普查测试要给采集、store 传入自己的注册表（本包测试进程里没人注册语言，不能动共享注册表），不提前第 1 步就编不过测试。第 2 步只剩 `.sortedOffsetsOnly`。 |
| 2026-11-19 | AppKit 普查改用注册了 Swift 与 ObjC 替身的注册表 | 第 1 步后普查断言「进程内镜像的名字全留在字符串表里」失败：本包测试进程没人注册 Swift，Swift 名字按 C 收进索引，其中只出现在导出表里的名字要复制。这是新设计下的预期行为；普查要量的是生产环境的构成（链接了两个下游、索引只剩 C/C++），所以改用替身注册表。`storeNeverContainsSwiftNames` 改为 `storeFilesUnregisteredLanguagesAsC`：没有注册时 Swift 名字照 C 收。 |
| 2026-11-19 | 只留偏移的表不收导出表；发现导出表一路的切片偏移口径不一致，记为后续项 | 边界偏移只取符号表（导出的符号本来也在符号表里），与提案详细设计一致。实现时曾让导出表也登记边界，`curl` 的测试随即多出一个 278528：导出表一路给文件加的是 `machO.startOffset`，对胖二进制的切片就是切片在胖文件里的起点（`curl` 的 arm64e 切片从 278528 开始），而符号表一路用 `SymbolValueOffsetConverter` 算出的是切片内偏移（`__mh_execute_header` 为 0）。2.0.0 起行模式就是这样，只影响「只在导出表、不在符号表」的名字铸出的新行，一直没暴露。与本提案无关，不在这条分支上改，记为后续项。 |
