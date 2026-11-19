# ARM64InstructionDecoding

分析要读的那几种 A64 编码的手写解码器（`ARM64InstructionWord`：`bl` / `b` 的目标、`adrp` / `add` / `adr` 算出的地址、`ldr` / `ldrsw` 的载入与字面量形式、`br` / `blr` 及其认证形式、`mov` / `movk`），以及链接器与 dyld cache 构建器生成的跳板形状（`ARM64Trampoline`：GOT 桩、ld64 改写的桩、stub island、cache 共用的 selector 桩）。没有依赖，不认识 Mach-O。

- 来历：MachOSwiftSection 提案 0072（交叉引用分析）在那边写成，0097 让 accessor thunk 读取与交叉引用共用；提案 [move-cross-reference-layers](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/draft-move-cross-reference-layers.md) 把它连同交叉引用核心一起搬来本包，名字不变（它与 Mach-O 无关，不加 `MachO` 前缀），随 2.0.0 发布。MachOSwiftSection 0.25.0 起不再有同名模块，0.24.0 及更早的版本要求本包 1.x，不会与 2.0.0 同时解析。
- 使用方：本包的 [MachOAddressResolution](MachOAddressResolution.md) 与 [MachOCodeReferences](MachOCodeReferences.md)；MachOSwiftSection 的 `CrossReferenceAnalysis`（Swift 层读元数据访问器的调用点）。
- 接口都是 `@_spi(Internals) public`，只给这些使用方用，不承诺稳定。
- 为什么是手写解码器而不是 Capstone：交叉引用要扫整个 cache，手写只认这几种编码，比 Capstone 快 25 到 50 倍；见 MachOSwiftSection 的 [Modules/CrossReferenceAnalysis.md](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Internal/Modules/CrossReferenceAnalysis.md)。
- 测试在 MachOSwiftSection：`ARM64InstructionDecodingTests` 与 `RegisterFileTests` 拿 Capstone 逐条对照，那边本来就依赖 Capstone，本包不为两组测试多一个大 C 库。
- 一条要记住的规则：GOT 桩的载入之后必须紧跟一条经同一寄存器的非调用跳转才算桩；开头是 `adrp; ldr` 的普通函数在前两条指令上和 GOT 桩一模一样（回归测试在 MachOSwiftSection 的 `ARM64TrampolineTests.aFunctionLoadingAGlobalIsNoSlotStub`）。
