# MachOSymbols：符号表、采集与 C/C++ 符号索引

> 实现说明，随代码维护。读者：维护者。
> 2026-11 由 MachOSwiftSection 的 `MachOSymbols` 拆出（提案 [0003-move-macho-infrastructure-modules](../Evolutions/0003-move-macho-infrastructure-modules.md)）。Swift 那一半——demangle、按成员 / 类型 / witness 归类——留在 MachOSwiftSection，模块名 `SwiftSymbols`，说明见它的 [SwiftSymbols.md](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Internal/Modules/SwiftSymbols.md)。

## 模块定位

`MachOSymbols` 回答「一个镜像的这个偏移上是什么符号、这个名字在哪个偏移、是否导出」，不懂任何一种语言的语法。它由三层组成：

1. **符号表**（`SymbolTable` 与它的 builder）：每个唯一名字一行 16 字节，名字的字节或指向镜像的字符串表、或进表自己的私有缓冲。
2. **采集**（`SymbolSweep`）：一趟扫完一个镜像的符号表与导出表，按调用方给的 **routing**（`SymbolTableRouting`）把每个名字分进几张表，每张表带自己的按偏移索引、导出信息与本地符号事实。
3. **store**：本包的 `SymbolIndexStore` 收 C、C++、Objective-C 的名字；MachOSwiftSection 的 `SwiftSymbolIndexStore` 收 Swift 名字，在同一趟采集上再 demangle、归类。两个 store 各有各的缓存与驱逐组，互不相干。

采集与符号表放在 `@_spi(Internals)` 下：它们是给「别的 store」用的构件，不是承诺给所有调用方的 API。`SymbolIndexStore` 与 `SymbolLanguage` 是正式公开的。

## 文件 → 子系统

| 子系统 | 文件 |
|---|---|
| 符号表 | `SymbolTable`（`SymbolRow`、`PackedNameReference`、`SymbolTable`、`SymbolTableBuilder`）、`SymbolRowBucket` |
| 偏移换算与 nlist 判断 | `SymbolValueOffsetConverter`、`NlistProtocol+`（`isExternal`、`isLocal`、`isDebuggingEntry`） |
| 语言 | `SymbolLanguage` |
| 采集 | `SymbolTableRouting`（含 `SymbolOffsetIndexing`）、`SymbolSweep`（含 `SweptSymbolTable`、`SymbolExportFacts`） |
| C/C++ store | `SymbolIndexStore`、`SharedCacheEvictionGroup+MachOSymbols`（`.symbolStore`） |

## 符号表

结构与取舍来自 MachOSwiftSection 提案 0001（符号名 offset 化）与 0003（行号桶扁平化），迁入时原样保留：

- 行 = 规范化偏移（8 字节）+ 打包的名字引用（1 位来源、1 位 `isExternal`、22 位长度、40 位偏移）。超出打包预算的名字（只可能来自畸形或恶意的输入）拒绝建行，不 trap。
- 名字反查是在按名字排序的行号排列上做字节级二分；`SymbolRowBucket` 让绝大多数「一个偏移一行」的情况内联存放。
- **零拷贝的前提**：行指向镜像字符串表，镜像一卸载就悬空。dyld 把带 Swift / ObjC 内容的镜像钉住不卸载（MachOSwiftSection `ReviewAdjudications.md` A4，2026-08-09 实测），但纯 C 镜像可以 `dlclose`。所以采集只在两种情况下让行指向字符串表：镜像在 dyld 共享缓存里（看 mach header 的 `isInDyldCache`，与本包 `MachOImage.cache` 同一个依据），或 routing 声明了 `mayReferenceStringTablesOfLoadedImages`（Swift 的 routing 声明了，C/C++ 的没有）。其余情况名字复制进私有缓冲。
- `retainedByteCount` / `privateNameByteCount` 给内存普查用：行、排列与私有缓冲的字节数，镜像的字符串表不计。

## 语言（`SymbolLanguage`）

只看名字开头的字节，不 demangle：

| 语言 | 前缀 |
|---|---|
| Swift | `$s` `_$s` `$S` `_$S` `$e` `_$e` `_T0` `@__swiftmacro_`，以及链接器去重名 `_symbolic `、`_default assoc type ` |
| C++ | `__Z`、`___Z`（C++ 函数里的 block） |
| Objective-C | `-[`、`+[`、`_OBJC_`、`__OBJC_`、`l_OBJC_`、`L_OBJC_`、`_objc_msgSend$` |
| C | 其余一切 |

Swift 的前缀集合必须与 swift-demangling 的 `getManglingPrefixLength` 一致。本包不依赖 demangler，等价由 MachOSwiftSection 的 `SymbolTableEquivalenceTests.symbolLanguageSwiftMatchesDemanglingIsSwiftSymbol` 在真实符号表上钉住；demangler 加前缀时那条测试会变红。

## 采集（`SymbolSweep`）

routing 有三个要求，正好是两个 store 在采集里不同的地方：名字进哪张表（或不收）、每张表怎么按偏移索引（`SymbolOffsetIndexing`：`.nameOnly`、`.byOffset`、`.byOffsetWithSortedOffsets`）、是否允许零拷贝。其余规则对所有 routing 一样：

- 导入（`N_UNDF` 且 `N_EXT`，即 `isExternal`）永远不收。注意 `isExternal` 只指导入，导出的定义同样带 `N_EXT`。
- 调试条目（STABS）只占行：名字还没有行时建一个占位行，此后不改它的偏移、不登记到任何偏移。行序因此跟着调试映射走，也就是源码顺序。
- 文件的符号值是虚拟地址，经 `SymbolValueOffsetConverter` 换成规范化偏移（独立文件是文件偏移，cache 里的镜像是「地址 − 共享区起点」）；行同时登记在原始值与规范化偏移下。进程内镜像两者相等。
- 一个偏移可以有多行（别名、identical code folding），一行在一个偏移下只登记一次；判断不扫桶，靠「新铸的行号一定比已发出的都大」。
- **同名多处定义**：链接后的镜像里 C 名字常常重名（不同目标文件里同名的 static 函数、`ltmp0`）。一个名字只有一行，偏移取最后一次出现，但每次出现的偏移都会登记这一行。所以不能用「行的偏移等于键」去判断一个键是不是规范化偏移——`.byOffsetWithSortedOffsets` 正是为此在登记时直接记下规范化偏移。
- 导出表：每个条目都算「有导出信息」（不管 routing 收不收）；routing 收下的名字已有行就记导出位，没有行但有偏移就铸一行，铸不出或没有偏移（re-export）就记进 name-only 集合。`SymbolExportFacts.isExported` 因此是三态：没有导出信息时答 `nil`。

## C/C++ store（`SymbolIndexStore`）

- 收 `SymbolLanguage` 不是 `.swift` 的一切名字，一张表，`.byOffsetWithSortedOffsets`，不允许零拷贝（共享缓存里的镜像除外）。
- 查询：`symbols(for:in:)`（恰好在这个偏移）、`closestSymbols(at:in:)`（不晚于这个偏移的最大偏移上的全部名字，二分 `sortedCanonicalOffsets`，不设距离上限）、`offset(ofSymbolNamed:in:)`、`containsSymbol(named:in:)`、`isExported(name:in:)`、`hasExportInformation(in:)`。方法名沿用 Swift store 的同名查询。
- `offset(ofSymbolNamed:)` 与 `containsSymbol` 只认登记过偏移的名字：只被调试条目提到的占位行不算。
- 偏移的口径与本包其余读取一致：独立文件是文件偏移，cache 镜像是「未滑动地址 − 共享区起点」，进程内镜像是距 mach header 的距离。镜像里确有负偏移的符号（cache 镜像的某些绝对符号），`closestSymbols(at: -1)` 不一定是 `nil`。
- 缓存是 `SharedCache<Storage>(evictionGroup: .symbolStore)`，没有任何 indexer 认领它；镜像不再需要时由调用方 `remove(for:)`。键按 `SharedCacheKey`：同一个文件（同一 `LC_UUID`）的两个 `MachOFile` 实例共享一份索引，包装读取器与它包着的读取器也共享。
- 2.0.0 不 demangle C++：要可读的名字暂时用 MachOKit 的 `demangledName`。结构化的 C++ 归类（按类、命名空间、成员）计划在 2.1.0 引入 LLVM 的 `ItaniumDemangle`，另有提案。

## 内存（2026-11-18，macOS 27.2 的 AppKit，`symbolIndexCensusOfALargeImage`）

| 读取器 | 行数 | 符号表（其中复制的名字） | 偏移索引的键 | 有序偏移 |
|---|---|---|---|---|
| 本机 dyld 缓存里的 `MachOFile` | 161,089 | 11.1 MB（7.9 MB） | 360,328 个，至少 8.6 MB | 1.4 MB |
| 进程内的 `MachOImage` | 161,089 | 3.2 MB（0） | 180,164 个，至少 4.3 MB | 1.4 MB |

- 文件的名字要复制进私有缓冲，进程内的缓存镜像零拷贝，差出 7.9 MB。
- 文件的每一行同时登记在原始地址与规范化偏移下，偏移索引的键是镜像的两倍。C/C++ store 的查询只按规范化偏移问，原始地址的键对它没有用：给 `SymbolOffsetIndexing` 加一档「只登记规范化偏移」可以省下约一半，留作后续。
- 「至少」是键与桶本身的字节数，不含 `Dictionary` 的空槽与元数据。

## 契约与坑

- **Swift 侧不要写裸的 `SymbolIndexStore`**：MachOSwiftSection 的 Swift store 叫 `SwiftSymbolIndexStore`，两者的查询方法同名，写错名字会悄悄编到 C/C++ store 上、查不到任何 Swift 名字。MachOSwiftSection 的 `SymbolIndexStoreNamingScanTests` 扫源码钉住。
- **MachOKit 读不了内核文件的段地址**：`/System/Library/Kernels/kernel` 的地址在 `0xffffff80…`，超出 `Int`，读段地址时 trap。测试里「没有导出表」的样本因此用 SDK 的 `usr/lib/lazydylib1.o`。
- **`MachOImage(name:)` 取文件名第一个点之前的部分**：libc++ 是 `"libc++"`，不是 `"libc++.1"`。
- **`MachOKitExtensions` 模块不再导出 `MachOSymbols`**：这里的 `SymbolIndexStore`、`Symbol`（来自 `MachOResolving`）与 MachOKit 的 `Symbol` / `SymbolProtocol` 同名，再导出会让同时 import 两者的文件歧义。

## 测试

- `Tests/MachOSymbolsTests/SymbolLanguageTests`：各语言的代表名字；`String` 与字节两种入口在三个已加载镜像的每个名字上答案一致，且四种语言都出现。
- `Tests/MachOSymbolsTests/SymbolSweepTests`：分表、导入不收、`.nameOnly` 表没有偏移索引、调试条目不改偏移（读测试 bundle 自己的调试映射）、两条采集腿等价、二分查找、无导出表时三态为 `nil`、带偏移的导出名都有行、本地符号不算导出、主可执行文件按文件偏移登记、零拷贝规则、有序偏移只在要求时保留。
- `Tests/MachOSymbolsTests/SymbolIndexStoreTests`：store 的每个查询，样本是 `/usr/bin/curl`、`/usr/bin/zip`、已加载的 Foundation 与 libswiftCore。
- `Tests/MachOSymbolsTests/PackedNameReferenceBudgetTests`：打包预算、一行 16 字节、行桶契约、字节统计。
- `Tests/MachOKitExtensionsTests/WrappedReaderSymbolIndexTests`：经包装读取器建的索引，偏移与直接读文件时一样。
