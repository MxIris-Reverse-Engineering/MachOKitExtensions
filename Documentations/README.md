# Documentations

| 文档 | 说明 |
|------|------|
| [Evolutions/README.md](Evolutions/README.md) | 提案索引与状态表 |
| [Evolutions/0001-cached-view.md](Evolutions/0001-cached-view.md) | 把 MachOKit fork 的三处性能改动移到 MachOKitExtensions 的 cached 视图 |
| [Evolutions/0002-move-reading-and-resolving-modules.md](Evolutions/0002-move-reading-and-resolving-modules.md) | 把 MachOSwiftSection 的 MachOReading / MachOResolving 原名迁入本包，本包发 2.0.0 |
| [Evolutions/0003-move-macho-infrastructure-modules.md](Evolutions/0003-move-macho-infrastructure-modules.md) | 把 MachOSwiftSection 剩余的 MachO 基础模块迁入本包，`MachOSymbols` 拆出只收 C/C++/ObjC 名字的符号索引，随 2.0.0 落地 |
| [Internal/ReadingContextAbstraction.md](Internal/ReadingContextAbstraction.md) | 实现说明：读取层（`ReadingContext`、`Resolvable`）两个模块各管什么、读文件为何直接用 MachOKit 的映射、本进程地址掩码、缓存范围、怎样看穿包装类型读取器 |
| [Internal/SymbolIndex.md](Internal/SymbolIndex.md) | 实现说明：符号表、按 routing 分表的采集、`SymbolLanguage` 与 C/C++ 符号索引；零拷贝名字何时可用、同名多处定义怎么登记 |
| [Internal/SharedCache.md](Internal/SharedCache.md) | 实现说明：按镜像共享的缓存（`SharedCache`）、键与驱逐登记 |
| [Internal/DependencyResolution.md](Internal/DependencyResolution.md) | 实现说明：依赖闭包、搜索路径与定位器 |
| [Internal/MachOCodeReferences.md](Internal/MachOCodeReferences.md) | 实现说明：交叉引用与语言无关的核心层——镜像集、函数表、指令扫描、识别器扩展点；接口只开 `Internals` SPI 给 MachOSwiftSection 与 MachOObjCSection，进程内部分只在 Darwin 上有 |
| [Internal/MachOAddressResolution.md](Internal/MachOAddressResolution.md) | 实现说明：离线读出一次调用落到哪——地址空间、跳板链、指针槽、cache 镜像定位，以及地址口径与槽的解码契约 |
| [Internal/ARM64InstructionDecoding.md](Internal/ARM64InstructionDecoding.md) | 实现说明：分析要读的几种 A64 编码与跳板形状的手写解码器，为什么不用 Capstone、测试为什么留在 MachOSwiftSection |
