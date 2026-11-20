# Draft - 从 RTTI 与 vtable 恢复 C++ 类：继承关系、虚函数表，以及沿基类给无名虚函数补名

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-20
- **最后更新**: 2026-11-20
- **所属愿景**: 无
- **关联提案**: 本包 [0005-cplusplus-symbol-classification](0005-cplusplus-symbol-classification.md)（只从符号名归类，非目标里写明「读 RTTI 或 vtable 的内容以后另写提案」）；之后另写的 protobuf 描述符还原提案（slug 预定 `protobuf-descriptor-recovery`，排在本提案之后，按类名挂到本提案的类上）
- **实现分支 / PR**: `feature/cplusplus-class-hierarchy`，从 `main` 切出；worktree 在 `.worktrees/MachOKitExtensions-CPlusPlusClassHierarchy`
- **配套文档**: 实现说明 [Internal/CPlusPlusClasses.md](../Internal/CPlusPlusClasses.md)
- **网页版**: 同目录同名的 `.html`

## 摘要

`CPlusPlusSymbols` 模块新增一个按镜像建索引的 store `CPlusPlusClassIndexStore`，从镜像的数据里读 Itanium C++ ABI 的运行时类型信息（RTTI，即 `std::type_info` 对象）和虚函数表（vtable），不依赖符号表。它给出三样东西。**类**（`CPlusPlusClass`）：镜像里每个有 typeinfo 的类，名字取自 typeinfo 里的名字串，所以符号被剥离的类也找得到；带直接基类，以及每个基类的偏移、是否虚继承、是否 public，基类可能在别的镜像里。**虚函数表**（`CPlusPlusVirtualTable`）：主表与多重继承、虚继承下的副表，每张表的 offset-to-top 和每个槽位指向的实现。**虚函数**（`CPlusPlusVirtualFunction`）：槽位的实现自己有 C++ 名字就用它；没有（被剥离、只剩 `<redacted function N>`）时，沿主基类链找同一槽位的名字，基类在别的镜像里也跟过去——进程内的镜像在进程里找，dyld shared cache 里的镜像在同一个 cache 里找，独立文件按调用方给的依赖搜索路径找。现有的作用域树（`CPlusPlusSymbolIndexStore`）不变；两边的限定名用同一个解析器打印，调用方可以拿类名去作用域树里取非虚成员。纯新增 API，随本包 3.1.0 发布。

## 动机

- **0005 只读符号名，剥离过的 C++ 类看不见。** 0005 的作用域树完全来自符号表；它的非目标一节写明「读 RTTI 或 vtable 的内容（基类、虚函数表布局）：以后另写提案」，`CPlusPlusScope.Kind` 的文档注释也预告了「以后读 RTTI，『未定』会变少」。release 构建会剥掉 hidden 的 C++ 符号，而这些类的 typeinfo 与 vtable 仍在数据段里。
- **具体场景：逆向 iWork。** `/Volumes/RE/iWork/macOS/14.5/Frameworks/TSTables.framework` 的 arm64 切片（统计见前期调研）：
  - 有 611 个类带 typeinfo，其中 167 个没有任何符号，只能从 RTTI 的名字串里得知类名（例如 `GSUNSWrapper<TSTCellDiff>`、`RTree<unsigned int, 2, double, 16, 8>`、`TSTUidOrderNode`）；
  - 继承关系、虚函数槽位，现在完全无从得知；
  - 7,028 个本镜像里的虚函数，2,988 个只剩 Apple 剥离后留下的 `<redacted function N>`。
- **继承链能补回相当一部分名字。** 派生类主表的第 i 个槽位，就是主基类主表第 i 个槽位所声明的那个虚函数（覆盖或继承）。在 TSTables 上沿基类链（含 TSPersistence 里的 `google::protobuf::Message`）补名，5,805 个缺 C++ 名的槽位里能补回 2,163 个（见前期调研）。
- **别的来源补不了这一块。** ObjC ivar 的类型编码带 C++ 结构体的字段，但只覆盖按值嵌进 ivar 的类型，而那些多是没有虚函数的值类型：TSTables 的 611 个 RTTI 类里只有 4 个出现在 ObjC 头文件的结构体定义里。字段另有 protobuf 描述符这条路，排在本提案之后另写。

## 前期调研

**Itanium C++ ABI 的对象布局**（libc++abi 源码：`/Volumes/SwiftProjects/swift-project/llvm-project/libcxxabi/src/private_typeinfo.h`，与 0005 引入解析器时同一份检出）

- `std::type_info`：`vptr`、`__type_name`（`const char*`，指向不带 `_Z` 的类型修饰名，例如 `N4llvm5ValueE`）。
- 三种类的 typeinfo，靠 `vptr` 指向哪个 libc++abi vtable 区分（指向 vtable 起点加 16，即跳过 offset-to-top 与 RTTI 两格）：
  - `__cxxabiv1::__class_type_info`（`:123`）：没有基类，对象 16 字节。
  - `__si_class_type_info`（`:146`）：恰好一个 public、非虚、偏移为 0 的基类，`+16` 是基类 typeinfo 的指针，对象 24 字节。
  - `__vmi_class_type_info`（`:180-190`）：`+16` 是 `unsigned __flags`（`__non_diamond_repeat_mask = 0x1`、`__diamond_shaped_mask = 0x2`），`+20` 是 `unsigned __base_count`，`+24` 起是 `__base_count` 个 `__base_class_type_info`（`:162-173`）：基类 typeinfo 指针，加一个 `long __offset_flags`（`__virtual_mask = 0x1`、`__public_mask = 0x2`、偏移在 `>> 8`）。非虚基类的偏移是子对象在类里的偏移；虚基类的偏移是「虚基类偏移存在 vtable 里的哪一格」（相对 address point，为负）。
  - 其余 typeinfo（指针、基本类型、枚举、函数、数组、成员指针，`:29-50`、`:204-250`）不描述类，本提案不读。
- **Apple arm64 的非唯一 RTTI 标记**（`/Volumes/SwiftProjects/swift-project/llvm-project/libcxx/include/typeinfo:144-181`、`:233`）：arm64 的 Apple 平台上 `_LIBCPP_TYPEINFO_COMPARISON_IMPLEMENTATION` 为 3，非唯一类型的 `__type_name` 指针最高位（bit 63）置 1，表示比较时要比字符串；取名字前要清掉这一位。哪些类型非唯一，由 clang 的 `classifyRTTIUniqueness` 决定：只有链接属性为 linkonce_odr 或 weak_odr、且默认可见性的类型——没有 key function 的类（虚函数全是内联的）、模板特化——每个镜像各留一份隐藏的副本并置这一位；hidden 类型反而是唯一的（实现时由夹具测出，见决策日志）。TSTables 的 611 个 typeinfo 里有 54 个带这个标记（`dyld_info -fixups` 显示目标形如 `0x800000000116CB3D`）；不清掉就读到一串乱码。

**vtable 的形状**（本机 Xcode 27.2 的 Apple clang 21，`clang++ -arch arm64 -shared -O1` 编一个带虚继承与多重继承的小探针，用 `nm` 与 `dyld_info -fixups` 看）

- 主表：`[虚基类与 vcall 偏移……][offset-to-top = 0][RTTI 指针][槽位……]`；`__ZTV` 符号指向整组的第一格，vptr 指向第一个槽位（address point）。
- 多重继承：主表后面紧跟副表 `[offset-to-top = -16][RTTI 指针，指向同一个类][槽位……]`，副表的槽位多是 `__ZThn16_…` 这样的 non-virtual thunk。
- 虚继承：类有 VTT（`__ZTT`）和 construction vtable（`__ZTC8Complete0_12Intermediate`，「Intermediate-in-Complete」）。**construction vtable 的 RTTI 指针指向基类 `Intermediate` 自己的 typeinfo，不是 `Complete` 的**，并且它是独立于 `Intermediate` 主表的另一组对象。所以只按「RTTI 指向谁」分组时，有虚基类的类可能找到不止一组表。
- 虚析构函数在表里占两格（complete 与 deleting）。
- 纯虚函数的槽位绑到 `___cxa_pure_virtual`；`= delete` 的虚函数绑到 `___cxa_deleted_virtual`。

**TSTables 的实测**（2026-11-20，`/Volumes/RE/iWork/macOS/14.5/Frameworks/TSTables.framework/Versions/A/TSTables` 的 arm64 切片，用 `nm`、`dyld_info -fixups` 与一次性的 Python 统计；镜像带链式 fixup，没有 arm64e 签名）

| 项 | 数量 |
|---|---|
| 导出的 C++ 符号（全部是外部符号，hidden 的已剥离） | 13,164 |
| typeinfo（绑到 `__class_type_info` / `__si_class_type_info` / `__vmi_class_type_info` 的 vtable + 16） | 611（53 / 558 / 0） |
| 其中有 `__ZTI` 符号的 | 444 |
| 单继承的基类：本镜像 / TSPersistence 的 `google::protobuf::Message` / libc++ 的 `std::exception` | 123 / 434 / 1 |
| vtable（主表；没有副表，因为没有多重继承） | 606；另有 5 个 typeinfo 没有 vtable |
| 槽位：指向本镜像 / 绑到别的镜像（其中纯虚或 deleted） | 10,310 / 2,208（6） |
| 本镜像里的不同虚函数：有 C++ 名 / 只有 `<redacted function N>` | 4,040 / 2,988 |
| 缺 C++ 名的槽位 / 沿基类链（含 TSPersistence 的 `Message`）补回的 | 5,805 / 2,163 |

- `Message` 在 TSPersistence 里有 `__ZTVN6google8protobuf7MessageE` 与 `__ZTIN6google8protobuf7MessageE` 两个导出符号，主表 20 个槽位、16 个有名字。
- 补不回的槽位主要是类自己新引入的虚函数（槽位号超出主基类的表长），基类里没有对应的名字。
- 扫描时，「前一格不是指针、本格指向某个 typeinfo」的槽位共 606 个，正好是 606 张表的 RTTI 格；另外 123 个指向 typeinfo 的槽位是 si typeinfo 里的基类指针（位于某个 typeinfo 的 `+16`）。槽位向后读到「不是函数指针」为止，606 张表全部停在下一个对象的边界上（没有逐一对照符号核对，核对放进普查测试）。
- `std::exception` 的基类指针绑到 `libc++/__ZTISt9exception`：libc++ 用 `LC_REEXPORT_DYLIB` 转出 libc++abi，定义在后者里，跨镜像找基类要跟着转出走。

**本包现有的基础设施**

- `MachOKitExtensions` 的 `MachOFile.resolveBind(fileOffset:)`（`Sources/MachOKitExtensions/MachOFile+.swift:106-130`）有按槽记忆，但它底下 MachOKit 的 `MachOFile.resolveBind(at:)`（`../MachOKit/Sources/MachOKit/MachOFile.swift:927-950`）每次调用都把每个段的链式指针从头列一遍再找匹配。逐槽调用十几万次是平方级的，所以本提案自己把链遍历一次、建「槽位 → 内容」表，不逐槽问它。
- `MachOAddressResolution`（`@_spi(Internals)`）：`SlotResolver`（`Sources/MachOAddressResolution/SlotResolver.swift:15-53`，只收 `MachOFile`，逐槽回答 bind 名或 rebase 目标）、`ImageAddressSpace`（offset 与地址互换、段范围判断）、`CacheImageLocator`（`CacheImageLocator.swift:18-82`，cache 里按地址找镜像、懒打开）。cache 镜像的 offset 口径是「未滑动地址减 `sharedRegionStart`」（`Documentations/Internal/MachOAddressResolution.md`）。
- `MachODependencies`：`FileDependencyLocator(searchPaths:preferredCPU:platforms:rootDyldCache:)` 与 `locate(loadName:)`（`FileDependencyLocator.swift:54-163`）；`@rpath` 不展开，兄弟框架要调用方以 `.machOFile(path:)` 显式给出（`Documentations/Internal/DependencyResolution.md`）。`DependencySearchPath` 是 `Hashable`。
- `MachOReading`：`InProcessContext.addressMask` 是本进程地址里真正属于地址的位，读进程内指针时用它去掉 PAC 签名与 tag。
- 0005 的 store 形状：`.shared` 加「方法 + `in: machO`」，按镜像在 `SharedCache` 里缓存，`prepare` / `contains` / `remove`（`Sources/CPlusPlusSymbols/CPlusPlusSymbolIndexStore.swift`）。限定名由 `CPlusPlusSymbolName` 打印，作用域树按 `qualifiedName` 查作用域。
- 包的最低平台是 macOS 10.15；测试夹具 `Tests/CPlusPlusSymbolsFixture` 已有 `Polymorphic`、`VirtualBase` / `Intermediate` / `Complete`（虚继承）等类。测试包的二进制用链式 fixup 还是旧式 opcode，取决于链接器对部署目标的处理，**未查证**，第 1 步先确认。

**相近的做法**

- IDA 的 Hex-Rays 与开源脚本（ClassInformer、`ida_medigate` 之类）都按「找 type_info → 找引用它的 RTTI 格 → 读 vtable」的路子恢复类，靠符号或地址范围判断表长。本提案的发现与表长规则与此相同，另外利用 fixup 信息判断「这一格是不是指针」，比只看数值可靠。
- proto-dump（`MxIris-Reverse-Engineering/proto-dump`）从字节里搜 protobuf 描述符；它属于字段还原，归之后的 protobuf 提案。

## 提议方案

1. **新 store `CPlusPlusClassIndexStore`，放在现有 `CPlusPlusSymbols` 模块与 product 里。** 形状照 0005 的 `CPlusPlusSymbolIndexStore`：`.shared`，方法带 `in: machO`，每个镜像第一次查询时建一次，缓存在新的驱逐组 `.cPlusPlusClassStore` 下。作用域树不动。
2. **读指针分三条路，对上层统一成「槽位里装着什么」。** 内部类型 `ImagePointerSlots` 回答「某个偏移上的 8 字节是不是指针、指向本镜像的哪个偏移，或者指向别的镜像的什么」：
   - 独立文件：把链式 fixup 的每条链遍历一次（没有链式 fixup 的旧文件改读 `LC_DYLD_INFO` 的 rebase 与 bind opcode），建成「偏移 → rebase 目标 / bind 的符号名、addend、来源库」的表；建完索引就丢掉。
   - dyld shared cache 里的镜像：逐槽按 cache 的指针格式解码（MachOKit 的 `DyldCache.resolveOptionalRebase(at:)`），不经带记忆的 `resolveRebase(fileOffset:)`，否则每个槽都会被记进字典。指向别的镜像的是 cache 里的未滑动地址。
   - 进程内的镜像：直接读内存，用 `InProcessContext.addressMask` 去掉签名；指向别的镜像的是进程地址。
3. **找 typeinfo：扫描加符号。** 扫描本镜像数据段里的普通节，找内容是「三个 `__cxxabiv1` 类 typeinfo 的 vtable + 16」的槽位，每个就是一个 typeinfo 对象的开头。独立文件看 bind 的符号名；cache 与进程内先找到 libc++abi 里那三个 vtable 的地址再比；镜像本身就是 libc++abi 时，比的是自己的导出。另外把 `__ZTI…` 符号指着的地方也并进来，防扫描漏掉。
4. **读 typeinfo。** 名字指针清掉 bit 63 后读出名字串，前面拼上 `__ZTS` 交给现有的解析器，得到与作用域树同样格式的作用域路径与限定名；si 读一个基类，vmi 读 `__flags` 与全部基类。基类指针指向本镜像就记下它的 typeinfo 偏移；指向别的镜像就记下外部引用（独立文件是 `__ZTI…` 符号名与来源库，cache 与进程内是地址），基类名字从符号名或另一个镜像的名字串取。
5. **找 vtable。** 指向某个本镜像 typeinfo 的槽位，若不在任何 typeinfo 对象之内、前一格不是指针且数值在 `[-2^31, 0]` 之内，它就是一张表的 RTTI 格，前一格是 offset-to-top。从 RTTI 格的下一格起逐格读槽位，直到遇到不是函数的格：函数是指向本镜像可执行节的 rebase、指向别的镜像函数的 bind 或地址，以及 `___cxa_pure_virtual` / `___cxa_deleted_virtual`；`__ZTV`、`__ZTI` 与 `_OBJC_` 开头的 bind 不算。
6. **把表归成组，认出主表与副表。** 同一个类的若干张表，地址相连、中间只隔着不是指针的格（下一张表的 offset-to-top 与 vcall、虚基类偏移），就是同一组；offset-to-top 为 0 的是主表，其余是副表。有 `__ZTV` 符号的类取符号所在的那组；没有符号又有不止一组时（只会出现在有虚基类的类上，多出来的是 construction vtable），取地址最小的那组，并在实现说明里写明这是已知局限。
7. **给副表认出它属于哪个基类子对象。** 非虚基类按 typeinfo 里的偏移递归展开（基类的基类，偏移相加，基类在别的镜像也照样展开）；虚基类读主表前缀里那一格虚基类偏移，得到它在本类里的偏移。offset-to-top 等于「负的子对象偏移」的那个基类就是副表的主人；同一偏移上有多层基类时取最外层的那个。
8. **槽位的名字。** 实现自己有名字时用它：本镜像里落在实现上的 C++ 符号，bind 的符号名，或者另一个镜像里落在那个地址上的 C++ 符号。再沿主基类链（副表沿它所属的基类）取同一槽位的名字作为「基类函数」，并判断是覆盖还是原样继承：两边指向同一个实现（同一镜像的同一偏移，或同名的导入）就是继承。槽位号超出基类表长的，是这个类自己引入的虚函数，没有基类函数。
9. **跨镜像找基类。** 外部基类按镜像来源定位：进程内按地址找到所在的已加载镜像；cache 里用 `CacheImageLocator` 在同一个 cache 里找；独立文件用 `FileDependencyLocator` 按 bind 来源库的 install name 找，找到的镜像若只是转出（导出表里标了 re-export，或经 `LC_REEXPORT_DYLIB` 整库转出），继续跟到真正定义的镜像。找到后在那个镜像上同样用本 store 建索引、按 typeinfo 偏移取类，所以基类的基类也能继续往上找。找不到的基类只留名字，不补槽位名。
10. **独立文件的搜索路径。** 通用的 `virtualTables(of:in:)` 对独立文件默认用「从文件位置推断的路径（`DependencySearchPath.inferred(forRoot:)`）加本机 cache」；`@rpath` 指向的兄弟框架（TSTables 的 TSPersistence 就是）要用带 `dependencySearchPaths:` 的重载显式给出。
11. **发版**：本包 3.1.0，纯新增，不需要下游配合。

### 非目标

- 读类的字段：RTTI 与 vtable 都不带字段。protobuf 消息类的字段归之后的 protobuf 提案；ObjC ivar 编码里的 C++ 结构体要在依赖本包的下游合并。
- 非类的 typeinfo（指针、枚举、函数、数组、成员指针、基本类型）。
- 把 RTTI 找到的类并进 0005 的作用域树、或给作用域加 RTTI 证据：两份索引各自独立，调用方按限定名关联。并进去要让建树依赖读数据段，留给以后需要时另写提案。
- 没有符号时可靠地区分自己的 vtable 与 construction vtable（见方案第 6 条）；VTT 的内容。
- 反查「某个函数出现在哪些 vtable 的哪个槽位」。
- 用 arm64e 槽位签名里的判别值（由方法的修饰名算出，推测，未验证）去核对覆盖关系。
- MSVC 的 RTTI 布局；32 位 Mach-O。
- 在 Linux 上验证（同 0005）。
- RuntimeViewer、swift-section 等下游采用：各自另写提案。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `Package.swift` | 修改 | `CPlusPlusSymbols` 加依赖 `MachOReading`、`MachOAddressResolution`、`MachODependencies`；`CPlusPlusSymbolsTests` 加 `MachOReading`、`MachODependencies` 依赖。文件末尾那段 Tuist 适配块（`origin/main` 的 `9d5a945`，来自 MachOSwiftSection 提案 0099，只在 `TUIST_MAPS_LOCAL_PACKAGE_TESTS=1` 时生效）保持在最后：它要在所有 target 与 product 声明完之后才运行 | 读指针、跨镜像定位 | 1 |
| `Sources/CPlusPlusSymbols/RuntimeTypeInformation/IndexedImage.swift`、`ImagePointerSlots.swift` · `IndexedImage`、`ImagePointerSlots`（含 `Content`）（internal） | 新增 | 三种读取器：独立文件复用 `cached.fixupPointers` 或读 opcode 的 rebase 与 bind，cache 文件把数据段的指针一次解码，进程内读内存去签名；小整数不当指针；回答 `content(atOffset:)`、`word(atOffset:)`、可执行范围、数据节的槽位遍历 | 上层的发现与解析不关心读取器 | 1 |
| `Sources/CPlusPlusSymbols/RuntimeTypeInformation/RuntimeLibraryMarkers.swift` · `RuntimeLibraryMarkers`（internal） | 新增 | libc++abi 三个类 typeinfo vtable 与 `__cxa_pure_virtual`、`__cxa_deleted_virtual` 在本镜像里的样子：bind 名、cache 里的地址（按 cache 镜像清单找到 libc++abi 再查导出表）、进程内 `dlsym`、镜像自己就是 libc++abi 时的偏移 | 方案第 3 条 | 2 |
| `Sources/CPlusPlusSymbols/RuntimeTypeInformation/TypeInfoScanner.swift` · `TypeInfoScanner`、`TypeInfoRecord`、`TypeInfoReference`（internal） | 新增 | 扫描槽位找 typeinfo、解析 si / vmi 的基类、读名字串并清 bit 63 | 方案第 3、4 条 | 2 |
| `Sources/CPlusPlusSymbols/CPlusPlusClass.swift` · `CPlusPlusClass`、`Base`、`Base.Location`、`InheritanceShape` | 新增 | 公开的类值类型 | 查询结果 | 2 |
| `Sources/CPlusPlusSymbols/CPlusPlusClassIndexStore.swift` · `CPlusPlusClassIndexStore`、`Storage`、`ClassHandle`、`ClassResolver`、`LocatorCache` | 新增 | `.shared`；`classes(in:)`、`class(named:in:)`、`class(atTypeInfoOffset:in:)`、`derivedClasses(of:in:)`、`virtualTables(of:in:)` 与带 `dependencySearchPaths:` 的重载、`prepare`、`contains`、`remove`；`Storage` 建索引，`ClassResolver` 在查询时跨镜像取基类与槽位，`LocatorCache` 按「镜像 + 搜索路径」缓存定位器 | 方案第 1 条 | 2、3、4 |
| `Sources/CPlusPlusSymbols/SharedCacheEvictionGroup+CPlusPlusSymbols.swift` | 修改 | 加 `.cPlusPlusClassStore` | 与作用域树分开驱逐 | 2 |
| `Sources/CPlusPlusSymbols/RuntimeTypeInformation/VirtualTableScanner.swift` · `VirtualTableScanner`、`VirtualTableRecord`、`VirtualSlotRecord`（internal） | 新增 | 认 RTTI 格、读 offset-to-top 与槽位、分组、取 `__ZTV` 所在组 | 方案第 5、6 条 | 3 |
| `Sources/CPlusPlusSymbols/CPlusPlusVirtualTable.swift` · `CPlusPlusVirtualTable`、`CPlusPlusVirtualFunction`、`Implementation`、`BaseFunction` | 新增 | 公开的表与槽位值类型 | 查询结果 | 3 |
| `Sources/CPlusPlusSymbols/RuntimeTypeInformation/VirtualFunctionNaming.swift` · `VirtualFunctionNaming`（internal） | 新增 | 槽位自己的名字、沿主基类链取基类函数、判断覆盖或继承；取名与取基类的两个函数由调用方注入，单元测试可替换 | 方案第 8 条 | 3、4 |
| `Sources/CPlusPlusSymbols/RuntimeTypeInformation/BaseClassLocator.swift` · `BaseClassLocator`（internal） | 新增 | 进程内按地址找镜像；cache 用 `CacheImageLocator`；独立文件用 `FileDependencyLocator`，跟随导出表的 re-export 与 `LC_REEXPORT_DYLIB`；按「根镜像 + 搜索路径」缓存定位器 | 方案第 9、10 条 | 4 |
| `Tests/CPlusPlusSymbolsFixture/Fixture.cpp` | 修改 | 新命名空间 `hierarchy`：多重继承（`Left`、`Right`、`Both`）、纯虚（`Shape`、`Square`）、`= delete` 的虚函数（`Retired`）、派生自 `std::exception` 的 `Failure`、默认可见性又没有 key function 的 `InlineOnly`（非唯一 RTTI）、匿名命名空间里的类；经基类指针调用，防止去虚化后丢掉 vtable | 进程内与测试包文件两种读法的确定输入 | 1、2、3 |
| `Tests/CPlusPlusSymbolsTests/ClassIndexTestImages.swift` · `ClassIndexTestImages`、`ClassHierarchyLibraries` | 新增 | 夹具镜像的两种读取器、取宿主架构的切片；测试运行时用 `xcrun clang++` 现编两个小 dylib：`Base` 导出类，`Derived` 经 `@rpath` 链接它、hidden 的覆盖被 `strip -x` 剥掉名字，另一份 `Derived` 用 `-Wl,-no_fixup_chains` 走旧式 opcode | 覆盖链式 fixup、opcode、剥离后的无名槽位与跨 `@rpath` 镜像，这些测试包本身给不出 | 1、4 |
| `Tests/CPlusPlusSymbolsTests/ImagePointerSlotsTests.swift` | 新增 | 夹具镜像的文件与进程逐槽一致；JavaScriptCore 的 cache 文件与进程逐槽一致（只比进程里确是指针的字）；libc++abi 的 `std::exception` 在 cache 文件与进程里给出同一张表；bind 给出符号名与来源库；offset-to-top 不是指针 | 第 1 步行为 | 1 |
| `Tests/CPlusPlusSymbolsTests/CPlusPlusClassIndexStoreTests.swift` | 新增 | 夹具上的类、基类、表、槽位、各查询；每个测试对进程内镜像与测试包文件各跑一遍 | 第 2、3 步行为 | 2、3 |
| `Tests/CPlusPlusSymbolsTests/CPlusPlusVirtualFunctionNamingTests.swift` | 新增 | 补名规则在编造的类上的单元测试，加上现编 dylib 的跨镜像补名、opcode 与链式两种文件结果一致 | 第 3、4 步行为 | 3、4 |
| `Tests/CPlusPlusSymbolsTests/CPlusPlusClassIndexCensusTests.swift` | 新增 | Espresso（进程内与 cache 文件）与 TSTables（目录不在时跳过，可用 `CPLUSPLUS_CLASS_CENSUS_FRAMEWORKS` 指定）的数量与耗时，以及「有 `__ZTV` 符号的表组，扫描出的末尾不越过下一个符号」 | 记录规模、核对表长规则 | 5 |
| `Documentations/Internal/CPlusPlusClasses.md` | 新增 | 实现说明：三条读指针的路、发现与表长规则、分组与副表归属、补名规则、跨镜像定位、已知局限、普查数字 | 实现说明随代码 | 6 |
| `Documentations/Internal/CPlusPlusSymbols.md` | 修改 | 「契约与坑」里「以后读 RTTI」一句改成指向新文档；说明作用域树仍只看符号 | 两份文档互相指路 | 6 |
| `README.md` | 修改 | `CPlusPlusSymbols` 的说明与示例加上类、vtable 与补名 | 对外说明 | 6 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案（写提案时已登记）与实现说明 | 索引 | 6 |

## 架构图

改了什么：

```text
MachOKitExtensions (package)
  MachOReading              InProcessContext.addressMask                (unchanged)
  MachOAddressResolution    CacheImageLocator, ImageAddressSpace (SPI)   (unchanged)
  MachODependencies         FileDependencyLocator, DependencySearchPath (unchanged)
  CPlusPlusDemangling       ItaniumDemangle behind a C API              (unchanged)
  CPlusPlusSymbols  (product)
  ~   dependencies          + MachOAddressResolution (SPI), + MachODependencies, + MachOReading
      CPlusPlusSymbolName                                                (unchanged)
      CPlusPlusScope, CPlusPlusSymbol, CPlusPlusSymbolIndexStore         (unchanged: scope tree from symbols only)
  +   CPlusPlusClass                class with RTTI: name, bases (maybe in other images)
  +   CPlusPlusVirtualTable         primary / secondary table, offset-to-top, functions
  +   CPlusPlusVirtualFunction      slot: implementation, own name, base function
  +   CPlusPlusClassIndexStore (.shared, eviction group .cPlusPlusClassStore)
  +   RuntimeTypeInformation/       (internal)
  +     ImagePointerSlots           file (chained / opcode) | dyld cache | in-process
  +     TypeInfoScanner             typeinfo objects, names, bases
  +     VirtualTableScanner         RTTI slots, groups, secondary-table owners
  +     VirtualFunctionNaming       own name, base function through the primary chain
  +     BaseClassLocator            other images: process | same cache | dependency search paths
```

建索引与查询的流程：

```text
CPlusPlusClassIndexStore.shared.virtualTables(of: cellID, in: tablesFile, dependencySearchPaths: [...])
 ├─ storage(in: tablesFile)                                  built once per image, cached
 │   ├─ ImagePointerSlots(tablesFile)                        walk fixup chains once -> offset: content
 │   ├─ TypeInfoScanner                                      slots == __cxxabiv1 vtable + 16  ∪  __ZTI symbols
 │   │   └─ name: (pointer & ~bit63) -> "__ZTS" + name -> CPlusPlusDemangler -> scope path
 │   ├─ VirtualTableScanner                                  slot -> typeinfo, previous word = offset-to-top
 │   │   └─ slots until a non-function word; group; owner of each secondary table
 │   └─ ImagePointerSlots dropped                            index keeps classes and tables only
 └─ VirtualFunctionNaming (per query)
     ├─ own name: C++ symbol at the implementation | bound symbol | symbol in the other image
     └─ base function: primary base's table, same slot, recursively
         └─ base in another image -> BaseClassLocator
             ├─ in-process: image containing the address
             ├─ dyld cache: CacheImageLocator.image(containing:)
             └─ file: FileDependencyLocator.locate(loadName:) -> follow re-exports
                 └─ CPlusPlusClassIndexStore.shared.class(atTypeInfoOffset:in: thatImage)
```

## 详细设计

### 公开类型

```swift
/// A C++ class an image carries run-time type information for: its name and
/// its direct bases, read from its `std::type_info` object, so a class whose
/// symbols are stripped is found too.
///
/// ```swift
/// let store = CPlusPlusClassIndexStore.shared
/// for polymorphicClass in store.classes(in: machO) where !polymorphicClass.hasTypeInfoSymbol {
///     print(polymorphicClass.qualifiedName, polymorphicClass.bases.map(\.qualifiedName))
/// }
/// ```
public struct CPlusPlusClass: Hashable, Sendable, CustomStringConvertible {
    /// `TST::CellID`, printed as ``CPlusPlusScope/qualifiedName`` prints a
    /// scope, so `CPlusPlusSymbolIndexStore.shared.scope(named:in:)` finds the
    /// scope holding the class's other symbols.
    public let qualifiedName: String
    /// The components of ``qualifiedName``, outermost first.
    public let scopePath: [String]
    /// The last component without template arguments.
    public let baseName: String
    /// The type's mangling as its typeinfo names it: `N3TST6CellIDE`.
    public let mangledTypeName: String
    /// Where the typeinfo object sits, as an offset in the image.
    public let typeInfoOffset: Int
    /// The direct bases, in declaration order.
    public let bases: [Base]
    /// What the typeinfo records about repeated and diamond-shaped bases.
    public let inheritanceShape: InheritanceShape
    /// Whether the image has a vtable for the class; `false` for a class only
    /// `typeid` or a `catch` clause needs.
    public let hasVirtualTable: Bool
    /// Whether a `__ZTI…` symbol names the typeinfo; `false` for a class only
    /// its run-time type information shows.
    public let hasTypeInfoSymbol: Bool
    /// `false` when the typeinfo is not unique program-wide and is compared by
    /// name — on Apple arm64, a type with default visibility and no key
    /// function, of which every image keeps a hidden copy.
    public let hasUniqueTypeInfo: Bool

    public var description: String { qualifiedName }
}

extension CPlusPlusClass {
    public struct Base: Hashable, Sendable {
        public let qualifiedName: String
        public let mangledTypeName: String
        public let isVirtual: Bool
        public let isPublic: Bool
        /// For a non-virtual base, where its subobject sits in the class. For
        /// a virtual base, where the vtable stores the subobject's offset,
        /// relative to the address point (negative).
        public let offset: Int
        public let location: Location
    }

    /// Where a base's typeinfo is defined.
    public enum Location: Hashable, Sendable {
        case sameImage(typeInfoOffset: Int)
        /// `installName` is the library a file binds the typeinfo from; `nil`
        /// for an image read from a dyld shared cache or the process.
        case otherImage(installName: String?)
    }

    public struct InheritanceShape: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32)
        /// Two or more distinct base subobjects of the same type.
        public static let repeatedBase: InheritanceShape
        /// A base subobject reached along two or more paths.
        public static let diamond: InheritanceShape
    }
}

/// One vtable of a class: the primary table, or a secondary table that a
/// base subobject's virtual pointer points at.
public struct CPlusPlusVirtualTable: Hashable, Sendable {
    /// The offset of the slot a virtual pointer points at: the first
    /// function.
    public let addressPointOffset: Int
    /// `0` for the primary table; minus the subobject's offset otherwise.
    public let offsetToTop: Int
    /// The base whose subobject uses the table; `nil` for the primary table,
    /// and for a secondary table no base explains.
    public let subobjectClassName: String?
    public let functions: [CPlusPlusVirtualFunction]

    public var isPrimary: Bool { offsetToTop == 0 }
}

/// A slot of a vtable and what it reaches.
public struct CPlusPlusVirtualFunction: Hashable, Sendable {
    /// The slot's position after the address point, from 0.
    public let slotIndex: Int
    public let implementation: Implementation
    /// The implementation's own name: the C++ symbol at it, or the symbol a
    /// file binds it to. `nil` when stripped.
    public let symbolName: CPlusPlusSymbolName?
    /// The base class function the slot overrides or inherits; `nil` for a
    /// function the class introduces, or when the base cannot be read.
    public let baseFunction: BaseFunction?

    /// ``symbolName``, else the name of ``baseFunction``.
    public var name: CPlusPlusSymbolName? { symbolName ?? baseFunction?.name }
}

extension CPlusPlusVirtualFunction {
    /// What a slot holds. The set is the Itanium ABI's: a function, or one of
    /// the two markers libc++abi provides.
    public enum Implementation: Hashable, Sendable {
        /// A function in this image.
        case function(offset: Int)
        /// A function a file binds from another library.
        case imported(symbolName: String, installName: String?)
        /// A function in another image of a dyld shared cache (an unslid
        /// address) or of the process.
        case otherImage(address: UInt64)
        /// `__cxa_pure_virtual`.
        case pureVirtual
        /// `__cxa_deleted_virtual`.
        case deletedVirtual
    }

    public struct BaseFunction: Hashable, Sendable {
        /// The nearest base whose table names the slot.
        public let className: String
        public let name: CPlusPlusSymbolName?
        /// Whether the class keeps the base's implementation instead of
        /// overriding it.
        public let isInherited: Bool
    }
}
```

### Store

```swift
public final class CPlusPlusClassIndexStore: Sendable {
    public static let shared: CPlusPlusClassIndexStore

    /// Every class with a typeinfo in the image, ascending by qualified name.
    public func classes(in machO: some MachORepresentableWithCache) -> [CPlusPlusClass]

    /// The class named `qualifiedName`; the one with the lowest typeinfo
    /// offset when hidden classes of several translation units share it.
    public func `class`(named qualifiedName: String, in machO: some MachORepresentableWithCache) -> CPlusPlusClass?

    public func `class`(atTypeInfoOffset offset: Int, in machO: some MachORepresentableWithCache) -> CPlusPlusClass?

    /// The classes of the image whose direct bases include `baseClass`.
    public func derivedClasses(of baseClass: CPlusPlusClass, in machO: some MachORepresentableWithCache) -> [CPlusPlusClass]

    /// The class's vtables, primary first, each slot named. Bases in other
    /// images are read from the process for an image of the process, from the
    /// same cache for an image of a dyld shared cache, and for a file from
    /// the paths inferred from where it sits plus this Mac's dyld shared cache.
    public func virtualTables(of polymorphicClass: CPlusPlusClass, in machO: some MachORepresentableWithCache) -> [CPlusPlusVirtualTable]

    /// The class's vtables, reading bases of other images through
    /// `dependencySearchPaths` — the way to reach `@rpath` siblings.
    public func virtualTables(of polymorphicClass: CPlusPlusClass, in machO: MachOFile, dependencySearchPaths: [DependencySearchPath]) -> [CPlusPlusVirtualTable]

    public func prepare(in machO: some MachORepresentableWithCache)
    public func contains(in machO: some MachORepresentableWithCache) -> Bool
    public func remove(for machO: some MachORepresentableWithCache)
}
```

三个调用点：

```swift
// Simplest: the classes of an image, including the ones without symbols.
let store = CPlusPlusClassIndexStore.shared
let hiddenClasses = store.classes(in: machO).filter { !$0.hasTypeInfoSymbol }

// Most common: the virtual functions of a class, named through its bases.
if let cellID = store.class(named: "TST::CellID", in: machO) {
    for function in store.virtualTables(of: cellID, in: machO).first?.functions ?? [] {
        print(function.slotIndex, function.name?.demangledName ?? "?", function.baseFunction?.isInherited == false)
    }
}

// Most involved: a standalone file whose bases sit in an @rpath sibling.
let tables = store.virtualTables(
    of: cellID,
    in: tablesFile,
    dependencySearchPaths: [.machOFile(path: persistencePath), .systemDyldSharedCache]
)
```

方法名 `class(named:in:)` 声明时要加反引号，调用点按 SE-0071 不用（`store.class(named:in:)`）。先例：`CPlusPlusSymbolIndexStore.scope(named:in:)`、`symbol(named:in:)`。

### 索引的常驻内容（`Storage`）

- 每个类一条记录：`CPlusPlusClass` 值（基类名已解析好）、vtable 组（`[VirtualTableRecord]`，每张表的 address point 偏移、offset-to-top、所属子对象的类名、槽位数组）、派生类的下标列表。
- 槽位记录 `VirtualSlotRecord`：`.function(offset)`、`.imported(symbolName, installName)`、`.otherImage(address)`、`.pureVirtual`、`.deletedVirtual`。不存名字：名字在查询时取（本镜像的 C++ 名字经 `CPlusPlusSymbolIndexStore` 的 `symbols(for:in:)`，第一次查询会建那棵作用域树）。
- 限定名 → 类下标，typeinfo 偏移 → 类下标。
- 外部基类的定位结果不进这里：它随搜索路径变化，由 `BaseClassLocator` 按「根镜像身份 + 搜索路径」缓存。
- `ImagePointerSlots` 建完即丢。TSTables 估计：611 个类、12,518 个槽位，常驻在几百 KB 量级（推测，普查测试实测）。

### 发现与解析的细节

- **扫描哪些节**：名字以 `__DATA` 或 `__AUTH` 开头的段（含 `__DATA_CONST`、`__DATA_DIRTY`、`__AUTH_CONST`）里的普通节，跳过 zerofill 节与 `__got`、`__auth_got`、`__la_symbol_ptr`、`__nl_symbol_ptr`、`__objc_*`、`__cfstring`、`__mod_init_func`、`__thread_*`。
- **三个 `__cxxabiv1` vtable 的标识**：
  - 独立文件：bind 的符号名为 `__ZTVN10__cxxabiv117__class_type_infoE`、`__ZTVN10__cxxabiv120__si_class_type_infoE`、`__ZTVN10__cxxabiv121__vmi_class_type_infoE`，addend 为 16。
  - cache：在同一个 cache 里找 `/usr/lib/libc++abi.dylib`，从导出表取三个地址加 16。
  - 进程内：`dlsym` 取三个地址加 16，去签名。
  - 镜像本身导出这三个符号（它就是 libc++abi）时，比较的是指向自己的 rebase 目标。
- **typeinfo 对象的范围**：class 16 字节、si 24 字节、vmi `24 + 16 × __base_count` 字节（`__base_count` 超过 1,024 视为不是 typeinfo，防坏数据）。范围内的槽位不当作 RTTI 格。
- **名字**：名字指针清 bit 63 后读 C 字符串；独立文件的目标是 rebase 偏移，cache 与进程内按地址读。拼上 `__ZTS` 交给 `CPlusPlusDemangler`，种类是 `typeInfoName` 时取作用域路径；解析不了的类仍收录，`qualifiedName` 用原样的修饰名，并在实现说明里记录。
- **槽位是不是函数**：本镜像的目标落在可执行节里（`S_ATTR_PURE_INSTRUCTIONS` 或 `S_ATTR_SOME_INSTRUCTIONS`）；bind 的符号名不以 `__ZTV`、`__ZTI`、`__ZTS`、`_OBJC_` 开头；cache 与进程内指向别的镜像时，目标落在那个镜像的可执行段里。
- **槽位的名字**：本镜像的实现取 `CPlusPlusSymbolIndexStore.shared.symbols(for: offset, in: machO)` 的第一个；没有 C++ 名字（剥离后留下的 `<redacted function N>` 不是 C++ 名字）就当无名。bind 的名字用 `CPlusPlusSymbolName(mangledName:)` 解析。另一个镜像的实现，在那个镜像上同样查。
- **主基类**：第一个偏移为 0、非虚、带 vtable 的直接基类；没有就没有主基类（Itanium 规则里「几乎为空的虚基类」也能当主基类，本提案不处理，实现说明记为局限）。递归深度上限 64，防坏数据成环。
- **是否原样继承**：两边的实现都在同一个镜像时比偏移；派生类的槽位是导入时比符号名；一边在派生类镜像、另一边在别的镜像时是覆盖。
- **线程安全**：`Storage` 建成后不可变；`BaseClassLocator` 的定位器缓存用 `NSLock`（本包最低 macOS 10.15）。

## 替代方案考量

- **只用 `__ZTI` / `__ZTV` 符号找类和表**：实现最简单，但 TSTables 的 611 个类里有 167 个没有符号，恰好是最需要恢复的那部分。否决。
- **逐槽调用 `SlotResolver` 或 `resolveBind(fileOffset:)`**：现成，但底下 MachOKit 的 `resolveBind(at:)` 每次都把所有链式指针列一遍，十几万个槽位是平方级；带记忆的版本还会把每个槽都记进字典常驻。否决，改为遍历链一次。
- **把 RTTI 并进 0005 的作用域树**：浏览时一棵树就有全部类，但建树要多读数据段，两份索引的失效与内存绑在一起，作用域的种类也会随读不读 RTTI 而变。本提案先分开，调用方按限定名关联；需要时另写提案。
- **槽位名只看本镜像，不跨镜像**：范围小、测试少，但 TSTables 有 434 个类的基类在 TSPersistence 里，补名的大头要跨镜像。用户选择跨镜像补名。
- **字段一起做（合并 ObjC ivar 编码，或 protobuf 描述符）**：ObjC 编码只能在依赖本包的下游合并，且与 RTTI 类几乎不重叠；protobuf 能补 434 个类的全部字段，但它是另一套格式。用户选择本提案不做字段，protobuf 另写提案排在之后。
- **测试只用测试包自己的二进制**：不用往仓库里放二进制，但测试包没有剥离的符号、也不经 `@rpath` 链接另一个 C++ 镜像，给不出「无名槽位靠跨镜像基类补名」的确定输入。改为放几个预编译的小 dylib，源码与重建脚本一起入库。

## 影响

### 源码兼容性（source compatibility）

纯新增。`CPlusPlusSymbols` 现有的类型与行为不变，作用域树的内容不变。新增依赖 `MachOAddressResolution`、`MachODependencies`、`MachOReading` 都是本包已有的模块，使用方不需要改清单。

### ABI 兼容性（条件项）

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

- 本仓库：`CPlusPlusSymbols` 多了三个模块依赖，构建 `CPlusPlusSymbols` 会顺带编译它们（`MachOFoundation` 的使用方本来就编译这些）。
- RuntimeViewer、MachOKitUI、swift-section：不受影响；要显示 C++ 类层级或虚函数时各自写提案采用。
- 之后的 protobuf 提案会依赖本提案的 `CPlusPlusClass`（按限定名把消息挂到类上）。

### 文档与示例

README 的 `CPlusPlusSymbols` 一节加上类与 vtable 的示例；新增实现说明 `Internal/CPlusPlusClasses.md`；`Internal/CPlusPlusSymbols.md` 加指路。

## API 演进与废弃策略

- 没有被替代的旧 API。
- `CPlusPlusVirtualFunction.Implementation` 与 `CPlusPlusClass.Location` 用 enum：前者的取值由 Itanium ABI 定死（函数或 libc++abi 的两个标记），后者只有「本镜像 / 别的镜像」。以后若要加情况，按破坏性改动处理。
- `InheritanceShape` 用 `OptionSet`，以后加标记不破坏调用方。
- 槽位的补名规则以后可能更聪明（例如处理虚基类当主基类），同一个槽位的 `baseFunction` 可能从 `nil` 变成有值；文档注释写明调用方不该把它当作永远不变。
- semver：3.1.0（minor）。

## 落地步骤

代码没有按下面的步骤逐步提交：本包在公司那台不编译，每次验证都要先推送功能分支、再到 Ultra 上跑，所以实现一次提交，之后是测试与几次修正。步骤与行为清单按实际做成的样子写。

1. **读指针的三条路**（完成）—— `Package.swift`、`IndexedImage.swift`、`ImagePointerSlots.swift`、`ImagePointerSlotsTests.swift`
   - 行为：`fileSlotsMatchTheProcessForEveryDataPointerOfTheFixtureImage`
   - 行为：`cacheSlotsMatchTheProcessForEveryDataPointerOfJavaScriptCore`
   - 行为：`libraryClassOfTheCacheReadsLikeTheProcess`
   - 行为：`aBindSlotNamesItsSymbolAndLibrary`
   - 行为：`aWordThatIsNoPointerHasNoContent`
2. **类与基类**（完成）—— `RuntimeLibraryMarkers.swift`、`TypeInfoScanner.swift`、`CPlusPlusClass.swift`、`CPlusPlusClassIndexStore.swift`（类的查询与 `prepare` / `contains` / `remove`）、驱逐组、夹具的 `hierarchy` 命名空间、`CPlusPlusClassIndexStoreTests.swift`
   - 行为：`everyFixtureClassWithATypeInfoIsFound`
   - 行为：`aClassWithoutSymbolsIsFoundThroughItsTypeInfo`（现编 dylib 里剥了 `__ZTI` 的类）
   - 行为：`aClassWithoutAKeyFunctionHasANonUniqueTypeInfoAndItsNameStillReads`
   - 行为：`singleInheritanceRecordsTheBaseAtOffsetZero`
   - 行为：`multipleInheritanceRecordsEveryBaseWithItsOffset`
   - 行为：`virtualInheritanceRecordsTheVirtualBaseOffsetSlot`
   - 行为：`aBaseInAnotherImageIsNamedAndLocatedThere`（`std::exception`）
   - 行为：`qualifiedNameFindsTheSameScopeInTheScopeTree`
   - 行为：`derivedClassesListTheDirectSubclassesInTheImage`
   - 行为：`processImageAndItsFileGiveTheSameClasses`
   - 行为：`prepareBuildsAndRemoveDrops`
3. **vtable 与补名规则**（完成）—— `VirtualTableScanner.swift`、`CPlusPlusVirtualTable.swift`、`VirtualFunctionNaming.swift`、store 的 `virtualTables(of:in:)`
   - 行为：`primaryTableListsSlotsInDeclarationOrder`（含虚析构函数占两格）
   - 行为：`secondaryTableBelongsToTheBaseAtItsOffset`
   - 行为：`secondaryTableSlotsAreThunksNamedAfterTheOverrider`
   - 行为：`theOwnTableIsPickedOverAConstructionTable`（同时覆盖几乎为空的虚基类当主基类）
   - 行为：`pureAndDeletedVirtualSlotsAreMarked`
   - 行为：`anOverrideIsNotInheritedAndAnUntouchedSlotIs`
   - 行为：`aSlotTheClassIntroducesHasNoBaseFunction`
   - 行为：`tableScanStopsAtTheNextObject`
   - 行为：`anUnnamedSlotTakesItsNameFromTheBase`、`aSlotKeepingTheBaseImplementationIsInherited`、`aSlotNoBaseNamesKeepsTheNearestBaseWithoutAName`、`aSlotPastTheBaseTableHasNoBaseFunction`、`anImportAndTheBaseFunctionWithTheSameNameAreTheSameImplementation`（编造的类上的单元测试）
4. **跨镜像补名**（完成）—— `BaseClassLocator.swift`、`ClassResolver`、带 `dependencySearchPaths:` 的重载、`ClassIndexTestImages.swift`、`CPlusPlusVirtualFunctionNamingTests.swift`
   - 行为：`strippedOverridesAreNamedFromTheBaseInTheRPathSibling`（现编 dylib）
   - 行为：`withoutTheSiblingTheBaseFunctionIsUnknown`
   - 行为：`chainedAndLegacyFixupFilesGiveTheSameTables`
   - 行为：`aStandaloneFileReachesABaseThroughAReexportingLibrary`（`std::exception` 经 libc++ 转出到 libc++abi）
   - 行为：`aBaseInAnotherImageNamesTheSlotsTheClassInherits`（进程内经已加载镜像、测试包文件经依赖搜索路径）
   - cache 镜像在同一个 cache 里跨镜像补名，由 Espresso 普查覆盖（见第 5 步）；「基类的基类也在别的镜像」没有单独的测试。
5. **普查**（JavaScriptCore 换成 Espresso；TSTables 未运行）—— `CPlusPlusClassIndexCensusTests.swift`
   - 行为：`classIndexCensusOfEspresso`（进程内与 cache 文件：类数、无符号类数、表数、槽位数、补名数、建索引与补名耗时；两种读法结果一致）
   - 行为：`scannedTableLengthsMatchSymbolBoundsInEspresso`
   - 行为：`classIndexCensusOfTSTables`（目录不在时跳过；期望 611 / 167 / 606，给 TSPersistence 后补回至少 2,163 个槽位名）
6. **文档**（完成）—— `Internal/CPlusPlusClasses.md`、`Internal/CPlusPlusSymbols.md`、`README.md`、两个索引
   - 收尾判断：实现说明必写（读指针的三条路、表长与分组规则、补名规则都是代码看不出的决策）；使用指南不写，API 的文档注释与 README 示例够用；术语表本包没有，`RTTI`、`vtable`、`address point`、`offset-to-top`、主基类在实现说明里第一次出现时解释。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-20 | Created as Draft | 用户要求给 C++ 加成员恢复：通过 RTTI 等手段还原类型与成员方法。先在 iWork 的 TSTables 上统计了能恢复多少（见前期调研）。 |
| 2026-11-20 | 范围：RTTI + vtable + 跨镜像补名 | 用户选择。否决：只读本镜像、不跨镜像补名（TSTables 434 个类的基类在 TSPersistence，补名的大头要跨镜像）。 |
| 2026-11-20 | 字段不在本提案 | 用户选择。RTTI 与 vtable 不带字段；ObjC ivar 编码只能在下游合并，且与 RTTI 类几乎不重叠（611 个里 4 个）。 |
| 2026-11-20 | protobuf 描述符另写提案，排在本提案之后 | 用户看了 proto-dump 后选择。实测 TSTables 内嵌 5 个 `.proto` 文件、434 个消息，与继承 `google::protobuf::Message` 的 434 个 RTTI 类一一对上。proto-dump 原样不能接进本包：不认 Mach-O，按代码看依赖不在同一输入时整次失败，并依赖 libprotobuf 与 abseil。 |
| 2026-11-20 | 放进现有 `CPlusPlusSymbols` 模块，新 store 与作用域树分开 | 两份索引的输入不同（符号表 / 数据段），分开后作用域树的成本与行为不变；按限定名关联。 |
| 2026-11-20 | 测试用预编译的小 dylib | 测试包给不出剥离后的无名槽位、`@rpath` 跨镜像基类与旧式 opcode，源码与重建脚本一起入库。 |
| 2026-11-20 | 状态 → Accepted | 用户批准，开始实现。集成分支用 `main`：本地的 `next` 只在公司那台、没推送，且落后 `main`。 |
| 2026-11-20 | 状态 → In Progress | 功能分支 `feature/cplusplus-class-hierarchy` 从 `main` 切出。本包在公司那台不编译，构建与测试都在 Ultra 上跑。 |
| 2026-11-20 | 测试改为运行时现编 dylib，不往仓库放二进制 | 照 `FixupResolutionMemoTests` 的先例，测试第一次需要时用 `xcrun clang++` 编出 `Base`、`Derived` 与走 opcode 的 `Derived`（`-Wl,-no_fixup_chains`），再 `strip -x`。`Package.swift` 因此不加 `resources`。否决：提案原定的预编译 dylib 入库（要维护二进制和重建脚本）。 |
| 2026-11-20 | 独立文件复用 `cached.fixupPointers` | 本包的 cached 视图已经有整文件的链式指针表（随 `MachOFile` 常驻、与别的使用方共享），不另建用完即丢的表。 |
| 2026-11-20 | `__ZTI` 符号只用来标 `hasTypeInfoSymbol` | typeinfo 的虚指针一定是 fixup，扫描不会漏，提案原想的「并入符号防漏」不需要。 |
| 2026-11-20 | cache 里的 libc++abi 按镜像清单的 install name 找 | `CacheImageLocator.exportedName(atAddress:in:among:)` 按第一次问的名字集合缓存整张表，后来换一组名字问会答错，所以不用它，自己查导出表。 |
| 2026-11-20 | 更正非唯一 RTTI 的条件 | 夹具测出 hidden 的类反而是唯一的。clang 的 `classifyRTTIUniqueness` 只给 linkonce_odr / weak_odr 且默认可见性的类型置 bit 63（没有 key function 的类、模板特化）。夹具改用默认可见性、只有内联虚函数的 `InlineOnly`，前期调研与 `hasUniqueTypeInfo` 的文档注释一并改正。 |
| 2026-11-20 | 几乎为空的虚基类当主基类 | 夹具的 `Intermediate : virtual VirtualBase` 只有一张表：`VirtualBase` 只有虚指针，按 Itanium 规则成了主基类、共用主表。提案原把这种情况列为不处理的局限，实现时补上：没有非虚主基类时，类自己主表里虚基类偏移为 0 的那个虚基类就是主基类。 |
| 2026-11-20 | 区分小整数与指针 | cache 的指针格式会把小整数解码成 cache 头部附近的地址，进程内的小整数也会被当成指针。进程内把 `[-2^31, 2^31)` 当整数；cache 里只把不大于 0 的小整数当整数——页内链末尾、目标在 cache 前 2 GB 的指针原样存成一个小正数，起初被当成整数，Espresso 因此少了 7 个类。 |
| 2026-11-20 | cache 文件的数据段指针一次解码 | 每节一次读出、一次定位所在的子 cache，之后的查询读解码结果。Espresso 建索引从 3.5 秒降到 2.5 秒（进程内 0.3 秒），仍有余地，记为后续项。 |
| 2026-11-20 | 独立文件定位基类时跳过 re-export 条目 | 导出表里标了 re-export 的条目不是定义，跳过后沿 `LC_REEXPORT_DYLIB` 继续找。 |
| 2026-11-20 | 普查改用 Espresso | WebKit 编译时关了 RTTI，JavaScriptCore 一个类都没有。Espresso 导出近 400 个 typeinfo，是 C++ 重度、带 RTTI 的系统框架。JavaScriptCore 留在逐槽对照测试里。 |
| 2026-11-20 | `Location.otherImage(installName:)` 对 cache 与进程内也给路径 | 提案原写这两种情况给 `nil`；实现时能拿到所在镜像的路径，就给了。 |
| 2026-11-20 | cache 里的数据地址按段范围找所在镜像 | `CacheImageLocator` 按 `__TEXT` 起点二分，只适合代码地址；cache 把各镜像的数据段集中放在后面，Espresso 普查里 libc++ 的 typeinfo 被归到了 `libobjcMsgSend11.dylib`，7 个类少补了 14 个槽位名。改为核对候选镜像的段范围，对不上再沿根镜像的依赖找。 |
| 2026-11-20 | 独立文件按导出表条目逐个跟随转出 | macOS 27 的 libc++ 没有 `LC_REEXPORT_DYLIB`，而是在导出表里逐个符号把 libc++abi 的符号标成 re-export，条目里带库序号与原名；按它跟过去。 |
| 2026-11-20 | 实现完成，待用户看过后收尾 | `CPlusPlusSymbolsTests` 79 个测试在 Ultra 上全部通过。Espresso 普查：4,379 个类（643 个没有 `__ZTI` 符号）、3,506 张表、56,204 个槽位，cache 文件与进程两种读法逐槽一致；3,008 组表没有一组越过下一个符号。cache 模式建索引 8.0 秒、取名 9.7 秒，进程内 0.29 秒、2.2 秒。后续项：cache 模式提速（推测瓶颈是逐指针解码，未采样确认）；TSTables 普查没有跑（Ultra 上没有 iWork 资料，公司那台不编译）；基类的基类在别的镜像缺单独测试。文档判断：写了实现说明 `Internal/CPlusPlusClasses.md`，不写使用指南，不建术语表。 |
