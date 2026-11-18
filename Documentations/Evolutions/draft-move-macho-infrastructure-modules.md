# Draft - 把 MachOSwiftSection 剩余的 MachO 基础模块迁入本包，并拆出 C/C++ 符号索引

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-18
- **最后更新**: 2026-11-18
- **所属愿景**: 无
- **关联提案**: 本包 [draft-move-reading-and-resolving-modules](draft-move-reading-and-resolving-modules.md)（前置：先把 `MachOReading` / `MachOResolving` 迁进本包；本提案的功能分支从它的功能分支切出，两者同一天落地）；MachOSwiftSection [0001 symbol-name-offsetization](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0001-symbol-name-offsetization.md)（符号表的紧凑行与零拷贝名字）、[0017 macho-dependencies-module](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0017-macho-dependencies-module.md)、[0018 self-contained-abi-layer](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0018-self-contained-abi-layer.md)（`MachOBase` 这一层能看到什么）、[0053 shared-cache-composition-and-eviction-registry](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0053-shared-cache-composition-and-eviction-registry.md)（`SharedCache` 与驱逐登记）、[0055 group-sources-by-layer](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0055-group-sources-by-layer.md)
- **实现分支 / PR**: 本包与 MachOSwiftSection 各一条 `feature/move-macho-infrastructure-modules`，分别从两边的 `feature/move-reading-and-resolving-modules` 切出，worktree 在各自的 `.worktrees/<项目名>-MoveMachOInfrastructureModules`
- **配套文档**: 待定 —— 落地时登记实现说明的链接（计划见「详细设计 · 文档」）
- **网页版**: 同目录同名的 `.html`

## 摘要

把 MachOSwiftSection 里还剩下的 Mach-O 基础模块迁进本包：`MachOPointers`、`MachOCaches`、`MachODependencies` 原样迁入，`MachOBase`、`MachOFoundation` 两个汇总模块跟着迁入，各带一个同名 library product。`MachOSymbols` 拆成两半：与语言无关的部分（紧凑符号表、按偏移分桶、符号值到偏移的换算、对符号表与导出表的单趟采集、导出信息）以原名迁入本包，并在其上新建一个只收 C、C++、Objective-C 名字的 `SymbolIndexStore`；Swift 部分留在 MachOSwiftSection，模块改名 `SwiftSymbols`，原来的 store 改名 `SwiftSymbolIndexStore`，通过本包的协议钩子 `SymbolTableRouting` 复用同一套采集。`Utilities` 留在 MachOSwiftSection；`MachOMacros` 与测试支撑模块在 MachOSwiftSection 改用 `SwiftSection` 前缀。落地后 MachOSwiftSection 里带 MachO 前缀的模块只剩 ABI 模型 `MachOSwiftSection`（及其 C 部分 `MachOSwiftSectionC`）。随前置提案一起发本包 2.0.0、MachOSwiftSection 0.25.0。C++ 符号的结构化归类不在本提案，放到 2.1.0 另写提案。

## 动机

- **这几个模块本来就与 Swift 无关，却只能经 MachOSwiftSection 拿到。** 核实过 `next` 上每个模块的 import：`MachOPointers`、`MachOCaches`、`MachODependencies`、`MachOBase`、`MachOFoundation` 一行 Swift 元数据或 demangle 代码都没有；`MachOSymbols` 里只有 demangle 与按 Swift 语法归类那一半 import 了 Demangling（见「前期调研」）。它们当初就按「迟早拆出去」的边界写成独立模块，但不装 MachOSwiftSection 就用不到。
- **关掉 SwiftSection trait 的使用方拿不到这些能力。** MachOKitUI 把 MachOSwiftSection 做成可选 trait；关掉时它只依赖 MachOKit 与本包（前置提案的动机一节已有证据）。依赖闭包、跨镜像共享缓存、相对指针这些都与 Swift 无关，却跟着 trait 一起消失。
- **C/C++ 符号的按地址、按名字查找，各下游都在手写。**
  - MachOKitUI `Sources/MachOKitUICore/Model/MachOSymbolLookup.swift:12-64`：按 `n_value` 排序、二分找「不大于目标地址的最后一个符号」，给 Function Starts 每行标符号名。
  - swift-decompiler `Sources/Decompiler/Loader/MachOFunctionLoader.swift:27-255`：遍历 `symbols` 建「`__text` 内地址 → 名字」字典。
  - MachOObjCSection `Sources/ObjCMetadataSource/ObjCExportIndex.swift:37-172`：遍历导出表建 ObjC 类名集合，注释里写明「与 MachOSwiftSection 的 `SymbolIndexStore` 做法相同」。
  - REAgent `Sources/REAgentStaticAnalysis/StaticAnalysisSession.swift:216-275`：每次查询线性扫描整张符号表。
- **现有的 `SymbolIndexStore` 帮不上它们**：它在采集阶段就把非 Swift 名字全部丢掉（`next` 的 `SymbolIndexStore.swift:824`、`:879-880`、`:927`），而且只在 MachOSwiftSection 里。
- **要和前置提案同一个大版本发。** SwiftPM 不允许依赖图里出现同名模块。前置提案已经因为 `MachOReading` / `MachOResolving` 让本包升到 2.0.0；这次迁入的 `MachOBase`、`MachOSymbols` 等也与 0.24.x 及更早的 MachOSwiftSection 重名。放进同一个 2.0.0，只需一次大版本、一次跨仓库切换；之后单独发就得再升 3.0.0。
- **命名规则**：迁移后 MachOSwiftSection 的模块名本身说明层次 —— Mach-O 层的通用基础设施在本包，MachOSwiftSection 里带 MachO 前缀的只有 ABI 模型，其上的模块一律以 Swift 开头。

## 前期调研

以 MachOSwiftSection `next` 检出（`a5d4c2c5`）为准，下文 `MSS:` 指它的仓库根。本包以前置提案的功能分支为准。

**各模块的现状**

- `MSS:Sources/MachO/MachOPointers`：19 个文件、809 行。没有 `package` / `@_spi` 声明。import `MachOKit`、`MachOKitExtensions`、`MachOReading`、`MachOResolving`，外加 `LocatableLayoutWrapper+RelativePointer.swift:1` 的 `import BinaryParseSupport`（只用 `LayoutWrapper`，而 MachOKit 已经在 `Sources/MachOKit/Util/exported.swift:18-19` 再导出它）。`Package.swift:438-448` 声明的 `Utilities` 依赖没有任何文件用到。
- `MSS:Sources/MachO/MachOCaches`：5 个文件、675 行，全部 `@_spi(Internals) public`。
  - `SharedCache.swift:60` 用 FrameworkToolbox 的 `@Mutex`，`:105`、`:135`、`:143`、`:152`、`:160`、`:180`、`:213` 用 `withLockUnchecked`；其余文件用 `NSLock`、`NSCondition`、pthread。
  - `SharedCache.swift:4` 的 `import Utilities` 没用到任何符号。
  - 四个 `package` 成员在模块外有使用者：`SharedCache.init(evictionGroup:follows:registry:)`（`:45`，模块外 25 处构造，分布在 SwiftInspection、SwiftLayout、SwiftObjCInterop、SwiftThunkAnalysis、MachOSymbols、SwiftDeclarationRendering）、`register(_:forKey:)`（`:104`，只有测试）、`resolve(key:build:)`（`:179`，`SymbolicDemangler.swift:1156` 与 `InternedNodeReferenceCache.swift:89`）、`SharedCacheRegistry.init()`（`SharedCacheRegistry.swift:65`，只有测试）。
  - `MSS:Tests/IntegrationTests/SwiftInterface/SwiftInterfaceBuilderTests.swift:14` 写的是 `@_spi(Internals) @testable import MachOCaches`。
- `MSS:Sources/MachO/MachODependencies`：11 个文件、1156 行。只依赖 MachOKit（`DependencyClosure.swift:2` 用 `@_spi(Support)` 取 `_cachedFullCache`）、本包与 Darwin，锁全是 `NSLock`，没有 `package` 声明。
- `MSS:Sources/MachO/MachOBase/Exported.swift`：只有 5 行 `@_exported import`（`MachOKitExtensions`、`MachOReading`、`MachOResolving`、`MachOPointers`、`Utilities`）。ABI 层有 29 个文件用 `@Layout`（`Utilities` 里声明的宏）却没写 `import Utilities`，全靠这条再导出。
- `MSS:Sources/MachO/MachOFoundation/Exported.swift`：再导出 `MachOBase`、`MachODependencies`、`MachOSymbols`。
- `MSS:Sources/Support/Utilities`：迁入的模块一处都不用它（逐个公开名字查过；`MachOCaches` 与 `MachOSymbols` 的 `import Utilities` 都是空 import）。真正的使用者是 Swift 层：`SwiftDump` 21 个文件、`SwiftPrinting` 11 个、`SwiftDeclarationRendering` 8 个等。它的声明大多是 `package` 级别（`asyncMap`、`SubstitutionMap`、`StringBuilder`、抛错版 `init(bitPattern:)`），`ThrowingBitPatternInitializers.swift:3-7` 的注释还记着它们正是为了不再公开才从本包搬出去的；`SubstitutionMap.swift:64`、`:88` 用 FrameworkToolbox 的 `#log`。

**`MachOSymbols` 的拆分点**

- 通用部分：`SymbolTable.swift` 里的 `SymbolRow`、`PackedNameReference`、`SymbolTable`、`SymbolTableBuilder`、`compareSymbolNameBytes`；`SymbolRowBucket.swift`；`SymbolValueOffsetConverter.swift`；`SymbolIndexStore.swift` 里的 `Storage.symbolTable`、`symbolRowsByOffset`、`ExportFacts`（`:180-198`）、`isExported(name:)`、`symbol(atRow:offset:)`，store 上的 `isExported(name:in:)`、`hasExportInformation(in:)`、`containsSymbol(named:in:)`、`offset(ofSymbolNamed:in:)`、`symbols(for:in:)`，以及 `NlistProtocol` 的 `isExternal`、`isLocal`、`isDebuggingEntry`（`:1955-1981`，`package`）。这些只依赖 MachOKit、本包与 `MachOResolving.Symbol`。
- Swift 部分：`DemangledSymbol`、`InternedNodeReferenceCache`、`StructuralNodeReferenceKey`、`SymbolicManglingSymbols`、`LargeStackTaskExecution`、`SymbolIndexStore` 里的成员 / 类型 / thunk / 不透明类型索引、第二段懒构建的 demangle 索引（`:254-340`、`:995-1100`）、`DemanglingWave`、`DependencyValues.symbolIndexStore`（`:1917-1929`）、`Symbol.swift` 的 `resolve(from:in:)`、`resolvesSymbolUsingIndexStore` 与 `demangledNode`、`MachO+Symbol.swift` 的 `symbols(offset:)` 与 `swiftSymbols`。
- 采集函数 `buildSymbolTableStage`（`SymbolIndexStore.swift:743-979`）里每个符号要做的决定：
  1. 名字归哪张表，或者不收：主表收 Swift 名字（mapped 腿 `:824` 按字节判断，泛型腿 `:879` 用 `isSwiftSymbol`），附加表收 `_symbolic ` / `_default assoc type ` 开头的名字（`:849`、`:880`），其余丢掉。
  2. 导入（`N_EXT` 且 `N_UNDF`，即 `isExternal`）一律不收。
  3. 每张表的行是否进按偏移的索引：主表进，附加表不进（`:860-866`）。
  4. 调试条目只占行，不登记偏移（`:826-834`、`:850-857`、`:883-890`）。
  5. 「镜像里有没有本地符号」只看主表里非调试、`isLocal` 的条目，被打包预算拒绝的名字也算（`:835-837`）。
  6. 导出表：只记 Swift 名字（`:927`）；已有行的记位图，没有行但有偏移的铸新行进主表，铸不出或没有偏移的进 name-only 集合。
  7. 「有没有导出信息」看导出表里有没有任何条目，与名字过滤无关（`:925`）。
  8. 冻结后的派生阶段（Swift 侧的懒 demangle 索引）与表外名字的后备（`lateDemangledNode`）是 store 自己的事，不在采集里。
- `SymbolTable` 依赖 `MachOResolving.Symbol`（`init(standaloneSymbol:)` 与 `symbol(atRow:)`），所以必须在前置提案之上做。
- 前缀判断有三份：Demangling 的 `getManglingPrefixLength`（`swift-demangling/Sources/Demangling/Utils/Extensions.swift:12`，前缀 `_T0`、`_$S`、`_$s`、`_$e`、`$S`、`$s`、`$e`、`@__swiftmacro_`）、`MachOSymbols` 的按字节版 `nameBytesHaveSwiftManglingPrefix`（`SymbolTable.swift:391-402`，由 `SymbolTableEquivalenceTests` 钉住与前者等价）、`MachOSwiftSection` 的 `String+.swift:37-51`（由 `ManglingPrefixTests` 钉住）。`_symbolic` 前缀在 `SymbolicManglingSymbols.swift:64-66`。
- 依赖：`@Mutex` 只出现在 Swift 部分（`SymbolIndexStore.swift:249`、`:262`、`:529`，`Symbol.swift:12`，`LargeStackTaskExecution.swift:48`）；`@Loggable(.private)`（`:16`）没有任何日志调用；`MemberwiseInit`、`AsyncAlgorithms` 是空 import；`OrderedCollections` 只在 Swift 部分用；`Dependencies` 只用于 `DependencyValues` 键。通用部分一个都不用。
- 零拷贝名字的卸载前提：`SymbolTable.swift:95-106` 的注释写明 mapped 行指向已加载镜像的字符串表，镜像卸载就悬空；成立的理由是「dyld 把带 Swift / ObjC 内容的镜像钉住不卸载，会卸载的只有纯 C 镜像，而它们没有 Swift 名字、不产生 mapped 行」（MachOSwiftSection `ReviewAdjudications.md` A4，2026-08-09 实测）。C/C++ 索引会收纯 C 镜像的名字，这个前提不再成立。
- 驱逐：`SharedCacheEvictionGroup` 按名字字符串判等（`MSS:Sources/MachO/MachOCaches/SharedCacheEvictionGroup.swift:33-44`）。`.symbolStore` 定义在 `MSS:Sources/MachO/MachOSymbols/SharedCacheEvictionGroup+MachOSymbols.swift:6`，有 7 个缓存 `follows: [.symbolStore]`（`SymbolicManglingIndex.swift:115`、`ObjCClassMethodIndex.swift:49`、`ObjCImplementationClassIndex.swift:40`、`SwiftClassObjectIndex.swift:54`、`ObjCAncestorResolver.swift:236`、`SwiftClassWithoutClassObjectIndex.swift:150`、`ObjCClassHierarchy.swift:194`）。驱逐由 `SwiftDeclarationIndexer` 的 live owner 触发（`SwiftDeclarationIndexer.swift:339`、`:201`）；`SymbolIndexStore.remove(for:)` 在 Sources 里没有调用者，`:705-707` 说它由 indexer 调用的注释已经过时。

**使用面**

- MachOSwiftSection 内 import 计数（文件数）：`MachOBase` 179（ABI 层 178）；`MachOFoundation` 源码 165、测试 277；`MachOCaches` 源码 31、测试 16；`MachODependencies` 源码 10、测试 10；`MachOSymbols` 源码 94、测试 53；`MachOFixtureSupport` 源码 8、测试 307；`MachOTestingSupport` 测试 367。
- `SymbolIndexStore.shared` 在源码里被 SwiftInspection、SwiftDeclaration、SwiftObjCInterop、SwiftDump、SwiftDeclarationRendering 使用，测试里约 110 处；`DependencyValues.symbolIndexStore` 约 30 处。
- C/C++ store 与 Swift store 共有的方法名（`symbols(for:in:)`、`isExported(name:in:)`、`containsSymbol(named:in:)`、`offset(ofSymbolNamed:in:)`）在 Swift 层有十几处调用。类型若漏改名，这些调用会悄悄编到 C/C++ store 上，返回的是非 Swift 名字而不报错。
- 下游（本机所有兄弟仓库，排除 `.build`、`checkouts`、`.worktrees`）：
  - MachOKitUI `Sources/MachOKitUICore/Builder/MachOSwiftSectionDetailBuilder.swift:9` `import MachOSymbols`，`:23-24` 读写 `MachOResolving.Symbol.resolvesSymbolUsingIndexStore`；整个文件在 `#if SwiftSection` 里。它对 MachOSwiftSection 是 `from: "0.24.0"`、对本包是 `from: "1.3.0"`，在它升级本包到 2.x 之前，SwiftPM 只会给它解析出 0.24.x。
  - RuntimeViewer `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift:9` `import Utilities`，解析到的是 MachOSwiftSection 的 `Utilities`；同模块的 `Utils/ObjCDump+SemanticString.swift:595`、`:619` 用 `offsetEnumerated()`。它能编译，靠的是 `MachOSwiftSection → MachOBase → Utilities` 这条再导出链。
  - swift-decompiler 只 `import MachOSwiftSection` 与 Swift 层模块，经再导出用到 `DependencySearchPath`、`InProcessContext`。REAgent 钉死 MachOSwiftSection 0.15.2。
  - 没有任何下游在 `Package.swift` 里依赖 `MachOBase`、`MachOFoundation`、`MachODependencies` 这三个 product（MachOSwiftSection `Package.swift:1441-1443`）。
  - MachOObjCSection 自己有同名的 public `RelativeDirectPointer`、`RelativeIndirectPointer`、`RelativeRawPointer`（`Sources/MachOObjCSection/Model/Pointer/`），在 `Model/Method/ObjCMethod.swift:96-98`、`:160-162` 不加限定地使用。只要本包的 `MachOKitExtensions` 模块不再导出 `MachOPointers`，就不会歧义。
- 测试：
  - `MSS:Tests/MachOCachesTests` 5 个文件都可迁；其中 `DyldCacheImageSearchTests`、`MachOImageCacheMembershipTests` 测的本来就是本包的行为（MachOSwiftSection `AGENTS.md` 的 MachOKitExtensions 一条列着它们）。
  - `MSS:Tests/MachODependenciesTests` 9 个文件，除 `DependencyClosureTests`（要 dlopen SymbolTestsCore 与它 `@rpath` 下的兄弟框架）外都可迁，要把 SymbolTestsCore / SymbolTestsHelper 样本换成普通 Mach-O（如 `/usr/bin/curl` 的副本），`DyldSharedCachePath` 换成字面路径。
  - `MSS:Tests/MachOSymbolsTests` 里通用的用例：`PackedNameReferenceBudgetTests` 的前半（`:23-50`）、`SymbolTableEquivalenceTests` 的两腿等价与二分查找（`:51`、`:82`）、`SymbolIndexStoreFixtureTests` 的行桶与偏移查询几条、`WrappedReaderSymbolTests`（本包已有 `Tests/MachOKitExtensionsTests/Support/ForwardingReader.swift`）。其余都靠 SymbolTestsCore 或 Swift 名字，留下。
  - `MachOPointers` 没有专属测试；它的覆盖来自 `MSS:Tests/MachOSwiftSectionTests/ReadingContextRelocationTests.swift` 与 `DeprecatedReadingFormsTests.swift`，都经 ABI 类型。
  - `MSS:.github/workflows/macOS.yml:123`、`:148-149` 的 `--filter` 列着要迁走的 suite；`MSS:Tests/MachOTestingSupportTests/ContinuousIntegrationTestFilterTests.swift:15-57` 检查列表里每个 suite 都能在 `Tests/` 找到。本包没有 CI 配置。
  - 写死模块名的地方：`MSS:Sources/TestSupport/MachOFixtureSupport/Baseline/BaselineGenerator.swift:891-892`（生成的 `AllFixtureSuites.swift` 头部）、`MSS:Tests/SwiftInterfaceTests/PrintFailureEventTests.swift:265`（`hostModules`）、`#externalMacro(module: "MachOMacros")` 两处（`Sources/Support/Utilities/Macros/Layout.swift:4`、`Sources/ABI/MachOSwiftSection/Utils/ResolvableLocatableLayoutWrapper.swift:40`）。
- C++ 名字解析器（供 2.1.0）：LLVM 的 `ItaniumDemangle` 正本在 `libcxxabi/src/demangle`（系统 `__cxa_demangle` 就是它），`llvm/include/llvm/Demangle` 是副本。`ItaniumDemangle.h` 6212 行、`ItaniumDemangle.cpp` 608 行，除 C++ 标准库外只 include `DemangleConfig.h`、`StringViewExtras.h`、`Utility.h` 与 `ItaniumNodes.def`；`DemangleConfig.h` 在 libcxxabi 里依赖 `../abort_message.h`、在 LLVM 里依赖 `llvm/Config/llvm-config.h`，都只取几个宏，容易替换。许可证 Apache-2.0 WITH LLVM-exception。（`/Volumes/SwiftProjects/swift-project/llvm-project`，`903b9faaae5c`）
- 平台：本包 README 承诺支持 Linux（`README.md:63-71`，MachOObjCSection 支持 Linux 的缘故）；FrameworkToolbox 的 platforms 只列 Apple 平台，MachOObjCSection 0001 因此把它从本包去掉；swift-dependencies 与 MemberwiseInit 都带宏、会引入 swift-syntax。本机没有 Linux SDK，Linux 编译这次验证不了（未验证）。

## 提议方案

1. **本包迁入四个模块，原名、原样，只改为编译所必需的地方**：`MachOPointers`、`MachOCaches`、`MachODependencies`、`MachOBase`，各带同名 library product。
   - `SharedCache` 的 `@Mutex` 换成 `NSLock`，与本包其它代码一致；删掉空的 `import Utilities`、`import BinaryParseSupport`。
   - `MachOCaches` 里四个 `package` 成员提为 `@_spi(Internals) public`，SPI 名与它其余成员相同。
   - `MachOBase` 不再再导出 `Utilities`。
   - 只能在 Darwin 上编译的部分包进 `#if canImport(Darwin)`。
2. **`MachOSymbols` 拆开，通用部分以原名迁入本包**：
   - 搬来 `SymbolTable`、`SymbolTableBuilder`、`PackedNameReference`、`SymbolRowBucket`、`SymbolValueOffsetConverter` 与 `NlistProtocol` 的三个判断；Swift 侧要用的提为 `@_spi(Internals) public`。
   - 新增 `SymbolLanguage`：按名字前缀判断 C、C++、Objective-C、Swift，两个 store 共用这一份前缀知识。
   - 新增钩子协议 `SymbolTableRouting` 与采集类型 `SymbolSweep`：一次扫描符号表与导出表，按 routing 的决定把名字分进几张表，每张表带自己的按偏移索引、导出信息与本地符号事实。
   - 新增只收非 Swift 名字的 `SymbolIndexStore`：按偏移、按最近偏移、按名字、是否导出查询，每个镜像建一次、所有调用方共享。
   - 新增汇总模块 `MachOFoundation`：再导出 `MachOBase`、`MachOSymbols`、`MachODependencies`。
3. **MachOSwiftSection 删掉迁走的五个模块，改依赖本包的 product**；ABI 模块自己再导出 `Utilities`，补上 29 个文件的 `import Utilities`。
4. **MachOSwiftSection 的 Swift 部分改名 `SwiftSymbols`**：`SymbolIndexStore` → `SwiftSymbolIndexStore`，采集改用 `SymbolSweep` 加一个 Swift 的 routing，其余（demangle 索引、成员归类、`_symbolic` 表、大栈执行器）不动；驱逐组改名 `.swiftSymbolStore`，`DependencyValues.symbolIndexStore` 改名 `swiftSymbolIndexStore`；新增 `SwiftSymbols` product；加一条源码扫描测试，禁止 Swift 层出现没改名的 `SymbolIndexStore`。
5. **MachOSwiftSection 的命名收尾**：`MachOMacros` → `SwiftSectionMacros`；`MachOFixtureSupport`、`MachOTestingSupport`、`MachOTestingSupportC` → `SwiftSectionFixtureSupport`、`SwiftSectionTestingSupport`、`SwiftSectionTestingSupportC`；`MachOSwiftSectionC` 是 ABI 模块的 C 部分，不改。
6. **测试与文档跟着代码走**：可迁的测试搬来并换样本，为 `MachOPointers`、`SymbolSweep`、`SymbolIndexStore` 补测试；实现说明搬来，两边互链。
7. **随前置提案一起落地**：本包 2.0.0、MachOSwiftSection 0.25.0 同一天切换。

### 非目标

- C++ 名字的 demangle（转字符串或结构化归类）与 LLVM `ItaniumDemangle` 的引入：放到 2.1.0，另写提案。2.0.0 的 C/C++ store 只给原始名字和语言；要可读名字的调用方暂时继续用 MachOKit 的 `demangledName`。
- 不迁 `Utilities`、`MachOMacros`、`ARM64InstructionDecoding` 及任何 Swift 层模块。
- 不让 `MachOKitExtensions` 模块再导出任何迁入的模块（避免与 MachOObjCSection 的 `Relative*Pointer`、与 MachOKit 的 `Symbol` / `SymbolProtocol` 歧义）。
- 不合并 `SharedCache` 与本包已有的 `MachOCacheStorage`：前者是跨实例、按镜像身份共享的缓存加驱逐登记，后者挂在单个 `MachOFile` 实例上；合不合并以后另议。
- 不改迁入模块的 API 与行为。例外只有：上面列出的可见性提升、`MachOBase` 不再导出 `Utilities`、`SymbolTable` 在纯 C 镜像上不再零拷贝。
- 不改 MachOKitUI、swift-decompiler、MachOObjCSection、REAgent 的代码去用新 store；MachOKitUI 那一行 import 随它升级本包 2.0.0 的那份提案改（前置提案已把 MachOKitUI 的改造列为另起提案）。
- 不加 Linux CI。

## 改动地图

本包路径相对本包根目录；`MSS:` 指 MachOSwiftSection 仓库根。

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `Sources/MachOPointers/**`（19 个文件） | 新增 | 从 `MSS:Sources/MachO/MachOPointers` 原样复制；删 `LocatableLayoutWrapper+RelativePointer.swift:1` 的 `import BinaryParseSupport` | 迁入相对指针层 | 1 |
| `Sources/MachOCaches/**`（5 个文件） | 新增 | 原样复制；`SharedCache` 的 `@Mutex` 与 7 处 `withLockUnchecked` 换 `NSLock`；删 `import Utilities`、`import SwiftStdlibToolbox`；`init(evictionGroup:follows:registry:)`、`register(_:forKey:)`、`resolve(key:build:)`、`SharedCacheRegistry.init()` 提为 `@_spi(Internals) public` | 本包不依赖 FrameworkToolbox；跨包后 `package` 不可见，MachOSwiftSection 有 25 处构造 | 1 |
| `Sources/MachODependencies/**`（11 个文件） | 新增 | 原样复制；Darwin 专属部分包进 `#if canImport(Darwin)` | 本包承诺 Linux | 1 |
| `Sources/MachOBase/Exported.swift` | 新增 | 再导出 `MachOKitExtensions`、`MachOReading`、`MachOResolving`、`MachOPointers` | `Utilities` 留在 MachOSwiftSection | 1 |
| `Package.swift` | 修改 | 新增 `MachOPointers`、`MachOCaches`、`MachODependencies`、`MachOBase` 四个 target 与同名 product；测试 target `MachOCachesTests`、`MachODependenciesTests`、`MachOPointersTests` | 迁入 | 1 |
| `Tests/MachOCachesTests/{SharedCacheTests,SharedCacheRegistryTests,SharedCacheKeyTests}.swift` | 新增 | 从 `MSS:Tests/MachOCachesTests` 搬，不改断言 | 测试跟着代码走 | 1 |
| `Tests/MachOKitExtensionsTests/{DyldCacheImageSearchTests,MachOImageCacheMembershipTests}.swift` | 新增 | 从 `MSS:Tests/MachOCachesTests` 搬 | 它们测的是本包的行为 | 1 |
| `Tests/MachODependenciesTests/*`（8 个文件） | 新增 | 从 `MSS:Tests/MachODependenciesTests` 搬（`DependencyClosureTests` 除外）；SymbolTestsCore / SymbolTestsHelper 换成 `/usr/bin/curl` 的副本；`DyldSharedCachePath` 换字面路径，保留 `.enabled(if:)` | 不依赖 MachOSwiftSection 的样本 | 1 |
| `Tests/MachOPointersTests/RelativePointerResolutionTests.swift` | 新增 | 在本进程的合成字节上解析相对直接、间接、带标志位的指针 | 迁入后本包没有它的专属测试 | 1 |
| `Sources/MachOSymbols/SymbolTable.swift` · `SymbolRow`、`PackedNameReference`、`SymbolTable`、`SymbolTableBuilder` | 新增 | 从 `MSS:Sources/MachO/MachOSymbols/SymbolTable.swift` 搬；`SymbolTable` 的读取 API 与 `init(standaloneSymbol:)` 提为 `@_spi(Internals) public`；`nameBytesHaveSwiftManglingPrefix` 并入 `SymbolLanguage`；`:95-106` 的卸载注释按新规则重写 | Swift 侧的 `DemangledSymbol`、`SymbolicManglingSymbols`、`DemanglingWave` 读这些 API | 2 |
| `Sources/MachOSymbols/SymbolRowBucket.swift` · `SymbolRowBucket` | 新增 | 搬，提为 `@_spi(Internals) public` | Swift 侧的成员索引也用它 | 2 |
| `Sources/MachOSymbols/SymbolValueOffsetConverter.swift` · `SymbolValueOffsetConverter` | 新增 | 搬，提为 `@_spi(Internals) public` | Swift 侧的 `swiftSymbols` 用它 | 2 |
| `Sources/MachOSymbols/NlistProtocol+.swift` · `isExternal`、`isLocal`、`isDebuggingEntry` | 新增 | 从 `MSS:…/SymbolIndexStore.swift:1955-1981` 搬，由 `package` 改为 `@_spi(Internals) public` | SwiftThunkAnalysis 用 `isDebuggingEntry`；`isExternal` 的名字容易误解（只指导入），不宜正式公开 | 2 |
| `Sources/MachOSymbols/SymbolLanguage.swift` · `SymbolLanguage` | 新增 | 按前缀判断语言（见详细设计） | 两个 store 共用一份前缀知识 | 2 |
| `Sources/MachOSymbols/SymbolTableRouting.swift` · `SymbolTableRouting` | 新增 | 钩子协议 | Swift store 经它复用采集 | 2 |
| `Sources/MachOSymbols/SymbolSweep.swift` · `SymbolSweep`、`SweptSymbolTable`、`SymbolExportFacts` | 新增 | 由 `MSS:…/SymbolIndexStore.swift:743-979` 的 `buildSymbolTableStage` 改写：名字分类交给 routing，按表分别建 builder、偏移索引、导出信息与本地符号事实；零拷贝名字按新规则 | 通用采集 | 2 |
| `Tests/MachOSymbolsTests/PackedNameReferenceBudgetTests.swift` | 新增 | 搬 `MSS:` 同名文件的 `:23-50` | 测试跟着代码走 | 2 |
| `Tests/MachOSymbolsTests/SymbolLanguageTests.swift` | 新增 | 各语言的代表名字 | 新类型 | 2 |
| `Tests/MachOSymbolsTests/SymbolSweepTests.swift` | 新增 | 两条采集腿等价、二分查找、按 routing 分表、偏移索引开关、导出信息三态、零拷贝规则、调试条目只占行 | 新类型；吸收 `SymbolTableEquivalenceTests`、`SymbolIndexStoreFixtureTests` 的通用用例 | 2 |
| `Sources/MachOSymbols/SymbolIndexStore.swift` · `SymbolIndexStore` | 新增 | 只收非 Swift 名字的 store | C/C++ 索引 | 3 |
| `Sources/MachOSymbols/SharedCacheEvictionGroup+MachOSymbols.swift` · `.symbolStore` | 新增 | 本包 store 的驱逐组 | 驱逐登记要一个组名 | 3 |
| `Sources/MachOFoundation/Exported.swift` | 新增 | 再导出 `MachOBase`、`MachOSymbols`、`MachODependencies` | 汇总模块随之迁入 | 3 |
| `Package.swift` | 修改 | 新增 `MachOSymbols`、`MachOFoundation` target 与 product、测试 target `MachOSymbolsTests` | 迁入 | 3 |
| `Tests/MachOSymbolsTests/SymbolIndexStoreTests.swift` | 新增 | C/C++ store 的查询契约 | 新类型 | 3 |
| `Tests/MachOSymbolsTests/WrappedReaderSymbolTests.swift` | 新增 | 包装读取器下的偏移换算，改用本包的 `ForwardingReader` 与 C/C++ store | 吸收 `MSS:` 同名测试的通用部分 | 3 |
| `MSS:Sources/MachO/{MachOBase,MachOCaches,MachODependencies,MachOFoundation,MachOPointers}` | 删除 | — | 已迁入本包 | 4 |
| `MSS:Package.swift` | 修改 | 删掉这五个 target 与 `.library(.MachOBase)`、`.library(.MachOFoundation)`、`.library(.MachODependencies)`（`:1441-1443`）及 `:1437-1440` 的注释；改依赖本包的同名 product；本包下限仍是 2.0.0 | 迁走 | 4 |
| `MSS:Sources/ABI/MachOSwiftSection/Exported.swift` | 修改 | 加 `@_exported import Utilities` | 下游（如 RuntimeViewer 的 `offsetEnumerated()`）经 `import MachOSwiftSection` 拿到 `Utilities` 的链不断 | 4 |
| `MSS:Sources/ABI/MachOSwiftSection/**` 中用 `@Layout` 的 29 个文件 | 修改 | 补 `import Utilities` | `MachOBase` 不再导出它 | 4 |
| `MSS:Tests/MachOCachesTests`、`MSS:Tests/MachODependenciesTests`（`DependencyClosureTests` 除外） | 删除 | — | 已搬到本包 | 4 |
| `MSS:Tests/MachODependenciesTests/DependencyClosureTests.swift` | 移动 | 移到 `MSS:Tests/IntegrationTests/MachODependencies/` | 它依赖 SymbolTestsCore 夹具，留在 MachOSwiftSection；`MachODependenciesTests` 这个 target 随之删除 | 4 |
| `MSS:Tests/IntegrationTests/SwiftInterface/SwiftInterfaceBuilderTests.swift:14` | 修改 | 去掉 `@testable`，只留 `@_spi(Internals) import MachOCaches`；若用到 internal 成员，改用 SPI | 跨包的 `@testable` 不保证可用 | 4 |
| `MSS:Sources/MachO/MachOSymbols` → `MSS:Sources/Symbols/SwiftSymbols` | 移动 | target 改名 `SwiftSymbols`，目录放进新的层分组 `Symbols/`（`MachO/` 分组随之消失） | 命名规则；0055 的按层分组 | 5 |
| `MSS:Sources/Symbols/SwiftSymbols/SymbolIndexStore.swift` → `SwiftSymbolIndexStore.swift` · `SwiftSymbolIndexStore` | 修改 | 类型改名；`Storage` 的通用字段改由 `SymbolSweep` 产出（`SwiftSymbolTableRouting`：`.swift` 主表、`.symbolicMangling` 附加表）；删除已迁走的通用代码与 `NlistProtocol` 扩展；`ExportFacts` 换成 `SymbolExportFacts`；删空 import（`MemberwiseInit`、`AsyncAlgorithms`、`Utilities`）与无用的 `@Loggable` | 拆分 | 5 |
| `MSS:Sources/Symbols/SwiftSymbols/SwiftSymbolTableRouting.swift` · `SwiftSymbolTableRouting` | 新增 | Swift 的 routing | 钩子的 Swift 实现 | 5 |
| `MSS:Sources/Symbols/SwiftSymbols/{SymbolTable,SymbolRowBucket,SymbolValueOffsetConverter}.swift` | 删除 | — | 已迁入本包 | 5 |
| `MSS:Sources/Symbols/SwiftSymbols/SharedCacheEvictionGroup+SwiftSymbols.swift` · `.swiftSymbolStore`、`.internedNames` | 修改 | 由 `SharedCacheEvictionGroup+MachOSymbols.swift` 改名；`.symbolStore` 改名 `.swiftSymbolStore`（名字字符串一并改） | 本包 store 用 `.symbolStore`，组按名字判等 | 5 |
| `MSS:` 7 处 `follows: [.symbolStore]` | 修改 | 改为 `.swiftSymbolStore` | 跟随的是 Swift store | 5 |
| `MSS:` 所有 `SymbolIndexStore` 引用（源码与测试） | 修改 | 改为 `SwiftSymbolIndexStore`；`DependencyValues.symbolIndexStore` 改为 `swiftSymbolIndexStore` | 类型改名 | 5 |
| `MSS:` 所有 `import MachOSymbols`（源码 94、测试 53） | 修改 | 改为 `import SwiftSymbols`；经 `import MachOFoundation` 用到 Swift 符号 API 的文件按编译报错补 `import SwiftSymbols` | 模块改名；`MachOFoundation` 不再带 Swift 部分 | 5 |
| `MSS:Package.swift` | 修改 | `MachOSymbols` target 改为 `SwiftSymbols`（依赖本包的 `MachOSymbols`、`MachOCaches` 与 Demangling、`Utilities`）；新增 `.library(.SwiftSymbols)`；`MachOSymbolsTests` 改名 `SwiftSymbolsTests` | 模块改名；让 MachOKitUI 能正式依赖它 | 5 |
| `MSS:Tests/MachOSymbolsTests` → `MSS:Tests/SwiftSymbolsTests` | 移动 | 删掉已搬到本包的通用用例；`SymbolTableEquivalenceTests` 改为钉住「`SymbolLanguage` 判为 `.swift`」与 `isSwiftSymbol` 及 `_symbolic` 前缀判断等价 | 拆分 | 5 |
| `MSS:Tests/SwiftSymbolsTests/SymbolIndexStoreNamingScanTests.swift` | 新增 | 扫描 `Sources/`，除本包类型外不允许出现没有 `Swift` 前缀的 `SymbolIndexStore` | 防止漏改名后悄悄编到 C/C++ store | 5 |
| `MSS:Sources/Support/MachOMacros` → `MSS:Sources/Support/SwiftSectionMacros` | 移动 | target 改名；`#externalMacro(module: "MachOMacros")` 两处改名 | 命名规则 | 6 |
| `MSS:Sources/TestSupport/{MachOFixtureSupport,MachOTestingSupport,MachOTestingSupportC}` → `SwiftSection…` | 移动 | target 改名；测试里约 680 个文件的 import；`BaselineGenerator.swift:891-892`；重新生成 `AllFixtureSuites.swift`；`PrintFailureEventTests.swift:265` 的 `hostModules` | 命名规则 | 6 |
| `MSS:Tests/MachOTestingSupportTests` → `MSS:Tests/SwiftSectionTestingSupportTests` | 移动 | target 改名 | 命名规则 | 6 |
| `MSS:.github/workflows/macOS.yml:123`、`:148-149` | 修改 | 从 `--filter` 删掉迁走的 suite，改名的 suite 换新名 | `ContinuousIntegrationTestFilterTests` 要求列表里的 suite 都存在 | 6 |
| `Documentations/Internal/SharedCache.md` | 新增 | 由 `MSS:Documentations/Internal/Modules/MachOCaches.md` 改写 | 实现说明跟着代码走 | 7 |
| `Documentations/Internal/DependencyResolution.md` | 新增 | 由 `MSS:Documentations/Internal/Modules/MachODependencies.md` 改写 | 同上 | 7 |
| `Documentations/Internal/SymbolIndex.md` | 新增 | 由 `MSS:Documentations/Internal/Modules/MachOSymbols.md` 的子系统 1 改写，加上 `SymbolLanguage`、`SymbolTableRouting`、C/C++ store 与零拷贝规则 | 同上 | 7 |
| `README.md`、`Documentations/README.md` | 修改 | product 表、2.0.0 说明、文档索引 | 新 product | 7 |
| `MSS:Documentations/Internal/Modules/MachOSymbols.md` → `SwiftSymbols.md` | 移动 | 删掉已搬到本包的子系统 1 通用部分，改为链接 | 拆分 | 7 |
| `MSS:Documentations/Internal/Modules/{MachOCaches,MachODependencies}.md` | 删除 | 模块表改为链接到本包文档 | 已迁走 | 7 |
| `MSS:AGENTS.md`、`MSS:Documentations/{README.md,Glossary.md,Internal/ProjectMap.md,Internal/Modules/README.md,Internal/SelfContainedABILayer.md,Internal/StaticLayoutDependencyClosure.md}`、`MSS:README.md` | 修改 | 模块层次图、模块说明、路径、product 表 | 模块搬家与改名 | 7 |
| `Documentations/Evolutions/README.md`、`MSS:Documentations/Evolutions/README.md` | 修改 | 本提案取号、改 Implemented；MachOSwiftSection 的索引加跨仓库行 | 落地 | 9 |
| MachOKitUI `Sources/MachOKitUICore/Builder/MachOSwiftSectionDetailBuilder.swift:9` | 修改（不在本提案的分支里做） | `import MachOSymbols` 改为 `import SwiftSymbols` | `resolvesSymbolUsingIndexStore` 随 Swift 部分改名；随 MachOKitUI 升级本包 2.0.0 的提案一起改 | — |

## 架构图

模块归属，改动前后（前置提案已迁入的 `MachOReading`、`MachOResolving` 记作现状）：

```text
MachOKitExtensions (package)                       MachOSwiftSection (package)
  MachOKitExtensions                                 Support/
  MachOReading                                         Utilities                  (stays)
  MachOResolving                                     - MachOMacros
+ MachOPointers      <-- moved, unchanged            + SwiftSectionMacros         (renamed)
+ MachOCaches        <-- moved, @Mutex -> NSLock       ARM64InstructionDecoding
+ MachODependencies  <-- moved, unchanged            MachO/                       (group removed)
+ MachOSymbols       <-- language-neutral half       - MachOPointers, MachOCaches, MachODependencies
      SymbolTable, SymbolRowBucket,                  - MachOSymbols
      SymbolValueOffsetConverter,                    - MachOBase, MachOFoundation
    + SymbolLanguage                                 Symbols/                     (new group)
    + SymbolTableRouting (hook)                      + SwiftSymbols               (Swift half of MachOSymbols)
    + SymbolSweep                                        SwiftSymbolIndexStore    (was SymbolIndexStore)
    + SymbolIndexStore   (C / C++ / ObjC names)          SwiftSymbolTableRouting
+ MachOBase          (umbrella, no Utilities)          ABI/
+ MachOFoundation    (umbrella)                          MachOSwiftSection        (re-exports MachOBase + Utilities)
                                                         MachOSwiftSectionC
                                                       Analysis/ Declaration/ Output/ Commands/ ...   (Swift*)
                                                       TestSupport/
                                                       - MachOFixtureSupport, MachOTestingSupport(C)
                                                       + SwiftSectionFixtureSupport, SwiftSectionTestingSupport(C)
```

依赖方向（箭头指向被依赖者）：

```text
SwiftSymbols ──> MachOSymbols, MachOCaches        (MachOKitExtensions)
             ──> Demangling, Utilities
MachOSwiftSection (ABI) ──> MachOBase              (MachOKitExtensions)
                        ──> Utilities, SwiftSectionMacros, MachOSwiftSectionC
Swift* modules ──> MachOFoundation                 (MachOKitExtensions)
               ──> SwiftSymbols, MachOSwiftSection, ...

MachOFoundation ──> MachOBase, MachOSymbols, MachODependencies
MachOBase       ──> MachOKitExtensions, MachOReading, MachOResolving, MachOPointers
MachOSymbols    ──> MachOKitExtensions, MachOResolving, MachOCaches
MachOCaches     ──> MachOKitExtensions
MachOPointers   ──> MachOKitExtensions, MachOReading, MachOResolving
```

采集与两个 store 的数据流：

```text
SymbolSweep(sweeping: machO, routing: someRouting)
  symbol-table leg   (MachOImage: names read in place / others: decoded Strings)
    for each entry, imports (isExternal) skipped:
      language = SymbolLanguage(ofSymbolNameBytes: name)
      table    = routing.table(forSymbolNamed: name, language: language)   -- nil: skip
      debug entry      -> builders[table].reserveRow(...)                   -- no offset
      otherwise        -> builders[table].canonicalRow(...)
                          -> rowsByOffset[table] (raw + canonical) if routing.indexesRowsByOffset(in: table)
                          -> hasLocalSymbols[table] |= isLocal
  export-trie leg
    any entry          -> exportFacts.hasExportInformation = true
    routed name        -> exported bit on its row, or a new row, or names-without-rows
  freeze -> [Table: SweptSymbolTable(symbolTable, rowsByOffset, exportFacts, hasLocalSymbols)]

SymbolIndexStore (MachOKitExtensions)              SwiftSymbolIndexStore (MachOSwiftSection)
  NonSwiftSymbolTableRouting                         SwiftSymbolTableRouting
    .c / .cPlusPlus / .objectiveC -> .symbols          .swift -> .swift | .symbolicMangling
    mapped names: dyld-cache images only               mapped names: every MachOImage (pinned)
  Storage = swept[.symbols]                          Storage = swept[.swift] + swept[.symbolicMangling]
          + offsets sorted (canonical only)                  + lazy demangled index      (unchanged)
  SharedCache(evictionGroup: .symbolStore)           SharedCache(evictionGroup: .swiftSymbolStore)
```

## 详细设计

### 本包的 `Package.swift`

在前置提案的基础上增加（`MachOReading`、`MachOResolving` 已在其中）：

```swift
products: [
    // ...MachOKitExtensions, MachOReading, MachOResolving
    .library(name: "MachOPointers", targets: ["MachOPointers"]),
    .library(name: "MachOCaches", targets: ["MachOCaches"]),
    .library(name: "MachODependencies", targets: ["MachODependencies"]),
    .library(name: "MachOSymbols", targets: ["MachOSymbols"]),
    .library(name: "MachOBase", targets: ["MachOBase"]),
    .library(name: "MachOFoundation", targets: ["MachOFoundation"]),
],
targets: [
    .target(name: "MachOPointers", dependencies: ["MachOKit", "MachOKitExtensions", "MachOReading", "MachOResolving"]),
    .target(name: "MachOCaches", dependencies: ["MachOKit", "MachOKitExtensions"]),
    .target(name: "MachODependencies", dependencies: ["MachOKit", "MachOKitExtensions"]),
    .target(name: "MachOSymbols", dependencies: ["MachOKit", "MachOKitExtensions", "MachOResolving", "MachOCaches"]),
    .target(name: "MachOBase", dependencies: ["MachOKitExtensions", "MachOReading", "MachOResolving", "MachOPointers"]),
    .target(name: "MachOFoundation", dependencies: ["MachOBase", "MachOSymbols", "MachODependencies"]),
    // test targets: MachOCachesTests, MachODependenciesTests, MachOPointersTests, MachOSymbolsTests
]
```

不新增任何外部包依赖。

### `SymbolLanguage`

```swift
/// The language a symbol name was mangled for, told from the name's leading
/// bytes alone.
public struct SymbolLanguage: Hashable, Sendable, CustomStringConvertible {
    /// A name no other language claims: plain C, assembler labels, and
    /// anything unrecognized.
    public static let c: SymbolLanguage

    /// An Itanium-mangled name: `__Z…`, or `___Z…` for a block inside a C++
    /// function.
    public static let cPlusPlus: SymbolLanguage

    /// An Objective-C method implementation (`-[…]`, `+[…]`) or a symbol of the
    /// Objective-C runtime (`_OBJC_…`, `__OBJC_…`, `l_OBJC_…`, `L_OBJC_…`,
    /// `_objc_msgSend$…`).
    public static let objectiveC: SymbolLanguage

    /// A Swift-mangled name (`$s`, `_$s`, `$S`, `_$S`, `$e`, `_$e`, `_T0`,
    /// `@__swiftmacro_`) or a name the Swift compiler emits for the linker to
    /// de-duplicate (`_symbolic `, `_default assoc type `).
    public static let swift: SymbolLanguage

    public init(ofSymbolNamed name: String)

    @_spi(Internals)
    public init(ofSymbolNameBytes name: UnsafePointer<CChar>)

    public var description: String { get }
}
```

- struct 加静态成员而不是 enum：语言以后可能增加（比如 Rust 的 `__R`），调用方不该被迫穷举。
- Swift 前缀集合与 Demangling 的 `getManglingPrefixLength` 一致，`_symbolic` 前缀与 `SymbolicManglingSymbolName` 一致；两者由 MachOSwiftSection 的 `SymbolTableEquivalenceTests` 在真实符号表上钉住（本包不依赖 Demangling，钉不了）。
- 按字节判断：先看首字节分支，再 `strncmp`，与现在的 `nameBytesHaveSwiftManglingPrefix` 同样不物化 `String`。

### 钩子：`SymbolTableRouting`

```swift
/// Decides, name by name, which of a store's tables a ``SymbolSweep`` files a
/// symbol under.
@_spi(Internals)
public protocol SymbolTableRouting: Sendable {
    /// The tables this routing files symbols into.
    associatedtype Table: Hashable, Sendable

    /// The table a symbol belongs in, or `nil` to leave it out of every table.
    ///
    /// Asked once for each defined symbol-table entry and once for each
    /// export-trie entry. `name` is valid only for the duration of the call.
    func table(forSymbolNamed name: UnsafePointer<CChar>, language: SymbolLanguage) -> Table?

    /// Whether the sweep files `table`'s rows by offset as well as by name.
    func indexesRowsByOffset(in table: Table) -> Bool

    /// Whether rows read from an in-process image outside the dyld shared
    /// cache may point into that image's string table instead of copying
    /// their names.
    ///
    /// `true` only when every image whose names this routing files is one
    /// dyld never unloads — dyld pins every image carrying Swift or
    /// Objective-C content. Rows of an image inside the shared cache always
    /// point in: the cache is never unmapped.
    var mayReferenceStringTablesOfLoadedImages: Bool { get }
}
```

- 用协议而不是闭包：两个具体 store 已经写出来了（C/C++ 与 Swift），协议的三个要求正是它们在采集里不同的地方，与「先具体、后抽象」一致。三个要求都没有默认实现，因为两个遵循者的答案本来就不同。
- 名字以 C 字符串交给 routing：mapped 腿本来就是 C 字符串；泛型腿与导出表腿的 `String` 用 `withCString` 交出，成本只有一次借用。语言由采集先算好再传入，routing 只做查表级的判断。
- 两个 routing 都是 internal 类型：`NonSwiftSymbolTableRouting`（本包）、`SwiftSymbolTableRouting`（MachOSwiftSection）。

### 采集：`SymbolSweep`

```swift
/// One pass over an image's symbol table and export trie, filing each name
/// into the table its routing chooses.
@_spi(Internals)
public struct SymbolSweep<Routing: SymbolTableRouting>: Sendable {
    public init(sweeping machO: some MachORepresentableWithCache, routing: Routing)

    /// What the sweep filed under `table`; an empty table when the routing
    /// filed nothing there.
    public subscript(table: Routing.Table) -> SweptSymbolTable { get }
}

@_spi(Internals)
public struct SweptSymbolTable: Sendable {
    public let symbolTable: SymbolTable

    /// Rows by offset — the raw symbol value and, when it differs, the
    /// canonical offset. Empty for a table the routing does not index by
    /// offset.
    public let rowsByOffset: [Int: SymbolRowBucket]

    public let exportFacts: SymbolExportFacts

    /// Whether a local (`N_EXT` clear), non-debug symbol was filed here,
    /// counting one whose name the packed layout refused.
    public let hasLocalSymbols: Bool
}

@_spi(Internals)
public struct SymbolExportFacts: Sendable {
    /// Whether the image's export trie had any entry, whatever the routing
    /// kept.
    public let hasExportInformation: Bool

    /// `nil` when the image carries no export information; otherwise whether
    /// `name` has an export-trie entry.
    public func isExported(name: String, in symbolTable: SymbolTable) -> Bool?
}
```

行为与现在的 `buildSymbolTableStage` 逐条对应（「前期调研」第 1–7 条），差别只有：

- 名字分类交给 routing，每个 routing 选出的表各有一个 `SymbolTableBuilder`；
- 偏移索引、导出位图、name-only 集合、本地符号事实按表分别记；
- 零拷贝规则：`MachOImage` 在 dyld shared cache 里（按 mach header 的 `MH_DYLIB_IN_CACHE` 判断，本包已有这个判断）或 `routing.mayReferenceStringTablesOfLoadedImages` 为真时，行指向镜像字符串表；否则名字复制进表的私有缓冲。`MachOFile` 与导出表名字照旧进私有缓冲。
- 不再有「Swift」字样的字段名：`exportedSwiftNamesWithoutRows` 改为 `exportedNamesWithoutRows`，`hasLocalSwiftSymbols` 改为 `hasLocalSymbols`。

### C/C++ store：`SymbolIndexStore`

```swift
/// The C, C++ and Objective-C symbols of an image, found by offset or by
/// name. An image's index is built on first use and shared by every caller.
///
/// Offsets are the ones every reader in this package uses: a file offset for
/// a standalone file, the unslid address minus the shared region start for an
/// image read from a dyld shared cache, the distance from the mach header for
/// a loaded image.
public final class SymbolIndexStore: Sendable {
    public static let shared: SymbolIndexStore

    /// The symbols at exactly `offset`.
    public func symbols(for offset: Int, in machO: some MachORepresentableWithCache) -> Symbols?

    /// The symbols at the greatest offset not after `offset` — the function
    /// or data an address falls in, when the symbol table names it.
    public func closestSymbols(at offset: Int, in machO: some MachORepresentableWithCache) -> Symbols?

    public func offset(ofSymbolNamed name: String, in machO: some MachORepresentableWithCache) -> Int?

    public func containsSymbol(named name: String, in machO: some MachORepresentableWithCache) -> Bool

    /// `nil` when the image carries no export information at all.
    public func isExported(name: String, in machO: some MachORepresentableWithCache) -> Bool?

    public func hasExportInformation(in machO: some MachORepresentableWithCache) -> Bool

    /// Builds the image's index now instead of on first use.
    public func prepare(in machO: some MachORepresentableWithCache)

    public func contains(in machO: some MachORepresentableWithCache) -> Bool

    public func remove(for machO: some MachORepresentableWithCache)
}
```

- 调用点示例：

  ```swift
  let store = SymbolIndexStore.shared
  let main = store.offset(ofSymbolNamed: "_main", in: machOFile)
  let enclosing = store.closestSymbols(at: instructionOffset, in: machOFile)?.symbols.first?.name
  let language = SymbolLanguage(ofSymbolNamed: symbol.name)   // .cPlusPlus, .objectiveC, …
  ```

- 方法名沿用 Swift store 的同名查询（`symbols(for:in:)`、`offset(ofSymbolNamed:in:)`、`containsSymbol(named:in:)`、`isExported(name:in:)`、`hasExportInformation(in:)`），同一族的 API 保持一致；`closestSymbols(at:in:)` 取自 MachOKit 的 `closestSymbol(at:)`，用复数是因为同一偏移常有多个别名。
- `closestSymbols` 只按规范化偏移找（`rowsByOffset` 里的 raw 键对独立文件是虚拟地址，不能混进有序数组）：建索引时把登记过偏移的行按规范化偏移排序存成数组，查询是二分。不设距离上限，由调用方判断（MachOKitUI 现在用 0x100000）。
- 返回 `MachOResolving.Symbols` / `Symbol`，与 Swift store 一致。
- 缓存用 `SharedCache<Storage>(evictionGroup: .symbolStore)`；store 自己不被任何 indexer 认领，`remove(for:)` 由调用方决定何时调。
- 2.0.0 不做 C++ demangle（见非目标）。

### MachOSwiftSection 一侧

- `SwiftSymbolIndexStore` 的构建改为：

  ```swift
  let sweep = SymbolSweep(sweeping: machO, routing: SwiftSymbolTableRouting())
  // Storage(symbolTable: sweep[.swift].symbolTable,
  //         symbolRowsByOffset: sweep[.swift].rowsByOffset,
  //         exportFacts: sweep[.swift].exportFacts,
  //         hasLocalSwiftSymbols: sweep[.swift].hasLocalSymbols,
  //         symbolicManglingSymbolTable: sweep[.symbolicMangling].symbolTable, ...)
  ```

  `SwiftSymbolTableRouting`：语言是 `.swift` 时，`_symbolic` / `_default assoc type ` 开头的进 `.symbolicMangling`，其余进 `.swift`；只有 `.swift` 进偏移索引；`mayReferenceStringTablesOfLoadedImages` 为真。第二段懒构建的 demangle 索引、`lateDemangledNode`、按归属分组、所有 Swift 查询原样保留。
- 与现状的唯一行为差异：导出表里若出现 `_symbolic` 名字，会进附加表而不是被丢掉。这类名字是链接器去重用的本地符号，不会被导出；渲染 A/B 会确认输出不变。
- `MachORepresentableWithCache.symbols(offset:)`、`MachORepresentable.swiftSymbols`、`Symbol.resolve(from:in:)`、`Symbol.resolvesSymbolUsingIndexStore`、`SymbolProtocol.demangledNode` 留在 `SwiftSymbols`，签名不变。本包不提供 `symbols(offset:)` 这类 MachO 类型上的便捷方法，避免与它重名。
- import 的改法：`import MachOSymbols` 一律改为 `import SwiftSymbols`；其余按编译报错补 `import SwiftSymbols`。测试支撑模块（改名后）`@_exported import SwiftSymbols`，减少测试文件的改动。
- `SymbolIndexStoreNamingScanTests`：扫 `Sources/` 与 `Tests/`，去掉注释后匹配 `(?<![A-Za-z])SymbolIndexStore\b`，命中即失败。

### 锁与 SPI

- `SharedCache` 的 `storageByKey` 改为私有存储加一个 `NSLock`，7 处 `withLockUnchecked` 改为 `lock.withLock { }`；行为（重入时 trap、并发去重）由搬来的 `SharedCacheTests` 钉住。
- 凡是 Swift 侧要用、又不宜成为正式公开 API 的，一律 `@_spi(Internals) public`，与 `MachOCaches` 现有约定相同；MachOSwiftSection 里已有的 `@_spi(Internals) import` 写法不用改。

### 测试

- 搬来的测试不改断言，只换样本与支撑代码。
- 新增的行为见「落地步骤」各步的清单。
- MachOSwiftSection 的全量测试必须通过；它规定读取层与符号层的大改动要做渲染 A/B（其 `Documentations/Internal/SystemFrameworkRenderingVerification.md`）：基线是前置提案的 MachOSwiftSection 功能分支（它已与 `next` 做过 96 对逐字节一致的 A/B），候选是本提案的功能分支，三条读取路径的 `dump` 与 `interface` 输出逐字节一致。
- 内存：在一个大镜像（AppKit 或 WebCore，`MachOFile` 与 `MachOImage` 各一次）上记录 C/C++ store 的行数与 `Storage` 大小，写进实现说明。

### 文档

- 本包新增三份实现说明：`Internal/SharedCache.md`、`Internal/DependencyResolution.md`、`Internal/SymbolIndex.md`，由 MachOSwiftSection 的模块文档改写，登记到 `Documentations/README.md` 与本提案头部的「配套文档」。
- MachOSwiftSection 的 `Internal/Modules/MachOSymbols.md` 改为 `SwiftSymbols.md`，只讲 Swift 部分并链接本包的 `SymbolIndex.md`；`MachOCaches.md`、`MachODependencies.md` 删除，模块表改为链接。
- 两边的 README、AGENTS.md、Glossary、ProjectMap 同步模块名、层次图与路径。

## 替代方案考量

- **类继承**（本包 `open class SymbolIndexStore`，Swift store 写子类覆写分类方法）：两边的 `Storage` 形状完全不同，现在的 store 又是 `final` 单例；继承要么把存储做成泛型、要么在子类里再挂一份，而且热循环里每个符号多一次动态派发。否。
- **一次扫描同时喂两个 store**：省一遍扫描，但两个 store 的建表时机、缓存与驱逐就被绑在一起——只想要 C 名字的调用方会被迫等 Swift 那半（以及它的 demangle 索引）建完。扫描本身相对 demangle 很便宜。否。
- **本包新模块另起名、MachOSwiftSection 的 `MachOSymbols` 不改名**：名字会和内容反过来——叫 `MachOSymbols` 的是 Swift 专用的那一半。否。
- **2.0.0 之后单独发**：本包新模块 `MachOSymbols` 会与 MachOSwiftSection 0.25.0 自带的同名模块冲突，得再发 3.0.0。否。
- **`Utilities` 改名 `MachOUtilities` 迁入**：最初这样定过，核实后推翻——迁入的模块一处都不用它；它的声明多为 `package`，跨包后只能改成 `public` 公开出去；还会带进 FrameworkToolbox 的日志宏和 `@Layout` 宏声明。否。
- **`MachOMacros` 迁入本包**：本包会多一个 swift-syntax 依赖，下游解析时多一条 swift-syntax 版本约束，而现在只有 MachOSwiftSection 的 ABI 层用这些宏。否。
- **迁入的代码照用 FrameworkToolbox、swift-dependencies、MemberwiseInit**：FrameworkToolbox 只支持 Apple 平台，后两者带宏会引入 swift-syntax，都违背本包对 Linux 的承诺与「不依赖 swift-syntax」。通用部分本来也不用它们。否。
- **2.0.0 就用 `__cxa_demangle` 把 C++ 名字转成字符串**：MachOKit 是经 `dlsym` 取这个函数的（`Util/CxaDemangle.swift`），平台行为不一；2.1.0 引入 `ItaniumDemangle` 后又要换一次实现、可能换输出。调用方现在就能用 MachOKit 的 `demangledName`。推迟到 2.1.0 一次做对。
- **C/C++ store 一律复制名字**：最安全，但 dyld shared cache 里的镜像（绝大多数查询对象）永远不会卸载，复制白白多占内存。只对 cache 外的镜像复制。
- **C/C++ store 也一律零拷贝**：纯 C 镜像可以被 `dlclose` 卸载，行会悬空。否。

## 影响

### 源码兼容性（source compatibility）

- **本包：纯新增。** 2.0.0（与前置提案共用）只新增 product 与模块，`MachOKitExtensions` 模块一行不改、也不再导出新模块。
- **MachOSwiftSection：有破坏**（0.x 的次版本，允许）：
  - `import MachOSymbols` 拿到的是本包的 C/C++ 部分；要 Swift 符号 API 改为 `import SwiftSymbols`。
  - `SymbolIndexStore` → `SwiftSymbolIndexStore`；`DependencyValues.symbolIndexStore` → `swiftSymbolIndexStore`；`SharedCacheEvictionGroup.symbolStore`（Swift store 的组）→ `.swiftSymbolStore`。
  - `MachOMacros`、`MachOFixtureSupport`、`MachOTestingSupport`、`MachOTestingSupportC` 改名（都不是 product）。
  - `MachOBase`、`MachOFoundation`、`MachODependencies` 三个 product 改由本包提供。
  - 改前 / 改后：

    ```swift
    // before
    import MachOSymbols
    let store = SymbolIndexStore.shared
    @Dependency(\.symbolIndexStore) var symbolIndexStore

    // after
    import SwiftSymbols
    let store = SwiftSymbolIndexStore.shared
    @Dependency(\.swiftSymbolIndexStore) var symbolIndexStore
    ```

  - 不提供 `@available(*, deprecated, renamed:)` 过渡：旧名 `SymbolIndexStore` 在新版本里指的是本包的 C/C++ store，留一个指向 Swift store 的别名反而让同名指向两处。

### ABI 兼容性

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

- **本包内**：`MachOKitExtensionsTests` 多两个搬来的测试文件；其余 target 不受影响。
- **MachOSwiftSection**：见源码兼容性；改动大部分是机械的 import 与类型改名。
- **MachOKitUI**：`MachOSwiftSectionDetailBuilder.swift:9` 要改 `import SwiftSymbols`（在 `#if SwiftSection` 里）。它现在的版本范围只会解析到 MachOSwiftSection 0.24.x，所以远端构建不受影响；用本地依赖、开 SwiftSection trait 构建时，从落地那天到它升级本包 2.0.0 之前会报找不到 `resolvesSymbolUsingIndexStore`——与前置提案已经记下的「本地依赖会报模块重名」是同一个窗口，随同一份 MachOKitUI 提案解决。
- **RuntimeViewer**：`import Utilities` 与 `offsetEnumerated()` 靠 `MachOSwiftSection` 再导出 `Utilities`；改为由 ABI 模块直接再导出，链不断，预计不用改。落地时编译确认。
- **swift-decompiler**：经 `import MachOSwiftSection` 与 Swift 层模块的再导出用到 `DependencySearchPath`、`InProcessContext`，再导出链不变，预计不用改。落地时编译确认。
- **REAgent**：钉死 MachOSwiftSection 0.15.2，不受影响。
- **MachOObjCSection**：不受影响；前置提案已把它对本包的范围放宽到 3.0.0 之前。
- **工作区**：`MxIris-Reverse-Engineering.xcworkspace` 与 `-Next` 只列包，不涉及 product，不用改。

### 文档与示例

- 本包 README 的 product 表与「Since 2.0.0」一段补上新 product。
- MachOSwiftSection 的 README product 表、AGENTS.md 的模块层次图与模块说明、Glossary、ProjectMap、模块文档按改动地图同步。

## API 演进与废弃策略

- 被替代的旧 API：MachOSwiftSection 的 `SymbolIndexStore`、`DependencyValues.symbolIndexStore`、`.symbolStore` 直接改名，不留废弃别名（理由见源码兼容性）。
- 废弃期：无。
- 版本号：本包 2.0.0（与前置提案共用，大版本已因模块重名而跃迁）；MachOSwiftSection 0.25.0。2.1.0 的 C++ 归类只新增 API。

## 落地步骤

前提：前置提案的两条功能分支（本包与 MachOSwiftSection 的 `feature/move-reading-and-resolving-modules`）已推送。本提案在两边各开 `feature/move-macho-infrastructure-modules`，从它们切出，worktree 按 `create-worktree` skill 放在各自的 `.worktrees/<项目名>-MoveMachOInfrastructureModules`。联调时本地依赖目录必须真叫 `MachOKitExtensions`（前置提案决策日志 2026-11-11 的做法）。

1. **本包迁入四个模块** —— 改动地图步骤 1 各行。先一个提交原样复制，再一个提交做编译所需的修改。
   - 行为：`sharedCacheResolvesEachKeyOnceUnderConcurrency`（搬来的 `SharedCacheTests` 全部通过）
   - 行为：`sharedCacheReentrantResolveTraps`
   - 行为：`evictionFollowsFollowerGroups`（搬来的 `SharedCacheRegistryTests`）
   - 行为：`fileDependencyLocatorResolvesHostCacheImagesByExactPath`（搬来的 `MachODependenciesTests` 全部通过）
   - 行为：`relativeDirectPointerResolvesToTargetInProcessMemory`
   - 行为：`relativeIndirectPointerReadsTargetThroughSlot`
   - 行为：`relativePointerIntPairSeparatesFlagBits`
2. **`MachOSymbols` 的通用部分与采集** —— 改动地图步骤 2 各行。
   - 行为：`symbolLanguageClassifiesSwiftManglingPrefixes`
   - 行为：`symbolLanguageClassifiesSymbolicManglingNamesAsSwift`
   - 行为：`symbolLanguageClassifiesItaniumNamesAsCPlusPlus`
   - 行为：`symbolLanguageClassifiesMethodImplementationsAndRuntimeSymbolsAsObjectiveC`
   - 行为：`symbolLanguageFallsBackToC`
   - 行为：`stringAndByteClassificationAgreeOnEveryNameOfARealImage`
   - 行为：`sweepFilesEachNameIntoTheTableItsRoutingChooses`
   - 行为：`sweepSkipsImportedSymbols`
   - 行为：`tableNotIndexedByOffsetHasNoOffsetRows`
   - 行为：`debugEntryReservesARowWithoutAnOffset`
   - 行为：`mappedAndDecodedLegsYieldTheSameTable`
   - 行为：`nameLookupFindsEveryRowByBinarySearch`
   - 行为：`exportFactsAreNilForAnImageWithoutAnExportTrie`
   - 行为：`exportTrieNameWithoutASymbolTableEntryGetsARow`
   - 行为：`cacheImageRowsPointIntoTheMappedStringTable`
   - 行为：`imageOutsideTheCacheCopiesNamesUnlessTheRoutingAllowsMapping`
   - 行为：`packedNameReferenceRefusesOversizedGeometry`（搬来的通用半）
3. **C/C++ store 与 `MachOFoundation`** —— 改动地图步骤 3 各行。
   - 行为：`storeFindsMainByNameInAnExecutable`（`/usr/bin/curl`，主可执行文件的 `__TEXT` 不在 0，偏移必须是文件偏移）
   - 行为：`storeFindsSymbolsAtAnExactOffset`
   - 行为：`closestSymbolsReturnsTheEnclosingFunction`
   - 行为：`closestSymbolsIgnoresRawVirtualAddressKeys`
   - 行为：`storeNeverContainsSwiftNames`（本机 cache 的 libswiftCore：有 C 名字、没有 `$s` 名字）
   - 行为：`storeAnswersIsExportedTriState`
   - 行为：`storeIsBuiltOnceAndSharedAcrossCallers`
   - 行为：`removeEvictsTheImageIndex`
   - 行为：`wrappedReaderSeesTheSameOffsetsAsTheReaderItWraps`
4. **MachOSwiftSection 删掉迁走的模块** —— 改动地图步骤 4 各行。
   - 行为：全量构建通过；`DependencyClosureTests` 在 `IntegrationTests` 里照常通过。
5. **`SwiftSymbols`** —— 改动地图步骤 5 各行。先一个提交做目录与 target 改名、类型改名、import 改名（纯机械），再一个提交把采集换成 `SymbolSweep`。
   - 行为：`swiftRoutingFilesSymbolicManglingNamesIntoTheirOwnTable`
   - 行为：`symbolLanguageSwiftMatchesDemanglingIsSwiftSymbol`（替代原 `SymbolTableEquivalenceTests` 的字节判断用例）
   - 行为：`noUnrenamedSymbolIndexStoreInSourcesOrTests`
   - 行为：MachOSwiftSection 全量测试通过；渲染 A/B 逐字节一致。
6. **MachOSwiftSection 的命名收尾** —— 改动地图步骤 6 各行。
   - 行为：`ContinuousIntegrationTestFilterTests` 通过；重新生成的 `AllFixtureSuites.swift` 与改名后的模块一致；全量测试通过。
7. **文档** —— 改动地图步骤 7 各行；本提案头部登记配套文档。
8. **自审与验证**：两个仓库全量测试；渲染 A/B；内存记录；在决策日志写下结果。功能分支只推送，不合进任何常驻检出（与前置提案相同的理由：本包 `main` 一合入，旧工作区就报模块重名）。
9. **落地（与前置提案、MachOSwiftSection 0.25.0 同一天）**：按前置提案决策日志里「落地那天要做的」清单执行，并插入本提案的分支——本包先合前置提案的分支、再合本提案的分支，发 2.0.0；MachOSwiftSection 同样先后合入 `next`，随 0.25.0 发布；两份提案各自取号、改 Implemented，MachOSwiftSection 的提案索引各加一行跨仓库链接。

**收尾时必须判断两件事**（判断结果写进决策日志）：

- 要不要配套专题文章：计划写三份实现说明（见「详细设计 · 文档」）；调用方契约（偏移的口径、`closestSymbols` 不设上限、`isExported` 的三态、`remove(for:)` 由调用方负责）写进 `SymbolIndexStore` 的文档注释，是否另写使用指南在收尾时判断。
- 有没有引入新术语：「routing」「sweep」「零拷贝行（mapped row）」是否进术语表，在收尾时判断；本包目前没有术语表，MachOSwiftSection 的术语表有 `SymbolIndexStore` 等词条要改。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-18 | Created as Draft | 用户要在本包建一个只处理 C 与 C++ 符号的 `SymbolIndexStore`，Swift 的逻辑经继承或钩子在 MachOSwiftSection 那边接上；随后把范围扩大到 MachOSwiftSection 里全部 MachO 开头的模块。按完整档提问四轮后写成本提案。 |
| 2026-11-18 | C/C++ 索引要做结构化归类 | 用户选择：不止按地址、名字、是否导出查询，还要按类、命名空间、成员归类 C++ 符号。否决：只做查询与字符串 demangle。 |
| 2026-11-18 | 扩展方式：共享底层加协议钩子 | 用户选择。两个 store 各有缓存与生命周期，Swift 的 demangle 分类不进本包。否决：类继承（存储形状不同、`final` 单例、热循环动态派发）；一次扫描喂两边（建表与驱逐绑死）。 |
| 2026-11-18 | 本包沿用 `MachOSymbols`，Swift 部分改名 `SwiftSymbols` / `SwiftSymbolIndexStore` | 用户选择。名字与内容对得上。否决：本包另起名。 |
| 2026-11-18 | 随 2.0.0 一起落地 | 用户选择。只发一次大版本、只切一次。否决：2.0.0 之后单独发（会与 0.25.0 的同名模块冲突，要再发 3.0.0）。 |
| 2026-11-18 | 范围扩大到全部 MachO 模块 | 用户决定：MachOSwiftSection 里带 MachO 前缀的只留 ABI 模型 `MachOSwiftSection`，其上的模块一律以 Swift 开头。核实过除 `MachOSymbols` 的 Swift 那半外，这些模块都不含 Swift 内容，当初就是为拆分而写。 |
| 2026-11-18 | `MachOMacros` 留在 MachOSwiftSection，改名 | 用户选择。本包不引入 swift-syntax。否决：迁入本包。 |
| 2026-11-18 | `Utilities` 先定迁入、后改为留下 | 第二轮提问时以「迁入的模块都用到它」为前提，用户选了改名 `MachOUtilities` 迁入。随后核实这个前提不成立：迁入的模块只有空 import，真正的使用者是 Swift 层，且它的声明多为 `package`、跨包后只能公开。据此重新提问，用户改为留在 MachOSwiftSection、不改名。 |
| 2026-11-18 | C++ 结构化归类放到 2.1.0，另写提案 | 用户选择。它只新增 API，不需要大版本；0.25.0 的落地不必等新的解析器。否决：随 2.0.0 一起。 |
| 2026-11-18 | C++ 解析器引入 LLVM `ItaniumDemangle` | 用户定的规则：依赖干净就引入，依赖多就用 Swift 自己写。核实它除 C++ 标准库外只依赖一个可替换的配置头文件，按规则引入；具体做法留给 2.1.0 的提案。 |
| 2026-11-18 | 共识确认，开始写提案 | 用户批准已定的决策与以下默认做法：另写一份提案叠在前置提案上；MachOSwiftSection 的 `MachOMacros` 与测试支撑模块改用 `SwiftSection` 前缀；`SharedCache` 与 `MachOCacheStorage` 并存；只测迁入模块的测试搬来、依赖 Swift 样本的留下；下游一起改；迁入的代码不带 FrameworkToolbox、MemberwiseInit、swift-dependencies，锁换 `NSLock`。 |
| 2026-11-18 | 写提案时定下的做法 | 未单独提问、写进简报供用户推翻：`SymbolLanguage` 放在本包，Swift 前缀也由它判断（C/C++ store 要排除 Swift 名字）；C/C++ store 把 ObjC 名字当作 C 一样收；零拷贝只用于 dyld shared cache 里的镜像与声明了镜像不会卸载的 routing；新增 `closestSymbols(at:in:)`；共享的构件放在 `@_spi(Internals)`；2.0.0 不做 C++ 字符串 demangle；`MachOSwiftSectionC` 不改名；`SwiftSymbols` 放进新的层分组 `Symbols/`；ABI 模块直接再导出 `Utilities`。 |
| 2026-11-18 | 状态 → Accepted | 用户批准，开始实现。 |
| 2026-11-18 | 开始实现 | 两个仓库各建 `feature/move-macho-infrastructure-modules`，从各自的 `feature/move-reading-and-resolving-modules` 切出。本包的功能分支并入了 `main`，让提案跟着分支更新。 |
| 2026-11-18 | MachOSwiftSection 的功能分支先并入 `origin/next` | 迁移分支比 `origin/next` 落后 84 个提交，而本提案要在 MachOSwiftSection 里大面积改名（约 150 处类型引用、约 680 个测试文件的 import）。先并入再改，落地那天要解的冲突少得多；合并没有冲突。渲染 A/B 的基线因此改为「迁移分支并入同一个 `origin/next`」的检出，两边只差本提案。 |
| 2026-11-18 | 本地联调用沙盒 | 照前置提案的做法：`/Volumes/DerivedData/Agents.noindex/claude/LocalDependencies/MoveMachOInfrastructureModules/` 里放本包功能分支的同步副本（目录名正好是 `MachOKitExtensions`）与 MachOObjCSection `origin/next` 的导出，MachOKit、swift-objc-dump、swift-semantic-string、FrameworkToolbox 链接到与 MachOSwiftSection 的 `.worktrees/` 相同的目标；MachOSwiftSection 功能 worktree 的 `Package.swift` 临时（不提交）指向这两个快照。共享的 `.worktrees/` 链接一律没动。 |
