# Evolutions

- **项目类型**: library

| # | 标题 | 状态 |
|---|------|------|
| 0001 | [用 cached 视图承载 MachOKit fork 的性能改动](0001-cached-view.md) | Implemented |
| cross-repository（MachOSwiftSection 0075） | [包装类型读取器的识别](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0075-wrapped-reader-recognition.md)：由 MachOSwiftSection 维护唯一提案；本库提供 `MachOReaderWrapper`、`underlyingReader`，`asMachOImage` 看穿包装，新增 `asMachOFile`（1.3.0） | Implemented |
| 0002 | [把 MachOReading 与 MachOResolving 迁入本包](0002-move-reading-and-resolving-modules.md) | Implemented |
| 0003 | [把 MachOSwiftSection 剩余的 MachO 基础模块迁入本包，并拆出 C/C++ 符号索引](0003-move-macho-infrastructure-modules.md) | Implemented |
| cross-repository（MachOSwiftSection 0098） | [交叉引用的核心层与 ObjC 层迁出 MachOSwiftSection](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0098-move-cross-reference-layers.md)：由 MachOSwiftSection 维护唯一提案；本包新增 `ARM64InstructionDecoding`、`MachOAddressResolution`、`MachOCodeReferences` 三个模块（层间接口是 `@_spi(Internals)`，只给 MachOSwiftSection 用），2.0.0 | Implemented |
