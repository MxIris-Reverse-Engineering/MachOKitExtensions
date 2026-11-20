# Documentations

| 文档 | 说明 |
|------|------|
| [Evolutions/README.md](Evolutions/README.md) | 提案索引与状态表 |
| [Evolutions/0001-cached-view.md](Evolutions/0001-cached-view.md) | 把 MachOKit fork 的三处性能改动移到 MachOKitExtensions 的 cached 视图 |
| [Evolutions/0002-move-reading-and-resolving-modules.md](Evolutions/0002-move-reading-and-resolving-modules.md) | 把 MachOSwiftSection 的 MachOReading / MachOResolving 原名迁入本包，本包发 2.0.0 |
| [Evolutions/0003-move-macho-infrastructure-modules.md](Evolutions/0003-move-macho-infrastructure-modules.md) | 把 MachOSwiftSection 剩余的 MachO 基础模块迁入本包，`MachOSymbols` 拆出只收 C/C++/ObjC 名字的符号索引，随 2.0.0 落地 |
| [Evolutions/0004-split-symbol-language.md](Evolutions/0004-split-symbol-language.md) | `SymbolLanguage` 只认 C 与 C++，Swift 与 Objective-C 由各自的包在加载时注册；C/C++ 索引排除已注册语言并留边界，随 3.0.0 落地 |
| [Evolutions/0005-cplusplus-symbol-classification.md](Evolutions/0005-cplusplus-symbol-classification.md) | 新模块 `CPlusPlusSymbols` 引入 LLVM `ItaniumDemangle`，把 C++ 名字拆成归类字段，并按证据把一个镜像的 C++ 符号整理成作用域树；与拆分同日随 3.0.0 落地 |
| [Evolutions/draft-cplusplus-class-hierarchy.md](Evolutions/draft-cplusplus-class-hierarchy.md) | 草案：从 RTTI 与 vtable 恢复 C++ 类（含符号被剥离的类）、继承关系与虚函数表，沿基类链（可跨镜像）给无名虚函数补名 |
| [Internal/ReadingContextAbstraction.md](Internal/ReadingContextAbstraction.md) | 实现说明：读取层（`ReadingContext`、`Resolvable`）两个模块各管什么、读文件为何直接用 MachOKit 的映射、本进程地址掩码、缓存范围、怎样看穿包装类型读取器 |
| [Internal/SymbolIndex.md](Internal/SymbolIndex.md) | 实现说明：符号表、按 routing 分表的采集、`SymbolLanguage` 与别的包在加载时注册语言、C/C++ 符号索引与已注册语言的边界；零拷贝名字何时可用、同名多处定义怎么登记 |
| [Internal/CPlusPlusSymbols.md](Internal/CPlusPlusSymbols.md) | 实现说明：引入的 LLVM `ItaniumDemangle` 与更新方法、C 接口与 AST 遍历、特殊名字归位、按证据定作用域种类、查询时重新解析；JavaScriptCore 上的规模与耗时 |
| [Internal/CPlusPlusClasses.md](Internal/CPlusPlusClasses.md) | 实现说明：从 RTTI 与 vtable 恢复 C++ 类——读指针的三条路、找 typeinfo 与 vtable、分组与副表归属、沿基类补名、跨镜像定位、已知局限与普查数字 |
| [Internal/SharedCache.md](Internal/SharedCache.md) | 实现说明：按镜像共享的缓存（`SharedCache`）、键与驱逐登记 |
| [Internal/DependencyResolution.md](Internal/DependencyResolution.md) | 实现说明：依赖闭包、搜索路径与定位器 |
| [Internal/MachOCodeReferences.md](Internal/MachOCodeReferences.md) | 实现说明：交叉引用与语言无关的核心层——镜像集、函数表、指令扫描、识别器扩展点；接口只开 `Internals` SPI 给 MachOSwiftSection 与 MachOObjCSection，进程内部分只在 Darwin 上有 |
| [Internal/MachOAddressResolution.md](Internal/MachOAddressResolution.md) | 实现说明：离线读出一次调用落到哪——地址空间、跳板链、指针槽、cache 镜像定位，以及地址口径与槽的解码契约 |
| [Internal/ARM64InstructionDecoding.md](Internal/ARM64InstructionDecoding.md) | 实现说明：分析要读的几种 A64 编码与跳板形状的手写解码器，为什么不用 Capstone、测试为什么留在 MachOSwiftSection |
