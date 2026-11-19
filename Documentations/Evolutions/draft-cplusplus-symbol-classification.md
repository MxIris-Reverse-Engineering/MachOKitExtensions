# Draft - C++ 符号的结构化归类：按作用域整理一个镜像的 C++ 符号

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-11-19
- **最后更新**: 2026-11-19
- **所属愿景**: 无
- **关联提案**: 本包 [0003 move-macho-infrastructure-modules](0003-move-macho-infrastructure-modules.md)（定下要做 C++ 结构化归类、解析器引入 LLVM `ItaniumDemangle`，见其决策日志 2026-11-18）；本包 [draft-split-symbol-language](draft-split-symbol-language.md)（与本提案同日随 3.0.0 落地）
- **实现分支 / PR**: `feature/cplusplus-symbol-classification`，从 `feature/split-symbol-language` 切出；worktree 在 `.worktrees/MachOKitExtensions-CPlusPlusSymbolClassification`
- **配套文档**: 待定 —— 落地时登记实现说明（计划新增 `Internal/CPlusPlusSymbols.md`）
- **网页版**: 同目录同名的 `.html`

## 摘要

本包新增模块 `CPlusPlusSymbols`（同名 library product），让调用方按类、命名空间与成员浏览一个镜像的 C++ 符号。底下是从 libc++abi 原样引入的 LLVM `ItaniumDemangle`，放在新的 C++ target `CPlusPlusDemangling` 里，对 Swift 只露一层 C 接口，下游不用开 C++ 互操作。上面有两样东西。`CPlusPlusSymbolName` 把一个 Itanium 名字拆成归类用的字段：种类、作用域路径、基本名、模板实参、参数、返回类型、const 等限定，外加与 `__cxa_demangle` 同源的可读字符串。`CPlusPlusSymbolIndexStore` 在第一次查询时扫描镜像里的 C++ 名字并逐个解析，建出一棵作用域树：每个作用域按名字里找得到的证据标成类型、命名空间或函数，找不到证据的标「未定」，并列出直接属于它的符号。只解析名字，不读 RTTI。这是纯新增的 API，与 `draft-split-symbol-language` 同日随本包 3.0.0 落地。

## 动机

- **按作用域归类 C++ 符号是已经定下的需求。** 0003 写提案时，用户要求 C/C++ 索引不止按地址、名字、是否导出查询，还要按类、命名空间、成员归类 C++ 符号；「只做查询与字符串 demangle」被否决。当时把归类放到下一个版本另写提案，解析器按「依赖干净就引入」的规则定为 LLVM `ItaniumDemangle`（0003 决策日志 2026-11-18 的三条）。之后拆分提案把这个版本合进了 3.0.0（`draft-split-symbol-language` 决策日志 2026-11-19）。
- **现在只拿得到原始名字，或一整串可读名字。** `SymbolIndexStore`（`Sources/MachOSymbols/SymbolIndexStore.swift`）只给符号表里的写法（`__ZNK4llvm5Value4dumpEv`）。要可读名字只能用 MachOKit 的 `demangledName`，它经 `dlsym` 取系统的 `__cxa_demangle`（0003 前期调研），得到的是一整串 `llvm::Value::dump() const`。调用方想知道「这是哪个类的成员」，就只能自己切字符串，可模板实参里同样有 `::`、括号和逗号（`std::__1::vector<int, std::__1::allocator<int>>::push_back(int&&)`），切不准。
- **Swift 那边已经有成员归类，C++ 没有。** MachOSwiftSection 的 `SwiftSymbolIndexStore` 能按类型列出成员（`memberSymbols(of:for:in:)`），C++ 符号没有对应的能力。

## 前期调研

**现状代码**（`feature/split-symbol-language` 上）

- C++ 名字的判断：`SymbolLanguage.isItaniumMangled` 认 `__Z…` 与 `___Z…`（块），即符号表在 Darwin 上的写法（`Sources/MachOSymbols/SymbolLanguage.swift`）。它先于任何已注册的语言判定，所以一个名字是不是 C++，与进程里注册了哪些语言无关。
- 采集：`SymbolSweep(sweeping:routing:languageRegistry:)` 与 `SymbolTableRouting` 都是 `@_spi(Internals)` 的公开接口（`Sources/MachOSymbols/SymbolSweep.swift:33`、`SymbolTableRouting.swift`）。routing 按名字与语言决定进哪张表、按什么方式建偏移索引（`SymbolOffsetIndexing` 四档）、能否零拷贝引用已加载镜像的字符串表。
- 采集结果 `SweptSymbolTable`：`symbolTable`（`materializedName(atRow:)`、`withNameBytes(atRow:_:)`、`row(forName:)`、`canonicalOffset(atRow:)`）、`rowsByOffset`、`sortedCanonicalOffsets`、`exportFacts`。
- 缓存：`SharedCache<Storage>(evictionGroup:)`（`Sources/MachOCaches/SharedCache.swift`，`@_spi(Internals)`），驱逐组在各模块用扩展声明，例如 `.symbolStore`（`Sources/MachOSymbols/SharedCacheEvictionGroup+MachOSymbols.swift`）。
- `SymbolIndexStore` 的形状是 store 方法加 `in: machO`（`symbols(for:in:)`、`closestSymbols(at:in:)`、`offset(ofSymbolNamed:in:)`、`prepare(in:)`、`contains(in:)`、`remove(for:)`），MachOSwiftSection 的 `SwiftSymbolIndexStore` 也一样。它在语言注册表的「代数」变化后会丢掉已建的索引重建（拆分提案）。
- 锁：本包一律用 `NSLock`（最低 macOS 10.15，`Mutex` 要 macOS 15）。

**`ItaniumDemangle`**（`/Volumes/SwiftProjects/swift-project/llvm-project`，提交 `903b9faaae5c`；`libcxxabi/src/demangle` 最后一次改动是 `67e8a743c9cc`）

- 正本在 `libcxxabi/src/demangle`，`llvm/include/llvm/Demangle` 是用 `cp-to-llvm.sh` 拷过去的副本（该目录的 `README.txt`）。系统的 `__cxa_demangle` 就是它。
- 文件：`ItaniumDemangle.h`（约 190 KB、6212 行）、`ItaniumNodes.def`、`StringViewExtras.h`、`Utility.h`、`DemangleConfig.h`。除 C++ 标准库外，只有 `DemangleConfig.h` 引用了上一级目录的 `../abort_message.h`，用来定义 `_LIBCPP_VERBOSE_ABORT`（`DemangleConfig.h:17-19`）。需要 C++17（`std::string_view`）。
- libcxxabi 版的 `DEMANGLE_NAMESPACE_BEGIN` 是 `namespace { namespace itanium_demangle {`（`DemangleConfig.h:115`）：匿名命名空间、内部链接，同一进程里的系统 libc++abi 或别人链接的 LLVM 不会与它撞符号。LLVM 那份放在 `llvm::itanium_demangle`，是外部链接。
- 解析器 `ManglingParser<Alloc>` 是纯头文件模板，但分配器不在头文件里：`BumpPointerAllocator` 与 `DefaultAllocator` 写在 `libcxxabi/src/cxa_demangle.cpp:290-366`（LLVM 的 `lib/Demangle/ItaniumDemangle.cpp:289-365` 有同样一份）。
- `parse()` 同时接受 `_Z` 与 `__Z`、`___Z` 与 `____Z`（`ItaniumDemangle.h:6161-6187`），符号表在 Darwin 上的写法不用先去掉下划线。名字后面跟 `.` 的部分包成 `DotSuffix`（`.cold.1` 之类）。
- AST 有 88 种节点（`ItaniumNodes.def`），其中三十多种是表达式。归类用得到的有：`FunctionEncoding`（`Ret`、`Name`、`Params`、`CVQuals`、`RefQual`，`ItaniumDemangle.h:952`）；`NestedName`（`Qual`、`Name`）；`LocalName`（`Encoding`、`Entity`）；`NameWithTemplateArgs`；`CtorDtorName`（`IsDtor`、`Variant`，`:1757`）；`AbiTagAttr`、`ModuleEntity`；`SpecialName`（一段前缀文字加一个子节点，`:1042`）与 `CtorVtableSpecialName`（`:1058`）；`ClosureTypeName`、`UnnamedTypeName`；`SpecialSubstitution`（`St`、`Sa`、`Ss`……）。
- `SpecialName` 的前缀文字：`vtable for `、`VTT for `、`typeinfo for `、`typeinfo name for `、`covariant return thunk to `、`virtual thunk to `、`non-virtual thunk to `、`guard variable for `、`reference temporary for `、`thread-local wrapper routine for `、`thread-local initialization routine for `、`template parameter object for `、`initializer for module `、`invocation function for block in `（`ItaniumDemangle.h:5519-5640`、`:6187`）。
- 每个节点都能用 `Node::visit` 加各自的 `match` 列出子节点（`ItaniumDemangle.h:232`、`:2639`），所以遍历参数类型不必为 88 种节点各写一段。
- LLVM 的 `ItaniumPartialDemangler`（`llvm/include/llvm/Demangle/Demangle.h:85`，实现在 `lib/Demangle/ItaniumDemangle.cpp:385-608`）能取函数的基本名、上下文名、参数与返回类型。但它只在 LLVM 那份里有；上下文只给一整串（`a::b`），不给逐段的列表；也不给任何「这是类」的证据。本提案照它的走法自己写遍历。
- 许可证：Apache-2.0 WITH LLVM-exception（`libcxxabi/LICENSE.TXT`），本包是 MIT。引入的文件要带上许可证全文。

**Itanium 名字分不出类与命名空间**

- `<nested-name> ::= N [<CV-qualifiers>] [<ref-qualifier>] <prefix> <unqualified-name> E`：前缀的每一段都只是名字。`_ZN3foo3barEv` 里的 `foo` 可能是命名空间，也可能是类（`bar` 是它的静态成员函数）。
- 名字里能找到的证据：
  - 某个作用域有构造函数或析构函数、vtable、VTT、typeinfo、thunk，或者有带 cv、ref 限定的成员函数，它就是类（class、struct 或 union）。
  - 某个作用域出现在参数、返回类型、模板类型实参或成员指针的类那一边，它就是类型（也可能是 enum）。
  - `St`（`std`）与匿名命名空间（`12_GLOBAL__N_1`，打印成 `(anonymous namespace)`）按 ABI 就是命名空间。
  - `ClosureTypeName`（lambda）与 `UnnamedTypeName` 按 ABI 就是类型。
  - `LocalName` 的 `Encoding` 是一个函数，它里面的局部实体以这个函数为作用域。
- libc++ 的内联命名空间 `std::__1` 的 `__1` 在名字里没有证据，按上面的规则会是「未定」。

**谁会用**

- 目前没有下游调用。RuntimeViewer、MachOKitUI、swift-decompiler、REAgent 都不用 C/C++ 索引（拆分提案前期调研）。MachOKitUI 显示 C++ 名字用的是 MachOKit 的 `demangledName` 字符串。

**平台**

- 本包 README 承诺支持 Linux，C++ target 在 Linux 上由 SwiftPM 链接 libstdc++。本机没有 Linux SDK，这次验证不了（同 0003）。

## 提议方案

1. **引入 `ItaniumDemangle`，原样、不改文件。** 新 C++ target `CPlusPlusDemangling`：`ItaniumDemangle/` 子目录放 libcxxabi 的五个文件与 `LICENSE.TXT`，一字不改。`DemangleConfig.h` 要的 `../abort_message.h` 由本包在上一级目录提供一份小头文件，只定义 `__abort_message`（打印后 `abort()`）。分配器照抄 `cxa_demangle.cpp:290-366`，带出处注释。以后更新解析器，只要把五个文件整份换掉。
2. **对 Swift 只露 C 接口。** `CPlusPlusDemangling` 的公开头文件是纯 C：一个可重复使用的不透明解析器对象。每次解析之后，用取值函数读出种类、作用域的各段、基本名、模板实参、参数、返回类型、限定、构造或析构的变体号、点后缀、完整的可读名字，以及名字里「当作类型用到」的各个作用域路径。字符串都指向解析器内部的缓冲区，下一次解析前有效。遍历 AST 的代码写在 `CPlusPlusDemangling.cpp` 里，照 `ItaniumPartialDemangler` 的走法。
3. **`CPlusPlusSymbolName`：一个名字拆开后的样子。** 值类型，`init?(mangledName:)` 接受符号表的写法（`__Z…`、`___Z…`），解析不了时返回 `nil`。字段见详细设计。种类 `Kind` 是 struct 加静态成员：函数、构造、析构、变量，以及十几种特殊名字（vtable、typeinfo、thunk、guard 变量……）。
4. **特殊名字按「它说的是谁」归位。** 说的是一个类型的（vtable、VTT、typeinfo、typeinfo name），作用域路径就是这个类型本身，因为它算这个类型的成员。construction vtable 归到被构造的那个完整类。说的是一个函数或变量的（各种 thunk、guard 变量、reference temporary、两种线程局部例程），取那个函数或变量的作用域与基本名。块的调用函数取外层函数的作用域与基本名。说的不是具名实体的（模板参数对象、模块初始化函数、关于指针或内置类型的 typeinfo），放在全局作用域。
5. **`CPlusPlusSymbolIndexStore`：作用域树。** 带 `.shared` 的 store，接口形状照 `SymbolIndexStore`（方法加 `in: machO`）。每个镜像在第一次查询时建一次：用自己的 routing 跑一遍 `SymbolSweep`，只收 C++ 名字；逐个解析，把作用域路径并进树里，累积证据。树里只有确实装着符号的作用域及其上层；名字里当作类型用到、却没有符号的作用域不进树，它的证据也丢掉。
6. **作用域的种类按证据定。** 依次判断：是函数（局部实体所在）→ `.function`；有命名空间的证据（全局、`std`、匿名命名空间）→ `.namespace`；有任何类型的证据 → `.type`；都没有 → `.undetermined`，不猜。证据本身以 `OptionSet` 公开，调用方能自己判断。
7. **模板的每个特化各是一个作用域。** `vector<int>` 与 `vector<char>` 是 `std::__1` 下的两个兄弟作用域，`name` 带实参，`baseName` 都是 `vector`，调用方按 `baseName` 就能把各个特化列在一起。
8. **解析结果不常驻。** 索引只常驻作用域树（每个作用域一份名字），以及每行所属的作用域与种类。`members(of:in:)`、`symbols(for:in:)` 返回的 `CPlusPlusSymbol` 当场重新解析出来；一次解析是微秒级，一个有几百个成员的类也在毫秒内。
9. **发版**：与 `draft-split-symbol-language` 同日随本包 3.0.0 落地。本提案只新增 API，不需要下游配合改动。

### 非目标

- 读 RTTI 或 vtable 的内容（基类、虚函数表布局）：以后另写提案。
- 把 ItaniumDemangle 的 AST 镜像成 Swift 类型：参数与模板实参只给字符串。
- `CPlusPlusSymbols` 进 `MachOFoundation`：那样 MachOSwiftSection、MachOObjCSection 都要编译这份 C++ 代码，而它们用不到。
- 替换 MachOKit 的 `demangledName`，或让下游（RuntimeViewer、MachOKitUI）采用本模块：留给各自的提案。
- 微软（MSVC）的名字修饰，以及 Swift、Objective-C、Rust 的名字。
- 为 `std::__1` 这类约定俗成的命名空间维护白名单：没有证据就是「未定」。
- 在 Linux 上验证：同 0003，这次只验证 Darwin。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `Package.swift` | 修改 | 包级 `cxxLanguageStandard: .cxx17`；新增 target `CPlusPlusDemangling`（C++，`publicHeadersPath: "include"`）、`CPlusPlusSymbols`、测试夹具 `CPlusPlusSymbolsFixture`（C++，`path: "Tests/CPlusPlusSymbolsFixture"`）、测试 target `CPlusPlusSymbolsTests`；新增 product `CPlusPlusSymbols` | 新模块；`ItaniumDemangle.h` 要 C++17 | 1 |
| `Sources/CPlusPlusDemangling/ItaniumDemangle/`（`ItaniumDemangle.h`、`ItaniumNodes.def`、`StringViewExtras.h`、`Utility.h`、`DemangleConfig.h`、`LICENSE.TXT`） | 新增 | 从 libcxxabi `src/demangle` 原样拷入，不改 | 解析器 | 1 |
| `Sources/CPlusPlusDemangling/abort_message.h` | 新增 | 只定义 `__abort_message`，供 `DemangleConfig.h` 的 `#include "../abort_message.h"` | 不改引入的文件 | 1 |
| `Sources/CPlusPlusDemangling/include/CPlusPlusDemangling.h` | 新增 | 纯 C 接口：解析器的创建、销毁、解析与取值函数，种类、作用域段种类、限定的常量 | Swift 不开 C++ 互操作 | 1 |
| `Sources/CPlusPlusDemangling/CPlusPlusDemangling.cpp` | 新增 | 分配器（照抄 `cxa_demangle.cpp:290-366`）；解析器对象；遍历 AST 拆字段、收集当作类型用到的作用域路径 | 同上 | 1 |
| `Sources/CPlusPlusSymbols/CPlusPlusSymbolName.swift` · `CPlusPlusSymbolName`、`Kind`、`FunctionQualifiers` | 新增 | 一个名字拆开后的值类型，经 C 接口填字段 | 单个名字的解析入口 | 2 |
| `Sources/CPlusPlusSymbols/CPlusPlusDemangler.swift` · `CPlusPlusDemangler`（internal） | 新增 | 包住 C 解析器对象：`deinit` 销毁，`parse(_:)` 返回只在闭包内有效的结果读取器；同时产出给索引用的作用域证据 | `CPlusPlusSymbolName` 与索引的建表共用 | 2 |
| `Sources/CPlusPlusSymbols/CPlusPlusScope.swift` · `CPlusPlusScope`、`Kind`、`Evidence` | 新增 | 作用域的值类型，含 `.global` | 树的节点 | 3 |
| `Sources/CPlusPlusSymbols/CPlusPlusSymbol.swift` · `CPlusPlusSymbol` | 新增 | `Symbol` 加 `CPlusPlusSymbolName` | 查询结果 | 3 |
| `Sources/CPlusPlusSymbols/CPlusPlusSymbolIndexStore.swift` · `CPlusPlusSymbolIndexStore`、`Storage`、`CPlusPlusSymbolTableRouting` | 新增 | `.shared`；查询见详细设计；`Storage` 建树、累积证据、定种类 | 按作用域浏览 | 3 |
| `Sources/CPlusPlusSymbols/SharedCacheEvictionGroup+CPlusPlusSymbols.swift` | 新增 | `.cPlusPlusSymbolStore` | 与 `.symbolStore` 分开驱逐 | 3 |
| `Tests/CPlusPlusSymbolsFixture/`（`Fixture.cpp`、`include/CPlusPlusSymbolsFixture.h`） | 新增 | 覆盖各种证据与特殊名字的小段 C++ 代码，符号都标 `used`，再导出一个 C 函数让测试取到所在镜像 | 归类规则需要确定的输入，不能只靠系统库 | 3 |
| `Tests/CPlusPlusSymbolsTests/CPlusPlusDemanglingTests.swift` | 新增 | C 接口：解析、拒绝、与系统 `__cxa_demangle` 一致 | 第 1 步行为 | 1 |
| `Tests/CPlusPlusSymbolsTests/CPlusPlusSymbolNameTests.swift` | 新增 | 一组固定名字的字段期望 | 第 2 步行为 | 2 |
| `Tests/CPlusPlusSymbolsTests/CPlusPlusSymbolIndexStoreTests.swift` | 新增 | 在夹具所在镜像上验证树、证据、种类与查询 | 第 3 步行为 | 3 |
| `Tests/CPlusPlusSymbolsTests/CPlusPlusSymbolIndexCensusTests.swift` | 新增 | 在 JavaScriptCore（进程内的 `MachOImage` 与从 cache 读出的 `MachOFile`）上打印 C++ 行数、作用域数、各种类的作用域数、未能解析的名字数、建树耗时与常驻字节 | 记录规模与成本 | 4 |
| `Documentations/Internal/CPlusPlusSymbols.md` | 新增 | 实现说明：引入的来源与更新方法、C 接口、特殊名字归位、证据与种类规则、为什么不常驻解析结果、普查数字 | 实现说明随代码 | 5 |
| `README.md` | 修改 | 模块表加 `CPlusPlusSymbols`；示例；第三方代码与许可证一节 | 对外说明 | 5 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案（写提案时已登记）与实现说明 | 索引 | 5 |

## 架构图

改了什么：

```text
MachOKitExtensions (package)
  MachOSymbols                              (unchanged)
    SymbolSweep, SymbolTableRouting   (SPI Internals)
    SymbolIndexStore                         C and C++ names, raw
  + CPlusPlusDemangling   (C++ target, C header)
  +   ItaniumDemangle/                      libcxxabi src/demangle, verbatim, Apache-2.0 WITH LLVM-exception
  +   abort_message.h                       __abort_message only
  +   CPlusPlusDemangling.cpp               allocator, demangler object, AST walk
  +   include/CPlusPlusDemangling.h         plain C API
  + CPlusPlusSymbols      (Swift, product)  -> CPlusPlusDemangling (internal import), MachOSymbols (SPI),
  +                                            MachOCaches (SPI), MachOResolving, MachOKitExtensions, MachOKit
  +   CPlusPlusSymbolName                   one name taken apart
  +   CPlusPlusScope                        scope: path, kind, evidence
  +   CPlusPlusSymbol                       Symbol + CPlusPlusSymbolName
  +   CPlusPlusSymbolIndexStore (.shared)   scope tree per image, built on first query
  MachOFoundation                           (unchanged: does not include CPlusPlusSymbols)
```

建树与查询的流程：

```text
CPlusPlusSymbolIndexStore.shared.members(of: scope, in: image)
 └─ storage(in: image)                                 built once, cached under .cPlusPlusSymbolStore
     └─ SymbolSweep(sweeping: image, routing: CPlusPlusSymbolTableRouting)
         └─ language == .cPlusPlus -> .symbols (.byOffset); everything else -> nil
     └─ for each row: CPlusPlusDemangler.parse(name)
         ├─ unparsable -> unparsedRows
         ├─ scope path (+ per-component hint: function / namespace / type)
         │    -> insert every prefix into the tree
         ├─ evidence for the scope it sits in:
         │    constructor/destructor, vtable/VTT, typeinfo, cv/ref-qualified, thunk
         ├─ type paths used as types in its signature -> pending usedAsType evidence
         └─ (scope, kind) recorded for the row
     └─ apply pending usedAsType evidence to scopes that exist; drop the rest
     └─ decide each scope's kind: function > namespace > type > undetermined
 └─ rows of scope, ascending offset
     └─ each row: parse its name again -> CPlusPlusSymbol(symbol, name)
```

## 详细设计

### C 接口：`CPlusPlusDemangling.h`

```c
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A reusable demangler. Not thread-safe: one per thread.
typedef struct CPlusPlusDemangler CPlusPlusDemangler;

/// Bytes owned by the demangler, valid until its next parse or its destruction.
/// Not NUL-terminated.
typedef struct {
    const char *bytes;
    size_t length;
} CPlusPlusDemanglerText;

typedef enum : int32_t {
    CPlusPlusDemanglerSymbolKindFunction,
    CPlusPlusDemanglerSymbolKindConstructor,
    CPlusPlusDemanglerSymbolKindDestructor,
    CPlusPlusDemanglerSymbolKindVariable,
    CPlusPlusDemanglerSymbolKindVirtualTable,
    CPlusPlusDemanglerSymbolKindVirtualTableTable,
    CPlusPlusDemanglerSymbolKindConstructionVirtualTable,
    CPlusPlusDemanglerSymbolKindTypeInfo,
    CPlusPlusDemanglerSymbolKindTypeInfoName,
    CPlusPlusDemanglerSymbolKindNonVirtualThunk,
    CPlusPlusDemanglerSymbolKindVirtualThunk,
    CPlusPlusDemanglerSymbolKindCovariantReturnThunk,
    CPlusPlusDemanglerSymbolKindGuardVariable,
    CPlusPlusDemanglerSymbolKindReferenceTemporary,
    CPlusPlusDemanglerSymbolKindThreadLocalWrapper,
    CPlusPlusDemanglerSymbolKindThreadLocalInitializer,
    CPlusPlusDemanglerSymbolKindTemplateParameterObject,
    CPlusPlusDemanglerSymbolKindModuleInitializer,
    CPlusPlusDemanglerSymbolKindBlockInvocation,
} CPlusPlusDemanglerSymbolKind;

/// What the mangling itself says a scope component is.
typedef enum : int32_t {
    CPlusPlusDemanglerScopeHintNone,
    CPlusPlusDemanglerScopeHintNamespace,   // std, an anonymous namespace
    CPlusPlusDemanglerScopeHintType,        // a closure or unnamed type, std::allocator and the other std substitutions
    CPlusPlusDemanglerScopeHintFunction,    // the function a local entity sits in
} CPlusPlusDemanglerScopeHint;

enum : uint32_t {
    CPlusPlusDemanglerQualifierConst = 1 << 0,
    CPlusPlusDemanglerQualifierVolatile = 1 << 1,
    CPlusPlusDemanglerQualifierRestrict = 1 << 2,
    CPlusPlusDemanglerQualifierLValueReference = 1 << 3,
    CPlusPlusDemanglerQualifierRValueReference = 1 << 4,
};

CPlusPlusDemangler *CPlusPlusDemanglerCreate(void);
void CPlusPlusDemanglerDestroy(CPlusPlusDemangler *demangler);

/// Parses `mangledName` (the symbol table's spelling, `__Z…` or `___Z…`).
/// Returns false when it is not a name the demangler parses; nothing may be
/// read then.
bool CPlusPlusDemanglerParse(CPlusPlusDemangler *demangler, const char *mangledName, size_t length);

CPlusPlusDemanglerSymbolKind CPlusPlusDemanglerGetKind(const CPlusPlusDemangler *demangler);
CPlusPlusDemanglerText CPlusPlusDemanglerGetDemangledName(CPlusPlusDemangler *demangler);

size_t CPlusPlusDemanglerGetScopeComponentCount(const CPlusPlusDemangler *demangler);
CPlusPlusDemanglerText CPlusPlusDemanglerGetScopeComponentName(CPlusPlusDemangler *demangler, size_t componentIndex);
CPlusPlusDemanglerText CPlusPlusDemanglerGetScopeComponentBaseName(CPlusPlusDemangler *demangler, size_t componentIndex);
CPlusPlusDemanglerScopeHint CPlusPlusDemanglerGetScopeComponentHint(const CPlusPlusDemangler *demangler, size_t componentIndex);

CPlusPlusDemanglerText CPlusPlusDemanglerGetBaseName(CPlusPlusDemangler *demangler);
/// Each returns a text with `bytes == NULL` when the name has no such part.
CPlusPlusDemanglerText CPlusPlusDemanglerGetTemplateArguments(CPlusPlusDemangler *demangler);
CPlusPlusDemanglerText CPlusPlusDemanglerGetParameters(CPlusPlusDemangler *demangler);
CPlusPlusDemanglerText CPlusPlusDemanglerGetReturnType(CPlusPlusDemangler *demangler);
CPlusPlusDemanglerText CPlusPlusDemanglerGetSuffix(CPlusPlusDemangler *demangler);

uint32_t CPlusPlusDemanglerGetFunctionQualifiers(const CPlusPlusDemangler *demangler);
/// 0 to 5 for a constructor (C0–C5) or destructor (D0–D5); -1 otherwise.
int32_t CPlusPlusDemanglerGetConstructorOrDestructorVariant(const CPlusPlusDemangler *demangler);

/// Named types the signature uses as types: parameters, the return type,
/// type template arguments, the class side of a member pointer. Each is a
/// scope path, read component by component.
size_t CPlusPlusDemanglerGetReferencedTypeCount(const CPlusPlusDemangler *demangler);
size_t CPlusPlusDemanglerGetReferencedTypeComponentCount(const CPlusPlusDemangler *demangler, size_t typeIndex);
CPlusPlusDemanglerText CPlusPlusDemanglerGetReferencedTypeComponentName(CPlusPlusDemangler *demangler, size_t typeIndex, size_t componentIndex);

#ifdef __cplusplus
}
#endif
```

- 文本按需打印：取值函数第一次被调用时才把对应节点打印进解析器自己的缓冲区，建树时用不到的部分（完整名字、参数）不打印。所以取文本的函数接受非 `const` 的解析器。
- 作用域的各段：从实体的名字一路往外拆。`NestedName` 把 `Qual` 拆成多段；`LocalName` 先放外层函数（提示 `Function`，名字打印成带参数的 `foo(int)`），再接着拆 `Entity`；`NameWithTemplateArgs` 作为一段，`name` 带实参，`baseName` 不带；`AbiTagAttr`、`ModuleEntity` 透过去；`SpecialSubstitution` 展开成 `std` 加可能的类型名（`Sa` → `std`、`allocator`）。
- 当作类型用到的作用域：从 `Params`、`Ret` 与模板实参出发，只沿类型节点往下走（指针、引用、cv 限定、数组、函数类型、成员指针、模板实参列表），遇到具名的类型（`NameType`、`NestedName`、`NameWithTemplateArgs`）就记一条路径，遇到表达式节点就停。表达式里的名字可能是变量或函数，不能当证据。
- 解析失败的判定与 `__cxa_demangle` 相同：`parse()` 返回空，或名字没读完。

### `CPlusPlusSymbolName`

```swift
/// A C++ (Itanium) symbol name taken apart: what it names, the scopes that
/// entity sits in, and the parts of its signature, each as C++ prints it.
///
/// ```swift
/// let name = CPlusPlusSymbolName(mangledName: "__ZNK4llvm5Value4dumpEv")!
/// name.demangledName          // "llvm::Value::dump() const"
/// name.kind                   // .function
/// name.scopePath              // ["llvm", "Value"]
/// name.baseName               // "dump"
/// name.parameters             // "()"
/// name.functionQualifiers     // [.const]
/// ```
public struct CPlusPlusSymbolName: Hashable, Sendable, CustomStringConvertible {
    /// `nil` when `mangledName` is not an Itanium name this demangler parses.
    /// `mangledName` is spelled as the symbol table spells it on Darwin:
    /// `__Z…`, or `___Z…` for a block inside a C++ function.
    public init?(mangledName: String)

    public let mangledName: String

    /// The whole name as `__cxa_demangle` prints it.
    public let demangledName: String

    public let kind: Kind

    /// The scopes the entity sits in, outermost first, each as C++ prints
    /// it — a specialization with its arguments, a function with its
    /// parameters: `["std", "__1", "vector<int, std::__1::allocator<int>>"]`.
    /// Empty at global scope. For a name about a type (its vtable, its
    /// typeinfo), the path ends with that type.
    public let scopePath: [String]

    /// The entity's own name without template arguments: `push_back`;
    /// `vector` and `~vector` for a constructor and a destructor; for a name
    /// about a type, the type's last component.
    public let baseName: String

    /// `<int>` when the entity itself is a template specialization.
    public let templateArguments: String?

    /// `(int, char const*)` for a function; `nil` for anything else.
    public let parameters: String?

    /// The return type, which the mangling records only for a function
    /// template specialization; `nil` otherwise.
    public let returnType: String?

    public let functionQualifiers: FunctionQualifiers

    /// The Itanium variant of a constructor (`C1` → 1, `C2` → 2, …) or a
    /// destructor (`D0` → 0, …); `nil` for anything else. Variants of one
    /// constructor print the same name and sit at different offsets.
    public let constructorOrDestructorVariant: Int?

    /// What follows the name after a dot — `.cold.1` — or `nil`.
    public let suffix: String?

    public var description: String { demangledName }
}

extension CPlusPlusSymbolName {
    /// What a C++ symbol names. More kinds can be added as the Itanium ABI
    /// grows, so a caller never switches over all of them.
    public struct Kind: Hashable, Sendable, CustomStringConvertible {
        public static let function: Kind
        public static let constructor: Kind
        public static let destructor: Kind
        public static let variable: Kind
        public static let virtualTable: Kind
        public static let virtualTableTable: Kind            // VTT
        public static let constructionVirtualTable: Kind
        public static let typeInfo: Kind
        public static let typeInfoName: Kind
        public static let nonVirtualThunk: Kind
        public static let virtualThunk: Kind
        public static let covariantReturnThunk: Kind
        public static let guardVariable: Kind
        public static let referenceTemporary: Kind
        public static let threadLocalWrapper: Kind
        public static let threadLocalInitializer: Kind
        public static let templateParameterObject: Kind
        public static let moduleInitializer: Kind
        public static let blockInvocation: Kind
        public var description: String { get }               // "function", "vtable", …
    }

    public struct FunctionQualifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8)
        public static let const: FunctionQualifiers
        public static let volatile: FunctionQualifiers
        public static let restrict: FunctionQualifiers
        public static let lValueReference: FunctionQualifiers  // &
        public static let rValueReference: FunctionQualifiers  // &&
    }
}
```

- `Kind` 用 struct 加静态成员，与本包的 `SymbolLanguage`、`SymbolOffsetIndexing` 一致：Itanium ABI 还会加特殊名字（`template parameter object` 与 `initializer for module` 都是近年加的），加成员不破坏调用方。
- `init?(mangledName:)` 只认符号表的写法，与 `SymbolLanguage(ofSymbolNamed:)` 一致。不带 Darwin 下划线的 `_Z…` 也能解析，因为解析器两种都接受，但文档只承诺符号表的写法。
- 每次 `init?(mangledName:)` 都新建一个解析器。解析器的分配器带 4 KB 的内联初始缓冲区，创建很便宜；建树时每个工作单元复用一个。

### `CPlusPlusScope` 与 `CPlusPlusSymbol`

```swift
/// A namespace, type or function that C++ symbols of an image sit in.
public struct CPlusPlusScope: Hashable, Sendable, CustomStringConvertible {
    /// The global namespace: the parent of every top-level scope.
    public static let global: CPlusPlusScope

    /// The scope's components, outermost first; empty for ``global``.
    public let path: [String]

    /// The last component as C++ prints it: `vector<int, std::__1::allocator<int>>`.
    public var name: String { get }

    /// The last component without template arguments: `vector`. Every
    /// specialization of one class template shares it.
    public let baseName: String

    /// `std::__1::vector<int, std::__1::allocator<int>>`; empty for ``global``.
    public let qualifiedName: String

    public let kind: Kind

    /// What the image's symbol names show about the scope.
    public let evidence: Evidence

    public var description: String { get }                  // qualifiedName, or "(global)"
}

extension CPlusPlusScope {
    /// The mangling never says whether a component is a namespace or a class;
    /// a scope is a type or a namespace only when some symbol name shows it.
    public struct Kind: Hashable, Sendable, CustomStringConvertible {
        public static let namespace: Kind      // global, std, anonymous namespaces
        public static let type: Kind           // a class, struct, union or enum
        public static let function: Kind       // the function a local entity sits in
        public static let undetermined: Kind   // a namespace or a type; no name shows which
    }

    public struct Evidence: OptionSet, Hashable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16)
        /// The mangling itself names it a namespace: `std`, an anonymous namespace.
        public static let mangledAsNamespace: Evidence
        /// The mangling itself names it a type: a lambda, an unnamed type, `std::allocator` and friends.
        public static let mangledAsType: Evidence
        public static let constructorOrDestructor: Evidence
        public static let virtualTable: Evidence       // vtable, VTT, construction vtable
        public static let typeInfo: Evidence           // typeinfo, typeinfo name
        public static let qualifiedMemberFunction: Evidence  // a const, volatile, & or && member function
        public static let thunk: Evidence
        public static let usedAsType: Evidence         // in a signature or a type template argument

        /// Every evidence of a type.
        public static let anyType: Evidence
    }
}

/// A C++ symbol of an image with its name taken apart.
public struct CPlusPlusSymbol: Hashable, Sendable {
    public let symbol: Symbol
    public let name: CPlusPlusSymbolName
    public var offset: Int { symbol.offset }
}
```

种类的判定（在全部名字都并进树之后、每个作用域一次）：

```swift
if hints.contains(.function) { .function }
else if scope.isGlobal || evidence.contains(.mangledAsNamespace) { .namespace }
else if !evidence.isDisjoint(with: .anyType) { .type }
else { .undetermined }
```

### `CPlusPlusSymbolIndexStore`

```swift
/// The C++ symbols of an image, arranged by the scopes they sit in. An
/// image's index is built on first use and shared by every caller.
///
/// ```swift
/// let store = CPlusPlusSymbolIndexStore.shared
/// for scope in store.childScopes(of: .global, in: machO) { … }          // top level
/// if let value = store.scope(named: "llvm::Value", in: machO) {
///     let constructors = store.members(of: value, in: machO).filter { $0.name.kind == .constructor }
/// }
/// let names = store.symbols(for: functionOffset, in: machO).map(\.name.demangledName)
/// ```
public final class CPlusPlusSymbolIndexStore: @unchecked Sendable {
    public static let shared: CPlusPlusSymbolIndexStore

    /// The scopes directly inside `scope`, ascending by name. ``CPlusPlusScope/global``
    /// gives the top-level ones.
    public func childScopes(of scope: CPlusPlusScope, in machO: some MachORepresentableWithCache) -> [CPlusPlusScope]

    /// The scope whose ``CPlusPlusScope/qualifiedName`` is `qualifiedName`;
    /// `nil` when no C++ symbol of the image sits in it or below it.
    public func scope(named qualifiedName: String, in machO: some MachORepresentableWithCache) -> CPlusPlusScope?

    /// The symbols directly inside `scope` — functions, data, its vtable and
    /// typeinfo — ascending by offset.
    public func members(of scope: CPlusPlusScope, in machO: some MachORepresentableWithCache) -> [CPlusPlusSymbol]

    /// The C++ symbols at exactly `offset`, in symbol-table order; empty when none.
    public func symbols(for offset: Int, in machO: some MachORepresentableWithCache) -> [CPlusPlusSymbol]

    /// The C++ symbol whose name is `mangledName`, spelled as the symbol table spells it.
    public func symbol(named mangledName: String, in machO: some MachORepresentableWithCache) -> CPlusPlusSymbol?

    /// Names that look like C++ (`__Z…`) but that the demangler does not parse.
    public func unparsedSymbols(in machO: some MachORepresentableWithCache) -> [Symbol]

    public func prepare(in machO: some MachORepresentableWithCache)
    public func contains(in machO: some MachORepresentableWithCache) -> Bool
    public func remove(for machO: some MachORepresentableWithCache)
}
```

- **自己的采集。** `CPlusPlusSymbolTableRouting`：语言是 `.cPlusPlus` 的进 `.symbols`（`.byOffset`），其余一概不收；`mayReferenceStringTablesOfLoadedImages` 为 `false`，与 C/C++ 索引一样，只对 dyld shared cache 里的镜像零拷贝。C++ 的判定先于任何注册的语言，所以这个索引不看注册表的代数，也不会因为有语言注册而重建。
- **常驻的内容。** `Storage` 保存：采集结果；作用域数组（每个作用域一条：路径的最后一段、`baseName`、父作用域编号、种类、证据、按名字排序的子作用域编号、按偏移排序的行号）；限定名到作用域编号的字典；每行的作用域编号与种类；未能解析的行号。全局作用域固定是第 0 号。
- **建树。** 逐行解析，按作用域路径逐段查找或插入，记下这一行的作用域、种类与它带来的证据。当作类型用到的路径先攒着，全部行处理完以后，只给树里已有的作用域加 `.usedAsType`，其余丢掉。最后为每个作用域定种类。
- **并行。** 先串行实现，在第 4 步按普查数字决定要不要按行分块、每块一个解析器并行解析。树的合并在解析之后串行做，结果与串行一致。
- **查询结果当场解析。** `members(of:in:)`、`symbols(for:in:)`、`symbol(named:in:)` 用行号取出名字，再解析一次，组成 `CPlusPlusSymbol`。`scope(named:)` 查字典；`childScopes(of:)` 先按 `path` 定位作用域（同一个镜像里，同一路径只对应一个作用域），再读它的子作用域编号。
- **锁与驱逐。** 与 `SymbolIndexStore` 相同：`SharedCache` 自己带锁，驱逐组 `.cPlusPlusSymbolStore`，不主动驱逐，调用方用 `remove(for:)` 释放。

### 测试夹具

`Tests/CPlusPlusSymbolsFixture` 是测试专用的 C++ target，用确定的源码代替系统库里会随版本变化的符号。它覆盖下面这些情况：

- 有构造函数的类；有虚函数的类（带 vtable 与 typeinfo），其中一个经虚继承（带 VTT、construction vtable 与 virtual thunk）；只有 const 成员函数的类；只有静态成员函数、按规则应是「未定」的类；只在别处的参数里出现的类；
- 命名空间里的普通函数、两个特化的类模板、函数模板（带返回类型）；
- 匿名命名空间、函数里的局部类与 lambda、局部静态变量（guard 变量）、`thread_local` 变量；
- 一个块（`^{}`）。

夹具的符号都标 `__attribute__((used))`，避免 release 构建把它们剥掉。另外导出一个 C 函数，测试用 `dladdr` 找到它所在的镜像，再按 `MachOImage` 读取。

## 替代方案考量

- **把 AST 完整镜像成 Swift 类型**：像 swift-demangling 的 `Node` 那样，能遍历参数类型与模板实参。但 88 种节点都要有 Swift 对应，API 面与工作量大很多。用户选择归类字段加字符串。
- **作用域只叫「作用域」，不分类与命名空间**；或**没有证据就当命名空间**：前者把判断全推给调用方；后者只导出了静态成员函数的类会被误标成命名空间。用户选择按证据标，其余标「未定」。
- **同时读 RTTI 拿基类**：能给出继承关系，类的判断也更可靠；但要解析镜像里的数据，范围与测试都翻倍，3.0.0 会更晚。用户选择这次只解析名字。
- **用系统的 `__cxa_demangle` 拿字符串再切**：模板实参里有 `::`、括号与逗号，切不准；它经 `dlsym` 取得，各平台行为不一。0003 已否决。
- **用 LLVM 那份与 `ItaniumPartialDemangler`**：省一段遍历代码，但上下文只给一整串、不给逐段列表与证据；`DemangleConfig.h` 要换掉 `llvm-config.h`；命名空间 `llvm::itanium_demangle` 是外部链接，同一进程里有人链接 LLVM 时会撞符号。改用 libcxxabi 那份（匿名命名空间），照它的走法自己写遍历。
- **开 Swift 的 C++ 互操作，直接在 Swift 里走 AST**：不用写 C 接口，但本包的 target 要开互操作，下游是否也要跟着开没有实测。C 接口完全避开这个问题，代价是一层取值函数。
- **用 Swift 重写解析器**：6000 多行，且要长期跟进上游。0003 定的规则是依赖干净就引入，而 ItaniumDemangle 只依赖一个可替换的配置头文件。否。
- **放进 `MachOSymbols`，或进 `MachOFoundation`**：每个用 `MachOSymbols` 的包（MachOSwiftSection、MachOObjCSection）都得编译 190 KB 的 C++ 头文件、链接 C++ 标准库，而它们用不到。放进单独的模块。
- **在 `SymbolIndexStore` 上加归类，复用它的采集**：省一遍扫描，但 C/C++ 索引在语言注册后会丢掉重建，归类索引若引用它的行号就得跟着重建；两个 store 的建表时机与驱逐也绑在了一起。扫描相对解析很便宜（0003「一次扫描同时喂两个 store」一条），各扫各的。
- **常驻全部解析结果**：查询不用再解析，但每个 C++ 名字要多存六七个字符串，而大镜像的 C++ 名字数以万计（第 4 步实测）。只常驻树与每行的编号，查询时再解析。
- **模板只按模板归**：`vector<int>` 与 `vector<char>` 的成员混在一起，分不出哪个特化有哪些成员。改为每个特化各是一个作用域，用 `baseName` 把它们列在一起。
- **为 `std::__1` 之类维护命名空间白名单**：结果更整齐，但等于凭约定猜，与「按证据标」相悖。否。

## 影响

### 源码兼容性（source compatibility）

**纯新增**：新模块与新 product，不改任何已有 API 的签名或行为。它随 3.0.0 发布，只是因为与拆分同日落地。

### ABI 兼容性

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

- **本包内**：`Package.swift` 加包级 `cxxLanguageStandard`，只影响 C++ target（之前没有 C++ target）。其余模块不变。
- **MachOSwiftSection、MachOObjCSection**：不依赖新模块，不受影响。
- **RuntimeViewer、MachOKitUI、swift-decompiler、REAgent**：不受影响。以后要按类浏览 C++ 符号时，各自写提案采用。
- 依赖本包的项目第一次解析 3.0.0 时会多编译一个 C++ target，但这只发生在它们依赖了 `CPlusPlusSymbols` product 的时候。SwiftPM 只构建被依赖的 product 用到的 target。

### 文档与示例

- `README.md`：模块表加一行；一段按作用域浏览的示例；第三方代码与许可证一节，说明 `Sources/CPlusPlusDemangling/ItaniumDemangle` 来自 LLVM，按 Apache-2.0 WITH LLVM-exception 授权。
- 新实现说明 `Documentations/Internal/CPlusPlusSymbols.md`。

## API 演进与废弃策略

- 没有被替代的旧 API。
- `CPlusPlusSymbolName.Kind`、`CPlusPlusScope.Kind` 用 struct 加静态成员，以后加种类不破坏调用方；`Evidence` 是 `OptionSet`，以后加证据也不破坏调用方。种类的判定规则会随证据增加而变（例如以后读 RTTI，「未定」会变少），这写进 `Kind` 的文档注释，调用方不该把某个作用域的种类当作永久不变。
- 不需要单独的 semver 跃迁；随拆分的 3.0.0 一起发布。

## 落地步骤

1. **引入解析器与 C 接口** —— 改动地图第 1–5、13 行。
   - 行为：`demanglerParsesTheSymbolTableSpellingOfAnItaniumName`
   - 行为：`demanglerRejectsANameThatIsNotItaniumMangled`
   - 行为：`demanglerReadsNothingAfterAFailedParse`
   - 行为：`demangledNameMatchesSystemCxaDemangleForEveryCPlusPlusNameOfLibCPlusPlus`（进程内的 `libc++.1.dylib`；有差异就逐条查明原因并记进决策日志）
   - 引入的五个文件与 libcxxabi 原文件逐字节相同：提交前用 `cmp` 核对，不写成测试；核对方法写进实现说明的「更新解析器」一节。
2. **`CPlusPlusSymbolName`** —— 第 6、7、14 行。
   - 行为：`functionNameSplitsIntoScopePathBaseNameAndParameters`
   - 行为：`templateArgumentsStayInsideTheirScopeComponent`
   - 行为：`constQualifiedMemberFunctionReportsItsQualifiers`
   - 行为：`constructorAndDestructorKeepTheirVariant`
   - 行为：`namesAboutATypeEndTheirScopePathWithThatType`
   - 行为：`constructionVirtualTableBelongsToTheCompleteClass`
   - 行为：`thunksTakeTheScopeAndBaseNameOfTheFunctionTheyReach`
   - 行为：`guardVariableTakesTheScopeOfItsVariable`
   - 行为：`localEntityScopePathRunsThroughItsFunction`
   - 行为：`blockInvocationTakesTheScopeOfItsFunction`
   - 行为：`functionTemplateSpecializationReportsItsReturnType`
   - 行为：`dotSuffixIsKeptApartFromTheName`
   - 行为：`variableHasNoParametersOrQualifiers`
   - 行为：`unparsableNameGivesNil`
3. **`CPlusPlusSymbolIndexStore`、作用域与夹具** —— 第 8–12、15 行。
   - 行为：`storeHoldsOnlyCPlusPlusNames`
   - 行为：`childScopesOfGlobalAreTheTopLevelScopes`
   - 行为：`scopeWithAConstructorIsAType`
   - 行为：`scopeWithAVirtualTableHasVirtualTableAndTypeInfoAmongItsMembers`
   - 行为：`scopeWithOnlyConstMemberFunctionsIsAType`
   - 行为：`scopeOnlyUsedAsAParameterTypeIsAType`
   - 行为：`scopeWithOnlyStaticMemberFunctionsIsUndetermined`
   - 行为：`standardAndAnonymousNamespacesAreNamespaces`
   - 行为：`functionWithALocalClassIsAFunctionScope`
   - 行为：`lambdaScopeIsAType`
   - 行为：`eachTemplateSpecializationIsItsOwnScopeSharingABaseName`
   - 行为：`typesUsedOnlyInSignaturesAddNoScope`
   - 行为：`scopeNamedFindsAScopeByItsQualifiedName`
   - 行为：`membersAreInOffsetOrder`
   - 行为：`symbolsForOffsetGivesTheParsedNamesAtThatOffset`
   - 行为：`symbolNamedFindsASymbolByItsMangledName`
   - 行为：`unparsedSymbolsListNamesTheDemanglerRejects`
   - 行为：`indexIsBuiltOnFirstQueryAndDroppedByRemove`
   - 行为：`registeringALanguageDoesNotRebuildTheIndex`
4. **普查与成本** —— 第 16 行。在 JavaScriptCore 上（进程内与从 cache 读出各一次，release）记录 C++ 行数、作用域数、各种类的作用域数、未能解析的名字数、建树耗时与常驻字节，写进实现说明与决策日志；据此决定要不要并行解析。
   - 行为：本包全量测试 debug 与 `swift test -c release` 都通过。
5. **文档** —— 第 17–19 行。
6. **落地（与 `draft-split-symbol-language` 同一天，3.0.0）**：本分支先并入那时的拆分分支或 `next`，重跑全量测试（含 release）；随拆分的落地顺序发本包 3.0.0；两份提案各自取号、改 Implemented。

**收尾时必须判断两件事**（判断结果写进决策日志）：

- 要不要配套专题文章：计划新增实现说明 `Internal/CPlusPlusSymbols.md`。证据规则与「种类会随证据增加而变」是调用方契约，写在类型的文档注释与 README 里；是否另写使用指南在收尾时判断。
- 有没有引入新术语：「证据（evidence）」「未定（undetermined）作用域」是否进术语表在收尾时判断；本包目前没有术语表。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-19 | Created as Draft | 0003 定下要按类、命名空间、成员归类 C++ 符号、解析器引入 LLVM `ItaniumDemangle`，并另写提案；拆分提案又把它与拆分合成同一个 3.0.0。用户选择轻量档，问一轮后写成本提案。 |
| 2026-11-19 | 解析到「归类字段加字符串」 | 用户选择。给作用域路径、基本名、种类与限定，参数、返回类型、模板实参只给字符串。否决：完整语法树（88 种节点镜像成 Swift，API 面与工作量大很多）。 |
| 2026-11-19 | 作用域按证据标，找不到证据的标「未定」 | 用户选择。Itanium 名字分不出类与命名空间。否决：统一只叫「作用域」；没有证据就当命名空间（只导出静态成员函数的类会被误标）。 |
| 2026-11-19 | 只从符号名归类，不读 RTTI | 用户选择。RTTI 与 vtable 的内容以后另写提案。否决：同时读 RTTI 拿基类（范围与测试翻倍，3.0.0 会更晚）。 |
| 2026-11-19 | 写提案时定下的做法 | 未单独提问、写进简报供用户推翻：引入 libcxxabi 那份（匿名命名空间、不改文件，`abort_message.h` 由本包提供），对 Swift 只露 C 接口，不开 C++ 互操作；新模块 `CPlusPlusSymbols`，不进 `MachOFoundation`；独立的 store 与采集，第一次查询时建树，不随语言注册重建；解析结果不常驻，查询时再解析；模板的每个特化各是一个作用域，用 `baseName` 列在一起；当作类型用到的证据只加给树里已有的作用域；完整可读名字与 `__cxa_demangle` 同源；测试用专门的 C++ 夹具；实现分支从 `feature/split-symbol-language` 切出。 |
| 2026-11-19 | 状态 → Accepted | 用户批准，开始实现。 |
