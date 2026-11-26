# MachOCodeReferences

交叉引用分析与语言无关的核心层：读取层（`CrossReferenceMemory`，进程内与文件两种实现）、与读取器无关的镜像描述 `CodeImage` 与 `__LINKEDIT` 读法 `ImageLinkEdit`、镜像集 `CodeImageSet`（进程内、cache 文件、一组独立文件三个构造器；镜像、路径、内存区间、按镜像缓存的函数表、链接关系与改名再导出）、函数表 `ImageFunctionTable` 与它的附件机制、指令扫描 `ReferenceScanner` 与寄存器跟踪 `RegisterFile`、调用目标解析 `CallTargetResolver`、按导入名与链接关系预筛、导出表起名 `ExportedFunctionNames`、地址结构判断 `AddressPlace`，以及识别器扩展点（`CodeReferenceRecognitionSession`、`CodeReferenceRecording`）。

- 来历：MachOSwiftSection 提案 0097（离线交叉引用与地址符号化）在那边把交叉引用拆成三层，核心层叫 `CrossReferenceCore`；MachOSwiftSection 提案 [0098 move-cross-reference-layers](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0098-move-cross-reference-layers.md) 把它搬来本包，改名 `MachOCodeReferences`，随 2.0.0 发布。
- 依赖：MachOKit（两处 `@_spi(Support)`，为了 `MemoryTrieTree`）、`MachOKitExtensions`、`MachOReading`（只用 `InProcessContext.addressMask`）、[MachOAddressResolution](MachOAddressResolution.md)（文件模式的槽解析与地址空间）、[ARM64InstructionDecoding](ARM64InstructionDecoding.md)、FrameworkToolbox 的 `OSToolbox`（只为 `Mutex`）。
- 使用方：MachOObjCSection 的 `ObjCCodeReferences`（ObjC 层）与 MachOSwiftSection 的 `CrossReferenceAnalysis`（Swift 层兼对外的分析器 `CrossReferenceAnalyzer`）。

## 接口只给 MachOSwiftSection 用

- 除了四个值类型，接口都是 `@_spi(Internals) public`：搬来之前它们是 MachOSwiftSection 包内的 `package`，跨包之后只能用 SPI。SPI 不承诺稳定，随时可能改，不算破坏性变更。
- 真正公开的只有 `CodeLocation`、`CodeReferenceKind`、`CodeReferenceRoute`、`IndirectCallEvidence`，它们经 MachOSwiftSection 的 `CrossReferenceAnalysis`（`@_exported import`）成为那边公开 API 的一部分，照常守 semver。
- 单用本包做不了交叉引用：对外的分析器、引用目标 `CodeReferenceTarget`、引用表与常驻索引都在 MachOSwiftSection。没有 Swift 层时引用目标用什么类型表示，等真有不经 MachOSwiftSection 的使用方时再定。

## 不认识任何一种语言

- 核心经识别器接纳各语言层：语言层为每次扫描建一个会话，核心只在五个时机问它（进入函数、解析不认识的调用目标、调用点、算出地址、读槽），扫完函数时再告诉它一声（`leaveFunction()`），会话产出的引用记到语言层自己的记录协议上，不经核心转手。
- 源码里不许出现 `objc_` / `swift_` 开头的字符串字面量：运行时的名单属于各自的层，由使用方经 `RuntimeLibraryRules` 交给核心（`SourceScanTests.coreSpellsNoRuntimeSymbolName`）。
- `IndirectCallEvidence` 只记调用点看得出的事实：载入的位移、arm64e 的鉴别常量、是否混入地址。从哪种表载入（vtable、见证表）是语言的知识，搬来时删掉了从来只写 `.none` 的 `table` 字段。
- `CoreOnlyScanTests.theCoreScansWithOnlyARecognizerFromTests` 不装任何语言层，只装测试里定义的一个识别器，驱动扫描器扫完 Foundation：所有调进 libobjc 的调用都由这个识别器代为记录，证明扩展点是开放的。

## 内存与平台

- 只有 `InProcessCrossReferenceMemory` 把地址变成指针（`SourceScanTests.onlyInProcessMemoryTurnsAddressesIntoPointers`）；剥签名用平台的掩码 `InProcessContext.addressMask`，不写常量（`coreDefinesNoAddressMaskConstant`，白名单只有 slide info v5 的 34 位 `runtimeOffset` 字段）。
- 进程内部分只在 Darwin 上有：`InProcessCrossReferenceMemory` 整个文件、`CodeImageSet.inProcess(...)`（`canImport(Darwin) && arch(arm64)`）。文件模式（`FileCrossReferenceMemory`、从 `FullDyldCache` 或一组 `MachOFile` 建镜像集）与平台无关。本包承诺 Linux，但这个模块在 Linux 上没有编过，也没有 Linux CI。

## 怎么工作

各子系统的分工、关键契约、文件模式、引用路线、地址符号化与吞吐实测，写在 MachOSwiftSection 的 [Modules/CrossReferenceAnalysis.md](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Internal/Modules/CrossReferenceAnalysis.md)：三层的代码一起演进，那份文档是它们的总说明，这里不重复。

## 算出的地址落在槽上、函数起点（MachOSwiftSection 提案 0113）

MachOSwiftSection 提案 [0113-cross-reference-recall-gaps](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0113-cross-reference-recall-gaps.md) 的复测在 Finder 26.5.2 与 ControlCenter 26.7 上找到几处扫描漏记，核心层补了三条：

- **算出的地址落在引用槽上，就在这条指令上按读槽处理。** `adrp; add` 或 `adr` 算出的地址是本镜像的 GOT、会话报的引用节（`__objc_classrefs`），或 cache 的共用 GOT 池里的槽时，走 `noteSlotReference(fromSlot:at:)`，路线记 `.pointerSlot`。优化过的 Swift 代码把 ObjC 类的 GOT 槽地址放进 `x2` 交给合并后的元数据访问器（`$sSo…CMaTm`），自己从不载入，ControlCenter 有 554 处。共用 GOT 池的判断（`isSlotOutsideEveryImage`）按地址记在地址认领缓存里（`referenceSlotClaim`）。
- **算出的地址落在会话观察的槽上，就在这条指令上通知会话。** 观察的槽是 ivar 偏移变量（`__objc_ivar`）、`__objc_superrefs`、`__objc_selrefs`。Finder 的 `-[TTaskErrorOrConflictViewController setResolutionsForKind:]` 在两条路径上各算一个 ivar 偏移变量的地址，汇合到同一条 `ldrsw x9, [x9]`；汇合处 `x9` 两边不一致、按规则作废，载入处就认不出读的是哪个，所以只有算地址的那条指令能说出它。
- 两种情况都给寄存器打上「已记过」的位（`RegisterFile.markRecordedSlotAddress(of:)`），之后经它做零位移的 64 位或 32 位载入不再重记，免得 `adrp; add; ldr [x]` 记成两行；寄存器里的地址照常保留，后面的发送仍能认出类字面量接收者。这个位随寄存器改写清掉、随 `mov` 复制、汇合时比较。不用 `setTag`：打标记会把寄存器改成 `.tagged` 状态，地址就没了。
- **算出的地址是本镜像的函数起点时，记成对函数的引用**（`CodeReferenceRecording.recordFunctionAddressReference(to:at:)`，种类 `.reference`、路线 `.addressMaterialization`），只在扫描器以 `recordsFunctionAddressReferences: true` 构造时记：建栈上 block 的函数、把回调交给 `dispatch_async_f` 的函数、返回闭包的函数因此成了被引用函数的「调用者」。会话照常再被问一次（Swift 会话把访问器地址认领为类型引用，两条都记）。
- 会话协议加了 `leaveFunction()`：扫描器扫完一个函数时调用，协议扩展给空实现。ObjC 层用它冲刷没被发送用掉的 selector 载入。

为此扫描器在任何会话观察槽时都要看算出的地址（`looksAtBuiltAddresses`），而 ObjC 会话总是观察 `__objc_superrefs`，所以每个 `add` / `adr` 都会进 `noteAddress`；进去后先做最便宜的判断。

## 吞吐

搬来之后量过一次（2026-11-19，JHs-Mac-Studio-Ultra，macOS 27.2，Xcode 26.6，release，MachOSwiftSection 的 `ScanThroughputBenchmarkTests`）。两侧交替各跑三轮、每项取最好：基线是 MachOSwiftSection 的 `origin/next`（三层都还在那边），候选是三个仓库的 `feature/move-cross-reference-layers`（同时包含两份搬迁提案）。

| 操作 | 基线 | 候选 |
|---|---|---|
| 进程内：建分析器 | 0.056 秒 | 0.055 秒 |
| 进程内：每个镜像都建整表（约 1.30 亿条引用） | 2.67 秒 | 2.53 秒 |
| 进程内：`init` 的调用者（预筛 2,880 个镜像 + 扫描） | 0.035 + 1.71 秒 | 0.034 + 1.53 秒 |
| 进程内：`makeKeyAndOrderFront:` 的调用者（105 个镜像） | 0.059 + 0.317 秒 | 0.058 + 0.293 秒 |
| 归档 macOS 27.2 cache 文件：建分析器 | 0.158 秒 | 0.154 秒 |
| 文件：进程里第一次查 `makeKeyAndOrderFront:` / `init` 的调用者 | 0.50 / 1.88 秒 | 0.47 / 1.68 秒 |
| 文件：每个镜像都建整表（128,120,075 条引用，两侧相同） | 2.75 秒 | 2.51 秒 |
| 文件：`init` 的调用者 | 0.045 + 1.74 秒 | 0.044 + 1.53 秒 |
| 文件：`makeKeyAndOrderFront:` 的调用者 | 0.115 + 0.325 秒 | 0.113 + 0.301 秒 |

跨包、改成 SPI 没有让扫描变慢，各项反而快了 1% 到 11%；候选同时带着两份搬迁提案的改动，没有追是哪一处带来的。进程内整表的引用数两侧差 18,250 条，是因为进程内也扫测试进程自己的镜像，而两侧的测试二进制本来就不同；只扫 cache 的文件模式逐条数一致，三个大镜像的整表摘要也一致。

## 测试

- `MachOCodeReferencesTests`：`ScanShapesFixture` 用 `FixtureCompiler` 汇编出一个库，每个函数就是测试要钉住的指令序列——`SlotAddressScanTests`（取槽地址记在 `add` 上、经它或它的副本再载入不重记、普通的 `adrp; ldr` 照旧）、`InstanceVariableMergePointTests`（两条路径各算一个偏移变量地址、在载入处汇合；没有分支时记在 `add` 上不记在载入上）、`FunctionAddressScanTests`（`adrp; add` 与 `adr` 取函数起点记成引用、函数内部的地址不算、不要求时不记、每个进入的函数都离开一次）；`CoreOnlyScanTests`（核心单独扫描、`IndirectCallEvidence` 只剩三项）、`MalformedExportTrieTests`（导出树里畸形的长度不让读越界或陷入，在子进程里跑）、`SourceScanTests`（上面三条源码扫描）。要带 dyld shared cache 的 arm64 进程的那几条在别处跳过。
- 其余测试经分析器走，留在 MachOSwiftSection 的 `CrossReferenceAnalysisTests`；本包没有 CI，这里的测试只在本地跑。
