# CPlusPlusClasses：从 RTTI 与 vtable 恢复 C++ 类

> 实现说明，随代码维护。读者：维护者。
> 2026-11 随提案 [0006-cplusplus-class-hierarchy](../Evolutions/0006-cplusplus-class-hierarchy.md) 新增，随 3.1.0 落地，代码在 `CPlusPlusSymbols` 模块里。作用域树（只看符号名）见 [CPlusPlusSymbols.md](CPlusPlusSymbols.md)。

## 模块定位

`CPlusPlusClassIndexStore` 回答「这个镜像有哪些 C++ 类、各自继承谁、虚函数表里每个槽位是什么函数」。它读镜像的数据，不读符号表：

- **RTTI**（run-time type information，C++ 的运行时类型信息）：每个多态类有一个 `std::type_info` 对象（typeinfo），里面有类型的修饰名和基类。符号被剥离的类，typeinfo 照样在数据段里。
- **vtable**（虚函数表）：对象的虚指针指向表中的 address point，即第一个函数槽位；它前面一格是 RTTI 指针，再前面一格是 offset-to-top（子对象到完整对象开头的距离，主表为 0）。多重继承、虚继承的类还有副表。

槽位的名字在查询时取：实现自己有 C++ 符号就用它，否则沿主基类链取同一槽位的名字，基类可以在别的镜像里。作用域树不变，两边的限定名由同一个解析器打印，按限定名对应。

## 文件 → 子系统

| 子系统 | 文件（`Sources/Symbols/CPlusPlusSymbols/`） |
|---|---|
| 公开类型 | `CPlusPlusClass.swift`、`CPlusPlusVirtualTable.swift`（含 `CPlusPlusVirtualFunction`） |
| store 与索引 | `CPlusPlusClassIndexStore.swift`（`Storage`、查询时的 `ClassResolver`、`LocatorCache`）、驱逐组 `.cPlusPlusClassStore` |
| 读指针 | `RuntimeTypeInformation/IndexedImage.swift`、`ImagePointerSlots.swift` |
| libc++abi 的标记 | `RuntimeTypeInformation/RuntimeLibraryMarkers.swift` |
| 找 typeinfo 与 vtable | `RuntimeTypeInformation/TypeInfoScanner.swift`、`VirtualTableScanner.swift` |
| 补名与跨镜像 | `RuntimeTypeInformation/VirtualFunctionNaming.swift`、`BaseClassLocator.swift` |
| 测试 | `Tests/CPlusPlusSymbolsTests/` 的 `ImagePointerSlotsTests`、`CPlusPlusClassIndexStoreTests`、`CPlusPlusVirtualFunctionNamingTests`、`CPlusPlusClassIndexCensusTests`，辅助在 `ClassIndexTestImages.swift`；夹具在 `Tests/CPlusPlusSymbolsFixture/Fixture.cpp` 的 `hierarchy` 命名空间 |

## 读指针的三条路（`ImagePointerSlots`）

偏移一律用符号索引的口径：进程内镜像是相对 mach header 的偏移，cache 里的镜像是「未滑动地址减 `sharedRegionStart`」，独立文件是文件偏移（见 `SymbolValueOffsetConverter`）。

| 镜像 | 一个槽位装着什么 | 怎么判断「不是指针」 |
|---|---|---|
| 独立文件 | 复用 `machO.cached.fixupPointers`（整文件的链式指针表，随 `MachOFile` 常驻、与别的使用方共享）；rebase 给本镜像偏移，bind 给符号名、addend 和来源库。没有链式 fixup 的旧文件读 `rebases` 与 `bindingSymbols`（opcode） | 表里没有这一格 |
| dyld shared cache 里的文件 | 逐槽 `DyldCache.resolveOptionalRebase(at:)`，不经带记忆的 `resolveRebase(fileOffset:)`（那会把每个槽都记进字典）；地址落在本镜像段里给本镜像偏移，否则给 cache 里的未滑动地址 | 值在 `[-2^31, 2^31)` 之内 |
| 进程内镜像 | 直接读内存，用 `InProcessContext.addressMask` 去掉签名与 tag | 同上 |

- **为什么不逐槽问 `resolveBind(fileOffset:)`**：MachOKit 的 `MachOFile.resolveBind(at:)` 每次都把每个段的链式指针从头列一遍，逐槽调用是平方级。
- **整数与指针的界限**：offset-to-top、vcall 偏移是不大于 0 的小整数，虚基类偏移是正的小整数。cache 指针格式里带签名的指针最高位为 1、下一跳字段非零，原始值远小于 `-2^31`；不带签名的指针若值小于 2^31，解出的地址落在 cache 头部，不在任何镜像里，照样不会被当成函数。
- **指针的最高字节**：rebase 目标带 `high8` 时一并读出（`topByte`），Apple arm64 用名字指针的 bit 63 标「非唯一 RTTI」（见下）。

## 找 typeinfo（`RuntimeLibraryMarkers`、`TypeInfoScanner`）

- **标记**：typeinfo 的第一个字是虚指针，指向 libc++abi 三个 vtable 之一再加 16：`__class_type_info`（无基类，16 字节）、`__si_class_type_info`（一个 public、非虚、偏移为 0 的基类，24 字节）、`__vmi_class_type_info`（其余，`24 + 16 × 基类数` 字节）。独立文件看 bind 的符号名与 addend；cache 文件按 cache 的镜像清单找到 `/usr/lib/libc++abi.dylib`，从它的导出表取地址；进程内用 `dlsym`；镜像本身就是 libc++abi 时比自己导出的偏移。同样的办法认出 `___cxa_pure_virtual` 与 `___cxa_deleted_virtual`。
- **扫描范围**：名字以 `__DATA`、`__AUTH` 开头的段里的普通节，跳过 zerofill、`__got`、`__auth_got`、`__la_symbol_ptr`、`__nl_symbol_ptr`、`__cfstring`、`__mod_init_func`、`__mod_term_func`、`__init_offsets`、`__objc_*`、`__thread_*`。
- **解析**：`+8` 是名字指针，指向不带 `_Z` 的修饰名（`N4llvm5ValueE`）；si 的 `+16` 是基类指针；vmi 的 `+16` 是 `__flags`（`0x1` 重复基类、`0x2` 菱形），`+20` 是基类数（超过 1,024 视为不是 typeinfo），`+24` 起每个基类 16 字节：指针加 `__offset_flags`（`0x1` 虚、`0x2` public，`>> 8` 是偏移）。布局来自 libc++abi 的 `private_typeinfo.h`。
- **非唯一 RTTI**：arm64 的 Apple 平台上，没有唯一定义的 hidden 类型（例如没有 key function、只有内联虚函数的 hidden 类）的名字指针 bit 63 为 1（libc++ 的 `_LIBCPP_TYPEINFO_COMPARISON_IMPLEMENTATION` 为 3）。读名字前要清掉，`hasUniqueTypeInfo` 就是这一位取反。
- **名字**：修饰名前面拼上 `__ZTS` 交给 `CPlusPlusDemangler`，种类是 `typeInfoName` 时取作用域路径，和作用域树的打印一致；解析不了的类仍收录，限定名用原样的修饰名。
- **`__ZTI` 符号只用来标 `hasTypeInfoSymbol`**：提案原想把 `__ZTI` 符号并进发现结果防漏，实现时发现 typeinfo 的虚指针一定是 fixup，扫描不会漏，就没有并。

## 找 vtable、分组（`VirtualTableScanner`）

- **RTTI 格**：内容指向本镜像某个 typeinfo、不在任何 typeinfo 对象之内（排除 si、vmi 里的基类指针）、前一格是不大于 0 的小整数（offset-to-top）。
- **槽位**：从 RTTI 格的下一格起，逐格读到不是函数为止：本镜像可执行节里的 rebase、addend 为 0 且名字不以 `__ZTV`、`__ZTI`、`__ZTS`、`__ZTT`、`_OBJC_` 开头的 bind、别的镜像 `__TEXT` 段里的地址，以及纯虚、deleted 两个标记。遇到另一个 RTTI 格或 typeinfo 也停。
- **分组**：同一个类的表按地址排好，后一张的 offset-to-top 与前一张的末尾之间只隔着小整数（不超过 64 格）就算同一组。主表在前，副表跟在后面。
- **哪组是自己的**：有虚基类的类还会被别的类的 construction vtable 指向（探针实测：`Intermediate-in-Complete` 的 RTTI 指向 `Intermediate` 自己），所以可能有不止一组。有 `__ZTV` 符号时取符号之后最近的那组，否则取第一组——没有符号又有多组时可能取错，这是已知局限。

## 补名（`VirtualFunctionNaming`、`ClassResolver`）

- **主基类**：第一个偏移为 0、非虚、有 vtable 的直接基类。主表第 i 格对应主基类主表的第 i 格；第 i 格超出主基类的表长，就是这个类自己引入的虚函数，没有基类函数。Itanium 规则里「几乎为空的虚基类」也能当主基类，这里不处理。
- **副表**：offset-to-top 等于「负的子对象偏移」的那个基类子对象是副表的主人，副表第 i 格对应主人主表的第 i 格。子对象按直接基类展开（非虚基类偏移相加，基类在别的镜像也照样展开）；虚基类的偏移从这个类自己主表前缀里那一格读。基类的基类里的虚基类不展开。
- **名字从哪来**：实现自己的 C++ 符号（`CPlusPlusSymbolIndexStore.symbols(for:in:)`，剥离后留下的 `<redacted function N>` 不是 C++ 名字），或 bind 的符号名，或另一个镜像里落在那个地址上的 C++ 符号。没有就沿主基类链往上找第一个有名字的同一格，`BaseFunction.className` 是给出名字的那个基类。
- **继承还是覆盖**：和直接主基类同一格比较实现。同一个独立文件比偏移，cache 与进程内比绝对地址，否则比修饰名（派生类 bind 到基类导出的那个函数，就是原样继承）。
- 递归深度上限 64，防坏数据成环。

## 跨镜像（`BaseClassLocator`）

| 根镜像 | 怎么找基类所在的镜像 |
|---|---|
| 进程内 | `dladdr` 找到地址所在的已加载镜像 |
| cache 里的文件 | 同一个 cache 里找。代码地址用 `CacheImageLocator`（按各镜像 `__TEXT` 的起点二分，每个 cache 一个）。typeinfo 这样的数据地址不能这么找：cache 把各镜像的数据段集中放在文本之后，按起点找会落到不相干的镜像（实测把 libc++ 的 typeinfo 归到了 `libobjcMsgSend11.dylib`）。所以先核对候选镜像的段范围，对不上再沿根镜像的依赖逐个打开核对（最多 512 个，按 cache 镜像清单的 install name 找到各自的文本起点） |
| 独立文件 | `FileDependencyLocator` 按 bind 来源库的 install name 找。库的导出表里这个符号若标着 re-export，就按条目里的库序号与原名到那个库里找（macOS 27 的 libc++ 就这样逐个符号转出 libc++abi 的 `std::exception`，它没有 `LC_REEXPORT_DYLIB`）；不是 re-export 又没有定义，再跟着 `LC_REEXPORT_DYLIB` 整库转出往下找。最多 4 层。flat 或 weak 查找的 bind 没有来源库，按根镜像的依赖顺序逐个找 |

- 独立文件的默认搜索路径是 `DependencySearchPath.inferred(forRoot:)` 加本机 cache；`@rpath` 兄弟框架要用带 `dependencySearchPaths:` 的重载显式给出（`MachODependencies` 不展开 `@rpath`）。
- store 按「镜像身份 + 搜索路径」缓存定位器（`LocatorCache`），基类镜像的索引经同一个 store 在 `SharedCache` 里缓存。
- `CPlusPlusClass.Base.location` 对 cache 与进程内的基类给出所在镜像的路径（提案原写 `nil`，实现时能拿到就给了）。

## 测试

- `ImagePointerSlotsTests`：夹具镜像的文件与进程逐槽一致（rebase 指向同一偏移，bind 的符号就是 dyld 绑定的那个）；JavaScriptCore 的 cache 文件与进程逐槽一致（cache 地址加 slide 等于进程地址）；只比 `__DATA_CONST` 与 `__AUTH_CONST`，其余数据段加载后可能被改写。
- `CPlusPlusClassIndexStoreTests`：夹具的 `hierarchy` 命名空间覆盖单继承、多重继承与 thunk、纯虚、deleted、`std::exception` 子类、hidden 内联类、匿名命名空间；`fixture` 里原有的虚继承类覆盖 construction vtable。每个测试对进程内镜像与测试包文件各跑一遍。
- `CPlusPlusVirtualFunctionNamingTests`：补名规则用编造的类测；跨镜像补名用测试运行时现编的两个 dylib（`Base` 导出类，`Derived` 经 `@rpath` 链接它、hidden 覆盖被 `strip -x` 剥掉名字；另一份用 `-Wl,-no_fixup_chains` 链接，走旧式 opcode）。照 `FixupResolutionMemoTests` 的先例在运行时编，不往仓库放二进制。
- `CPlusPlusClassIndexCensusTests`：见下节。

## 普查（2026-11-20，Ultra，macOS 27.2，debug 构建，`CPlusPlusClassIndexCensusTests`）

| Espresso 的读法 | 类（其中没有 `__ZTI` 符号） | 有 vtable | 表 | 槽位 | 自己有名 / 经基类补名 / 无名 | 建索引 | 给每个类的每个槽位取名 |
|---|---|---|---|---|---|---|---|
| 本机 cache 里的 `MachOFile` | 4,379（643） | 3,338 | 3,506 | 56,204 | 52,788 / 38 / 3,378 | 8.0 秒 | 9.7 秒 |
| 进程内的 `MachOImage` | 同左 | 同左 | 同左 | 同左 | 同左 | 0.29 秒 | 2.2 秒 |

- 两种读法逐类、逐表、逐槽位一致。耗时包括顺带给基类所在的镜像（MIL、libc++ 等）建索引。
- **cache 模式比进程内慢约 10 倍**：数据段已经一次读出、一次定位子 cache，剩下的大头推测是逐个指针经 `DyldCache.resolveOptionalRebase(at:)` 解码（没有做过采样）。后续项：采样确认后，按 cache 的 slide info 格式直接解码。
- **表长**：Espresso 里有 `__ZTV` 符号的 3,008 组表，3,001 组正好在下一个符号处结束，其余 7 组提前结束（后面隔着填充），没有一组越界。
- **JavaScriptCore 没有类**：WebKit 编译时关了 RTTI（`-fno-rtti`），所以普查用 Espresso；JavaScriptCore 只留在逐槽对照测试里。
- **TSTables（iWork 14.5，arm64 切片）**：611 个类（167 个没有 `__ZTI` 符号）、606 张表、12,518 个槽位；6,676 个自己有名，1,520 个经基类补名（TSTables 自己的基类与 TSPersistence 的 `google::protobuf::Message`，另有 `std::exception` 子类的 2 个析构槽经 libc++abi），4,322 个无名。建索引 2.2 秒，补名 1.1 秒。资料在 Ultra 的 `/Volumes/Repositories/Private/Personal/App/OpenNumbers/Dumps/macOS/14.5/Frameworks`，公司那台在 `/Volumes/RE/iWork/macOS/14.5/Frameworks`（两边 UUID 相同），用 `CPLUSPLUS_CLASS_CENSUS_FRAMEWORKS` 指定。
- **补名补不上的主要原因**：类自己引入的虚函数没有基类可借；基类那一格本身也没名字（`Message` 的析构函数在 TSPersistence 里同样只剩 `<redacted function N>`）；纯虚槽位不算名字。

## 已知局限

- 有虚基类、又没有 `__ZTV` 符号、找到不止一组表时，取地址最小的一组，可能是别的类的 construction vtable。
- 只展开类自己的虚基类；基类的基类里的虚基类不展开，它们的副表认不出主人。
- 「基类的基类也在别的镜像」没有单独的测试，只由 Espresso 普查间接覆盖。
- 32 位 Mach-O 与 MSVC 的 RTTI 不支持；本包自 3.2.0 起不支持 Linux。

## 契约与坑

- **种类与名字都是推出来的**：`baseFunction` 以后可能从 `nil` 变成有值（例如以后处理虚基类当主基类），调用方不要当作永远不变。
- **测试宏里不能隐式打开 existential**：`#expect`、`#require` 里直接写 `store.class(named:in: machO)`，`machO` 是 `any MachORepresentableWithCache` 时编不过，先赋给局部变量。
