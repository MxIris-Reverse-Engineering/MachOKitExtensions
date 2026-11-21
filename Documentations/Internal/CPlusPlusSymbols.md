# CPlusPlusSymbols：C++ 名字的解析与按作用域归类

> 实现说明，随代码维护。读者：维护者。
> 2026-11 随提案 [0005-cplusplus-symbol-classification](../Evolutions/0005-cplusplus-symbol-classification.md) 新增，与拆分提案 [0004-split-symbol-language](../Evolutions/0004-split-symbol-language.md) 同随 3.0.0 落地。名字的语言判断与采集在 `MachOSymbols`，见 [SymbolIndex.md](SymbolIndex.md)。

## 模块定位

`CPlusPlusSymbols` 回答「这个 C++ 名字说的是哪个作用域里的什么」与「这个镜像有哪些类、命名空间，各自有哪些符号」。它由三层组成：

1. **解析器**（C++ target `CPlusPlusDemangling`）：从 libc++abi 原样引入的 LLVM `ItaniumDemangle`，外面一层纯 C 接口，加上把 AST 拆成归类字段的遍历。
2. **单个名字**（`CPlusPlusSymbolName`）：经 C 接口读出的值类型。
3. **作用域树**（`CPlusPlusSymbolIndexStore`，配 `CPlusPlusScope`、`CPlusPlusSymbol`）：每个镜像一棵，第一次查询时建。

它不进 `MachOFoundation`：那样 MachOSwiftSection、MachOObjCSection 都要编译这份 C++ 代码、链接 C++ 标准库，而它们用不到。

## 文件 → 子系统

| 子系统 | 文件 |
|---|---|
| 引入的解析器 | `Sources/Symbols/CPlusPlusDemangling/ItaniumDemangle/`（五个源文件与 `LICENSE.TXT`）、`Sources/Symbols/CPlusPlusDemangling/abort_message.h` |
| C 接口与遍历 | `Sources/Symbols/CPlusPlusDemangling/include/CPlusPlusDemangling.h`、`Sources/Symbols/CPlusPlusDemangling/CPlusPlusDemangling.cpp` |
| Swift 侧的解析器包装 | `Sources/Symbols/CPlusPlusSymbols/CPlusPlusDemangler.swift`（internal） |
| 单个名字 | `CPlusPlusSymbolName.swift` |
| 作用域树 | `CPlusPlusScope.swift`、`CPlusPlusSymbol.swift`、`CPlusPlusSymbolIndexStore.swift`（含 `Storage`、`ScopeTreeBuilder`、`CPlusPlusSymbolTableRouting`）、`SharedCacheEvictionGroup+CPlusPlusSymbols.swift`（`.cPlusPlusSymbolStore`） |
| 测试夹具 | `Tests/CPlusPlusSymbolsFixture/` |

## 引入的解析器

- **来源**：`swift-project` 里的 llvm-project，提交 `903b9faaae5c`，目录 `libcxxabi/src/demangle`（正本；`llvm/include/llvm/Demangle` 是用 `cp-to-llvm.sh` 拷出的副本）。系统的 `__cxa_demangle` 跑的就是它。许可证 Apache-2.0 WITH LLVM-exception，全文在 `ItaniumDemangle/LICENSE.TXT`。
- **五个文件一字不改**：`ItaniumDemangle.h`、`ItaniumNodes.def`、`StringViewExtras.h`、`Utility.h`、`DemangleConfig.h`。`DemangleConfig.h` 会 `#include "../abort_message.h"`，所以本包在上一级目录放一份只定义 `__abort_message` 的小头文件；它是 `static` 的，不与 libc++abi 自己那个（隐藏的）同名函数冲突。
- **用 libcxxabi 那份、不用 LLVM 那份**：前者的 `DEMANGLE_NAMESPACE_BEGIN` 是匿名命名空间，内部链接，同一进程里链接了 LLVM 也不会撞符号；后者在 `llvm::itanium_demangle`，还要换掉 `llvm-config.h`。代价是 LLVM 那份才有的 `ItaniumPartialDemangler` 用不上——它也只给一整串上下文，不给逐段的作用域与证据，本包照它的走法自己写了遍历。
- **从 `cxa_demangle.cpp` 照抄的两段**（`CPlusPlusDemangling.cpp` 开头，带出处注释）：`parse_discriminator`（`:31-58`，头文件声明了它、定义却在这里，漏了会在链接时报未定义符号）与分配器 `BumpPointerAllocator`、`DefaultAllocator`（`:290-366`）。
- **更新解析器**：把五个文件与 `LICENSE.TXT` 整份换成新提交的；`cmp` 核对与原文件逐字节相同；对照新的 `cxa_demangle.cpp` 看照抄的两段有没有变；跑 `CPlusPlusDemanglingTests` 的 `demangledNameMatchesSystemCxaDemangleForEveryCPlusPlusNameOfLibCPlusPlus`。新解析器可能加了节点或特殊名字：在 `ItaniumNodes.def` 与 `parseSpecialName` 里找新增的，补进遍历（见下一节）与 `CPlusPlusSymbolName.Kind`。

## C 接口与遍历

- **为什么是 C 接口**：Swift 只 import 一个纯 C 头文件，不开 C++ 互操作，下游也不用改任何编译设置。代价是一层取值函数。
- **解析器对象可以复用**：分配器自带 4 KB 的内联缓冲，新建很便宜；建树时整棵树共用一个。它不是线程安全的。输入会先拷进解析器自己的 `std::string`——AST 里的 `string_view` 都指向输入，调用方的缓冲在调用返回后就失效了。
- **文本按需打印**：完整名字、参数、各段作用域名都在第一次取时才打印并缓存，到下一次解析为止有效。建树只取作用域各段与「当作类型用到」的路径，不打印完整名字。
- **作用域路径**：从实体的名字一路往外拆。`NestedName` 拆成多段；`NameWithTemplateArgs` 把实参挂在最后一段上（`vector<int, …>` 是一段）；`LocalName` 先放外层函数的作用域，再放函数本身——打印成不带返回类型、带参数与限定的 `emplace_back<int>(int&&)`——再接着拆局部实体；`AbiTagAttr`、`ModuleEntity`、`GlobalQualifiedName` 透过去；`St` 打印成 `std`；`Sa`、`Ss` 这类替换展开成 `std` 加类型名。每段带一个提示：`std` 与匿名命名空间是命名空间，lambda（`ClosureTypeName`）、无名类型与 `std::allocator` 这类替换是类型，`LocalName` 的外层是函数——外层不带参数时也是：clang 把 ObjC++ 里 ObjC 方法的局部静态变量写成 `Z 26-[CAMetalDrawable texture] E 9onceToken`，外层只是一段名字，3.3.0 以前它因此落成「未定」，下游把方法名当成了命名空间。
- **签名里的类型位置**（3.3.0）：参数与返回类型的文本和其中每个命名类型的位置在同一次打印里得出（`PrintedSignaturePart`），位置因此总与文本相符。先用与「当作类型用到」相同的遍历（`forEachNamedType`：命名类型记下并进入它的模板实参，指针、引用、函数类型这类构造继续往里走，遇到表达式就停）收集这一部分的类型节点；再用 `TypeRecordingOutputBuffer` 打印——它重写 `OutputBuffer` 的 `printLeft` 钩子（`Node::printLeft` 只对 `OutputBuffer` 自己开放，所以调基类的实现），遇到收集到的节点就记下打印前后的位置。打印一个类型的名字时碰到的节点算名字的一部分（`S0_` 会让 `CA::Foo::Bar` 的限定词复用 `CA::Foo` 的节点），只有进了模板实参表才重新开始记；解析器回头插入或回退时（`notifyInsertion`、`notifyDeletion`）同步挪动或丢弃已记的范围。按起点排序，起点相同的长的在前，所以模板排在它实参里的类型之前。
- **特殊名字归位**（`analyzeSpecialName`）：

  | 名字 | 归到 |
  |---|---|
  | vtable、VTT、typeinfo、typeinfo name | 那个类型本身；类型没有自己的名字（指针、内置类型）时放全局 |
  | construction vtable for `Base-in-Complete` | `Complete`；`Base` 记作「当作类型用到」 |
  | non-virtual / virtual / covariant return thunk | 它跳到的函数（作用域、基本名、参数与限定都取那个函数的） |
  | guard variable、reference temporary、两种线程局部例程 | 那个变量（不带签名） |
  | invocation function for block in `f` | `f` 的作用域与基本名，不带 `f` 的签名 |
  | template parameter object、initializer for module | 全局 |

- **当作类型用到的类型**：从参数、返回类型、各段的模板实参出发，只沿类型节点往下走（指针、引用、cv 限定、数组、函数类型、成员指针、模板实参列表、参数包），遇到具名类型就记一条路径，遇到表达式节点就停——表达式里的名字可能是变量或函数。子节点用 `Node::visit` 加各节点的 `match` 通用地列出，`ForwardTemplateReference` 没有 `match`，单独取它的 `Ref`；深度上限 64，防 AST 成环。
- **内置类型的判断**：内置类型与用户写的类名在 AST 里都是 `NameType`。区分办法是看名字的 `string_view` 是否指向输入：用户的类名是从输入里切出来的，内置类型的拼写是解析器里的字符串常量。

## 作用域树（`CPlusPlusSymbolIndexStore`）

- **自己的采集**：`CPlusPlusSymbolTableRouting` 只收 `.cPlusPlus` 的名字，按偏移建索引；不引用已加载镜像的字符串表（C++ 镜像可能被卸载），dyld shared cache 里的镜像照常零拷贝。不复用 `SymbolIndexStore` 的采集：那个索引在有语言注册后会丢掉重建，归类若引用它的行号就得跟着重建。C++ 的判断先于任何注册的语言，所以这棵树不看注册表的代数，永远不因注册而重建。
- **建树**（`ScopeTreeBuilder`）：只看在某个偏移上登记过的行（只被调试条目提到的行不算）。逐行解析，按作用域路径逐段查找或插入（每个作用域按名字索引它的子作用域），把行记进它所在的作用域，累积这一行带来的证据。当作类型用到的路径先放进一个集合，全部行处理完后，只给树里已有的作用域加 `.usedAsType`——没有符号的类型（只声明、只出现在别人签名里的）不进树。
- **种类的判定**：先看是不是函数（局部实体的外层），再看有没有命名空间的证据（全局、`std`、匿名命名空间），再看有没有任何类型的证据，都没有就是「未定」。
- **常驻的内容**：采集结果；每个作用域一条记录（做好的 `CPlusPlusScope` 值、父作用域、按名字排序的子作用域、按偏移排序的成员行号）；限定名到作用域的字典；未能解析的行号。拆开的名字不常驻：`members(of:in:)`、`symbols(for:in:)`、`symbol(named:in:)` 当场用行号取名字再解析，一个名字几微秒。
- **`symbols(for:in:)` 只答规范化偏移**：文件的每行同时登记在原始地址与规范化偏移下（见 SymbolIndex.md），这里过滤掉原始地址的命中。

## 内存与耗时（2026-11-19，Ultra，macOS 27.2 的 JavaScriptCore，`cPlusPlusSymbolIndexCensusOfALargeImage`）

| 读取器 | C++ 行数 | 未能解析 | 作用域（类型 / 未定 / 函数 / 命名空间） | 建树（release） | 符号表（其中复制的名字） | 偏移索引 | 作用域树 |
|---|---|---|---|---|---|---|---|
| 本机 dyld 缓存里的 `MachOFile` | 34,951 | 100 | 7,010（3,910 / 2,117 / 967 / 16） | 0.156 秒 | 4.7 MB（4.0 MB） | 至少 1.6 MB | 约 4.1 MB |
| 进程内的 `MachOImage` | 34,951 | 100 | 同左 | 0.151 秒 | 0.7 MB（0） | 至少 0.8 MB | 约 4.1 MB |

- debug 下建树约 1 秒。release 已经够快，没有做并行解析。
- 100 个未能解析的名字都是 clang 的 `$_N` 闭包名套在模板实参里，系统的 `__cxa_demangle` 同样解析不了；普查测试断言了「本包没解析的，系统也解析不了」。
- 作用域树的字节数是估算：记录本身、路径数组与名字、限定名、子作用域与成员行号，不含 `Dictionary` 的空槽。模板很重的镜像里限定名很长，占了大头。

## 与提案的差异

- 照抄的代码多了 `parse_discriminator`（提案只写了分配器）。
- construction vtable 的基类记作「当作类型用到」，`.virtualTable` 只给完整类。
- 符号表里 C++ 函数中的 block 写作 `____Z…_block_invoke`（四个下划线），`SymbolLanguage` 原先只认 `__Z` 与 `___Z`，这类名字一直被判成 C（2.0.0 起就是这样）。这次在 `MachOSymbols` 里一并修正，见提案决策日志。
- 夹具里的 lambda 分两种：clang 给既非内联、也非模板的函数里的 lambda 起名 `$_0`，不是 Itanium 的 `'lambda'`，所以夹具另加了一个内联函数放 Itanium 命名的 lambda。

## 契约与坑

- **种类是证据推出来的，可能变**：只导出了静态成员函数的类是「未定」；libc++ 的内联命名空间 `std::__1` 里的 `__1` 也是「未定」——名字里没有任何证据，本包不维护约定俗成的白名单。RTTI 由另一份索引 `CPlusPlusClassIndexStore` 读（见 [CPlusPlusClasses.md](CPlusPlusClasses.md)），作用域树仍只看符号名；以后若把两者合起来，「未定」会变少，调用方不要把某个作用域的种类当作永久不变。
- **同一个类在不同镜像里种类可能不同**：作用域只反映这个镜像的符号名。
- **clang 的 `$_N` 闭包**：普通函数里的 lambda 叫 `$_0`、`$_1`……，按 Itanium 规则它只是一段普通名字；它的调用运算符是 `const` 的，所以靠「带限定的成员函数」判成类型。套在模板实参里的 `$_N` 会让解析器整体失败（见普查）。
- **限定名在一个镜像里标识一个作用域**：`scope(named:)` 与 `childScopes(of:)` 都按 `qualifiedName` 查。函数作用域的段带参数（`localThing(int)`），查的时候也要带。
- **夹具要防优化**：夹具的函数都标 `used, noinline`，放 lambda 的函数接收运行时参数——常量参数会让 release 构建把 lambda 折叠掉、符号消失。

## 测试

- `Tests/CPlusPlusSymbolsTests/CPlusPlusDemanglingTests`：C 接口解析符号表写法、拒绝非 Itanium 名字、失败后读不到旧结果；进程内 libc++ 的每个 C++ 名字，完整可读名字与系统 `__cxa_demangle` 逐字一致。
- `CPlusPlusSymbolNameTests`：clang 21（Xcode 27.2）给小段 C++ 生成的真实名字，覆盖函数、模板实参、限定、构造与析构变体、各种特殊名字的归位、局部实体与 lambda、block、函数模板的返回类型、点后缀、变量、解析失败；签名里的类型位置（替换复用的类型、模板实参里的类型、函数指针参数、返回类型、限定词不单列、只有内置类型）。
- `CPlusPlusSymbolIndexStoreTests`：读夹具所在的测试镜像，覆盖每种证据与「未定」、命名空间、函数作用域（含不带参数的 ObjC 方法：夹具用汇编标签手写了一个这样的名字，因为夹具编译器只编 C、C++、Swift）、两种 lambda、模板特化、只出现在签名里的类型不进树、各个查询、`unparsedSymbols`、建与删、注册不触发重建（用独立的注册表与 store 的内部初始化方法）。
- `CPlusPlusSymbolIndexCensusTests`：上面的普查。
