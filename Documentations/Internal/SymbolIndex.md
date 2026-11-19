# MachOSymbols：符号表、采集与 C/C++ 符号索引

> 实现说明，随代码维护。读者：维护者。
> 2026-11 由 MachOSwiftSection 的 `MachOSymbols` 拆出（提案 [0003-move-macho-infrastructure-modules](../Evolutions/0003-move-macho-infrastructure-modules.md)）；同月 Swift 与 Objective-C 的名字判断移回各自的包，本包只认 C 与 C++（提案 [draft-split-symbol-language](../Evolutions/draft-split-symbol-language.md)）。Swift 那一半——demangle、按成员 / 类型 / witness 归类——留在 MachOSwiftSection，模块名 `SwiftSymbols`，说明见它的 [SwiftSymbols.md](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Internal/Modules/SwiftSymbols.md)。

## 模块定位

`MachOSymbols` 回答「一个镜像的这个偏移上是什么符号、这个名字在哪个偏移、是否导出」，不懂任何一种语言的语法。它由四部分组成：

1. **符号表**（`SymbolTable` 与它的 builder）：每个唯一名字一行 16 字节，名字的字节或指向镜像的字符串表、或进表自己的私有缓冲。
2. **采集**（`SymbolSweep`）：一趟扫完一个镜像的符号表与导出表，按调用方给的 **routing**（`SymbolTableRouting`）把每个名字分进几张表，每张表带自己的按偏移索引、导出信息与本地符号事实。
3. **语言**（`SymbolLanguage` 与 `SymbolLanguageRegistry`）：本包只认 C++ 的 Itanium 前缀，其余语言由拥有它的包在镜像加载时注册。
4. **store**：本包的 `SymbolIndexStore` 收 C 与 C++ 的名字，已注册语言的名字只留偏移作边界；MachOSwiftSection 的 `SwiftSymbolIndexStore` 收 Swift 名字，在同一趟采集上再 demangle、归类。两个 store 各有各的缓存与驱逐组，互不相干。

采集与符号表放在 `@_spi(Internals)` 下：它们是给「别的 store」用的构件，不是承诺给所有调用方的 API。`SymbolIndexStore`、`SymbolLanguage` 与 `SymbolLanguageRegistry` 是正式公开的。

## 文件 → 子系统

| 子系统 | 文件 |
|---|---|
| 符号表 | `SymbolTable`（`SymbolRow`、`PackedNameReference`、`SymbolTable`、`SymbolTableBuilder`）、`SymbolRowBucket` |
| 偏移换算与 nlist 判断 | `SymbolValueOffsetConverter`、`NlistProtocol+`（`isExternal`、`isLocal`、`isDebuggingEntry`） |
| 语言 | `SymbolLanguage`、`SymbolLanguageRegistry`（含 `SymbolLanguageRegistration`、`SymbolLanguageClassifier`） |
| 采集 | `SymbolTableRouting`（含 `SymbolOffsetIndexing`）、`SymbolSweep`（含 `SweptSymbolTable`、`SymbolExportFacts`） |
| C/C++ store | `SymbolIndexStore`、`SharedCacheEvictionGroup+MachOSymbols`（`.symbolStore`） |

## 符号表

结构与取舍来自 MachOSwiftSection 提案 0001（符号名 offset 化）与 0003（行号桶扁平化），迁入时原样保留：

- 行 = 规范化偏移（8 字节）+ 打包的名字引用（1 位来源、1 位 `isExternal`、22 位长度、40 位偏移）。超出打包预算的名字（只可能来自畸形或恶意的输入）拒绝建行，不 trap。
- 名字反查是在按名字排序的行号排列上做字节级二分；`SymbolRowBucket` 让绝大多数「一个偏移一行」的情况内联存放。
- **零拷贝的前提**：行指向镜像字符串表，镜像一卸载就悬空。dyld 把带 Swift / ObjC 内容的镜像钉住不卸载（MachOSwiftSection `ReviewAdjudications.md` A4，2026-08-09 实测），但纯 C 镜像可以 `dlclose`。所以采集只在两种情况下让行指向字符串表：镜像在 dyld 共享缓存里（看 mach header 的 `isInDyldCache`，与本包 `MachOImage.cache` 同一个依据），或 routing 声明了 `mayReferenceStringTablesOfLoadedImages`（Swift 的 routing 声明了，C/C++ 的没有）。其余情况名字复制进私有缓冲。
- `retainedByteCount` / `privateNameByteCount` 给内存普查用：行、排列与私有缓冲的字节数，镜像的字符串表不计。

## 语言（`SymbolLanguage` 与 `SymbolLanguageRegistry`）

只看名字开头的字节，不 demangle。`SymbolLanguage` 是以字符串 `rawValue`（给人看的语言名）为身份的 struct，别的包在扩展里加静态成员。一个名字的语言按这个顺序定：

1. **C++**（本包内置）：`__Z`、`___Z`（C++ 函数里的 block）。在任何注册的语言之前判，注册的识别器看不到这些名字。
2. **已注册的语言**，按注册顺序，第一个认领的胜出。目前有两门，前缀表都在各自的包里：
   - Swift：MachOSwiftSection 的 `SwiftSymbols`（`.swift`），前缀与 swift-demangling 的 `isSwiftSymbol` 等价，由它的 `SymbolTableEquivalenceTests` 在真实符号表上钉住。
   - Objective-C：MachOObjCSection（`.objectiveC`），`-[`、`+[`、`_OBJC_`、`__OBJC_`、`l_OBJC_`、`L_OBJC_`、`_objc_msgSend$`。
3. **C**：其余一切，包括所属的包不在进程里的语言的名字。

**注册在镜像加载时自动发生。** 拥有语言的包放一个 C target，里面一个 `__attribute__((constructor))` 函数调用该包用 `@c`（6.2 工具版本用 `@_cdecl`）导出的 Swift 注册函数；Swift target 依赖这个 C target，链接它就带上了 constructor，调用方什么都不用做。2026-11-19 的原型确认：探针程序不引用注册模块的任何符号，`swift build` 的 debug、release 与 `xcodebuild` 的 Release 都在加载时拿到了注册。纯 Swift 的写法——SE-0492 的 `@section("__DATA,__mod_init_func,mod_init_funcs") @used` 放一个 `@convention(c)` 闭包——在 Swift 6.4.2 上链接失败（`ld: fixup error (kind=arm64_adrp_lo12) … ADRP out of range`），变量改成 `private` 也一样，所以用 C target。

注册表的规则：

- 同一语言重复注册保留第一次的识别器（同一个包可能被两个镜像各带一份）；注册 `.c`、`.cPlusPlus` 是程序员错误（`precondition`）。
- 每次登记新语言，注册表的「代数」加一。采集开始时取一份快照（`SymbolLanguageClassifier`：识别闭包数组的拷贝加当时的代数），逐名字判定时不碰锁。
- 识别闭包对采集到的每个名字都要调一次，只该看名字开头几个字节。

## 采集（`SymbolSweep`）

routing 有三个要求，正好是两个 store 在采集里不同的地方：名字进哪张表（或不收）、每张表怎么按偏移索引（`SymbolOffsetIndexing`：`.nameOnly`、`.byOffset`、`.byOffsetWithSortedOffsets`、`.sortedOffsetsOnly`）、是否允许零拷贝。routing 拿到的 `SymbolLanguage` 来自采集时给的注册表（默认 `.shared`）。其余规则对所有 routing 一样：

- 导入（`N_UNDF` 且 `N_EXT`，即 `isExternal`）永远不收。注意 `isExternal` 只指导入，导出的定义同样带 `N_EXT`。
- 调试条目（STABS）只占行：名字还没有行时建一个占位行，此后不改它的偏移、不登记到任何偏移。行序因此跟着调试映射走，也就是源码顺序。
- 文件的符号值是虚拟地址，经 `SymbolValueOffsetConverter` 换成规范化偏移（独立文件是文件偏移，cache 里的镜像是「地址 − 共享区起点」）；行同时登记在原始值与规范化偏移下。进程内镜像两者相等。
- 一个偏移可以有多行（别名、identical code folding），一行在一个偏移下只登记一次；判断不扫桶，靠「新铸的行号一定比已发出的都大」。
- **同名多处定义**：链接后的镜像里 C 名字常常重名（不同目标文件里同名的 static 函数、`ltmp0`）。一个名字只有一行，偏移取最后一次出现，但每次出现的偏移都会登记这一行。所以不能用「行的偏移等于键」去判断一个键是不是规范化偏移——`.byOffsetWithSortedOffsets` 正是为此在登记时直接记下规范化偏移。
- 导出表：每个条目都算「有导出信息」（不管 routing 收不收）；routing 收下的名字已有行就记导出位，没有行但有偏移就铸一行，铸不出或没有偏移（re-export）就记进 name-only 集合。`SymbolExportFacts.isExported` 因此是三态：没有导出信息时答 `nil`。
- `.sortedOffsetsOnly` 的表不建行、不存名字（已加载镜像那一路连 `String` 都不生成），只留升序去重的规范化偏移；偏移只取符号表，导出表一路不登记它（导出的符号本来也在符号表里）。
- **已知问题（后续项）**：导出表一路给文件加的偏移起点是 `machO.startOffset`，对胖二进制的切片就是切片在胖文件里的起点（`/usr/bin/curl` 的 arm64e 切片是 278528），而符号表一路算出的是切片内偏移。只影响「只在导出表、不在符号表」的名字铸出的新行。

## C/C++ store（`SymbolIndexStore`）

- 两张表：`.c` 与 `.cPlusPlus` 的名字进 `.symbols`（`.byOffsetWithSortedOffsets`，不允许零拷贝，共享缓存里的镜像除外）；其余名字——即已注册语言的——进 `.boundaries`（`.sortedOffsetsOnly`），只留偏移。
- **索引的内容取决于进程链接了哪些包**：链接了 `SwiftSymbols` 就不含 Swift 名字，链接了 MachOObjCSection 就不含 Objective-C 名字；两者都没链接时（例如 MachOKitUI 关掉 SwiftSection trait 的构建），它们按 C 收进来。
- 查询：`symbols(for:in:)`（恰好在这个偏移）、`closestSymbols(at:in:)`（不晚于这个偏移的最大偏移上的全部名字，二分 `sortedCanonicalOffsets`，不设距离上限）、`offset(ofSymbolNamed:in:)`、`containsSymbol(named:in:)`、`isExported(name:in:)`、`hasExportInformation(in:)`。方法名沿用 Swift store 的同名查询。
- **边界**：`closestSymbols` 同时在 `.boundaries` 里找不晚于目标的最大偏移；它比最近的 C/C++ 偏移更靠后时答 `nil`——地址落在别的语言的代码里，不再答出前面一个不相干的 C 函数。同一偏移两边都有（别名、相同代码折叠）时由 C/C++ 符号作答。按名字、按精确偏移与导出的查询只看 `.symbols`。
- **晚注册**：索引记下建它时快照的代数。查询时注册表的代数比 store 上次见到的新，就先清空整个缓存；取到的索引代数仍旧（建索引途中有人注册），就把这一份删掉再建。
- `offset(ofSymbolNamed:)` 与 `containsSymbol` 只认登记过偏移的名字：只被调试条目提到的占位行不算。
- 偏移的口径与本包其余读取一致：独立文件是文件偏移，cache 镜像是「未滑动地址 − 共享区起点」，进程内镜像是距 mach header 的距离。镜像里确有负偏移的符号（cache 镜像的某些绝对符号），`closestSymbols(at: -1)` 不一定是 `nil`。
- 缓存是 `SharedCache<Storage>(evictionGroup: .symbolStore)`，没有任何 indexer 认领它；镜像不再需要时由调用方 `remove(for:)`。键按 `SharedCacheKey`：同一个文件（同一 `LC_UUID`）的两个 `MachOFile` 实例共享一份索引，包装读取器与它包着的读取器也共享。
- 不 demangle C++：要可读的名字暂时用 MachOKit 的 `demangledName`。结构化的 C++ 归类（按类、命名空间、成员）计划引入 LLVM 的 `ItaniumDemangle`，另有提案，与本节的语言拆分一起随 3.0.0 发布。

## 内存与耗时（2026-11-19，macOS 27.2 的 AppKit，`symbolIndexCensusOfALargeImage`）

普查在注册了 Swift 与 Objective-C 运行时两个替身语言的注册表上量，即进程链接了两个下游时的构成。替身只认 `_OBJC_` 开头的 ObjC 名字，比 MachOObjCSection 的规则窄，见 `Tests/MachOSymbolsTests/StandInLanguages.swift`。

| 读取器 | 行数 | 符号表（其中复制的名字） | 偏移索引的键 | 有序偏移 | 边界偏移 |
|---|---|---|---|---|---|
| 本机 dyld 缓存里的 `MachOFile` | 151,422 | 10.6 MB（7.6 MB） | 340,994 个，至少 8.2 MB | 1.4 MB | 13,718 个，0.1 MB |
| 进程内的 `MachOImage` | 151,422 | 3.0 MB（0） | 170,497 个，至少 4.1 MB | 1.4 MB | 13,718 个，0.1 MB |

- 2.0.0 的同一普查（2026-11-18，索引收 C、C++ 与 ObjC）是 161,089 行、文件的符号表 11.1 MB；ObjC 运行时名字离开索引后少了约 9,700 行，边界只多 0.1 MB。
- 耗时：同一个普查测试（建文件与镜像两份索引）在 release 下各跑三次，2.0.0 为 0.312–0.365 秒，拆分后为 0.308–0.340 秒。每个名字多一次识别闭包调用，看不出代价。

- 文件的名字要复制进私有缓冲，进程内的缓存镜像零拷贝，差出 7.9 MB。
- 文件的每一行同时登记在原始地址与规范化偏移下，偏移索引的键是镜像的两倍。C/C++ store 的查询只按规范化偏移问，原始地址的键对它没有用：给 `SymbolOffsetIndexing` 加一档「只登记规范化偏移」可以省下约一半，留作后续。
- 「至少」是键与桶本身的字节数，不含 `Dictionary` 的空槽与元数据。

## 契约与坑

- **测试不要往共享注册表注册**：`SymbolLanguageRegistry.shared` 的登记撤不掉，而且会清空共享 store。本包的测试用独立的注册表实例和 `SymbolIndexStore(languageRegistry:)`（内部初始化方法）；替身语言在 `Tests/MachOSymbolsTests/StandInLanguages.swift`。
- **比较语言要 import 定义它的模块**：`.swift` 在 MachOSwiftSection 的 `SwiftSymbols`，`.objectiveC` 在 MachOObjCSection。
- **Swift 侧不要写裸的 `SymbolIndexStore`**：MachOSwiftSection 的 Swift store 叫 `SwiftSymbolIndexStore`，两者的查询方法同名，写错名字会悄悄编到 C/C++ store 上、查不到任何 Swift 名字。MachOSwiftSection 的 `SymbolIndexStoreNamingScanTests` 扫源码钉住。
- **MachOKit 读不了内核文件的段地址**：`/System/Library/Kernels/kernel` 的地址在 `0xffffff80…`，超出 `Int`，读段地址时 trap。测试里「没有导出表」的样本因此用 SDK 的 `usr/lib/lazydylib1.o`。
- **`MachOImage(name:)` 取文件名第一个点之前的部分**：libc++ 是 `"libc++"`，不是 `"libc++.1"`。
- **`MachOKitExtensions` 模块不再导出 `MachOSymbols`**：这里的 `SymbolIndexStore`、`Symbol`（来自 `MachOResolving`）与 MachOKit 的 `Symbol` / `SymbolProtocol` 同名，再导出会让同时 import 两者的文件歧义。

## 测试

- `Tests/MachOSymbolsTests/SymbolLanguageTests`：C++ 不靠注册就认得；没人认领的都是 C（Swift、ObjC 名字也是）；注册的语言认领它的名字、C++ 先判、先注册的胜出、重复注册保留第一次、注册内置语言是程序员错误（exit test）；`String` 与字节两种入口在三个已加载镜像的每个名字上答案一致，且只见 C 与 C++。
- `Tests/MachOSymbolsTests/SymbolSweepTests`：分表（用替身语言）、采集按给定的注册表分类、导入不收、`.nameOnly` 表没有偏移索引、`.sortedOffsetsOnly` 表只留偏移且不收调试条目与原始地址、调试条目不改偏移（读测试 bundle 自己的调试映射）、两条采集腿等价、二分查找、无导出表时三态为 `nil`、带偏移的导出名都有行、本地符号不算导出、主可执行文件按文件偏移登记、零拷贝规则、有序偏移只在要求时保留。
- `Tests/MachOSymbolsTests/SymbolIndexStoreTests`：store 的每个查询，样本是 `/usr/bin/curl`、`/usr/bin/zip`、已加载的 Foundation 与 libswiftCore；排除已注册语言、没注册的按 C 收、边界上答 `nil`、别名偏移由 C 名字作答、注册后重建与整体清空。
- `Tests/MachOSymbolsTests/PackedNameReferenceBudgetTests`：打包预算、一行 16 字节、行桶契约、字节统计。
- `Tests/MachOKitExtensionsTests/WrappedReaderSymbolIndexTests`：经包装读取器建的索引，偏移与直接读文件时一样。
