# Documentations

| 文档 | 说明 |
|------|------|
| [Evolutions/README.md](Evolutions/README.md) | 提案索引与状态表 |
| [Evolutions/0001-cached-view.md](Evolutions/0001-cached-view.md) | 把 MachOKit fork 的三处性能改动移到 MachOKitExtensions 的 cached 视图 |
| [Evolutions/draft-move-reading-and-resolving-modules.md](Evolutions/draft-move-reading-and-resolving-modules.md) | 把 MachOSwiftSection 的 MachOReading / MachOResolving 原名迁入本包，本包发 2.0.0（实现中，未落地） |
| [Internal/ReadingContextAbstraction.md](Internal/ReadingContextAbstraction.md) | 实现说明：读取层（`ReadingContext`、`Resolvable`）两个模块各管什么、读文件为何直接用 MachOKit 的映射、本进程地址掩码、缓存范围、怎样看穿包装类型读取器 |
