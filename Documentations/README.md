# Documentations

| 文档 | 说明 |
|------|------|
| [Evolutions/README.md](Evolutions/README.md) | 提案索引与状态表 |
| [Evolutions/0001-cached-view.md](Evolutions/0001-cached-view.md) | 把 MachOKit fork 的三处性能改动移到 MachOKitExtensions 的 cached 视图 |
| [Evolutions/draft-move-reading-and-resolving-modules.md](Evolutions/draft-move-reading-and-resolving-modules.md) | 把 MachOSwiftSection 的 MachOReading / MachOResolving 原名迁入本包，本包发 2.0.0（已批准，未落地） |
| [Evolutions/draft-move-macho-infrastructure-modules.md](Evolutions/draft-move-macho-infrastructure-modules.md) | 把 MachOSwiftSection 剩余的 MachO 基础模块迁入本包，`MachOSymbols` 拆出只收 C/C++/ObjC 名字的符号索引，随 2.0.0 落地（已批准，未落地） |
