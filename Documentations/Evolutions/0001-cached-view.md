# 0001 - 用 cached 视图承载 MachOKit fork 的性能改动

- **状态**: In Progress
- **创建日期**: 2026-09-29
- **最后更新**: 2026-09-29

## 摘要

MachOKit fork 在上游文件里有三处纯性能改动：`MachOFile` 的 chained fixups 缓存、`DyldCacheLoaded.current` 缓存、`ObjCHeaderOptimizationRO.headerInfo(at:in:)` 按下标直取。它们是功能而不是 bug，上游未必接受，却让每次合并上游都要处理我们对上游文件的改动。本提案把这三处改成 MachOKitExtensions 里的 cached 视图，只依赖 MachOKit 的 public API；下游切换后，MachOKit 把对应文件恢复成上游原样。必须改在 MachOKit 方法体里的三个 bug 修复（`CPU.current`、N_ABS、chained fixups 空段）留在 fork，另行向上游提 PR。

## 方案

- **接口**（语义与 MachOKit 同名方法一致）：
  - `MachOFile.cached: MachOCached<MachOFile>`，提供 `dyldChainedFixups`、`fixupPointers`、`fixupPointer(at:)`、`resolveRebase(at:)`、`resolveOptionalRebase(at:)`、`resolveBind(at:)`。
  - `DyldCacheLoaded.cachedCurrent`：进程内只构造一次的 `DyldCacheLoaded.current`。
  - `DyldCacheLoaded.cached: DyldCacheLoadedCached`，提供 `headerInfo(at:in:)`，对 `ObjCHeaderOptimizationROProtocol` 泛型，替代 fork 的 `headerInfo(at:in:)`。
- **缓存挂载**：`MachOFile` 是 class，用 `@AssociatedObject(.retain(.atomic))` 挂存储，首次创建由锁保护；存储不持有 `MachOFile`，避免循环引用。`DyldCacheLoaded` 是 struct，存储放在按 `ptr` 索引的全局表里；已加载的 shared cache 在进程内不会被卸载，所以不做淘汰。
- **并发**：沿用旧 `feature/cached-view` 分支的 `NSLock` + `CacheSlot` 做法，重计算在锁外进行，两个线程同时首算时先写入的结果胜出。
- **`resolveOptionalRebase` 的零值判断**：MachOKit 读槽位原始值用的 `fileHandle` 不是 public。改为检查解码后 rebase 内容的 `layout` 字节是否全零，它就是槽位的原始比特。
- **内部切换**：`resolveRebase(fileOffset:)`、`resolveBind(fileOffset:)`、`isBind(_:)` 走 `cached`；`MachOImage.cache` 改用 `DyldCacheLoaded.cachedCurrent`。MachOSwiftSection 经由这些接口，无需改动。
- **撞名的扩展移出本包**：`UnsafeRawPointer` / `UnsafePointer` 的公开抛错版 `init(bitPattern:)` 会遮住标准库的可失败版本，依赖本包的模块里凡是写 `UnsafeRawPointer(bitPattern:)!` 的地方都编译不过。它们移到唯一的使用方 MachOSwiftSection（`package` 访问级别），本包内部改用 internal 的 `init(nonZeroBitPattern:)`。这是破坏性改动，因此本次发 **1.0.0**：下游对 0.x 写的 `from:` 覆盖到 `1.0.0` 之前，旧版下游不会被悄悄升级到缺了这两个初始化方法的版本。
- **MachOObjCSection**：要改的调用都在它的核心 target 里，该 target 因此新增对 MachOKitExtensions 的依赖。`cachedCurrent` 在非 Darwin 平台返回 `nil`，与 MachOObjCSection 给 Linux 补的 `DyldCacheLoaded.current` 替身一致。MachOKitUI 只在构建导入列表时调一次 `DyldCacheLoaded.current`，不改。
- **测试**：新增 `MachOKitExtensionsTests` 测试 target（swift-testing）。以 MachOKit 的同名方法为参照，在 `/usr/bin/curl`（x86_64 与 arm64e 切片都用 chained fixups）和 Freeform 各切片上比对 rebase、bind 槽位及其后一字节的结果；另测并发首算和 `DyldCacheLoaded` 两个接口。
- **不在本次范围**：旧分支里的符号 memoize、按名字索引、`closestSymbol` 等算法拷贝（上游之后已重写，拷贝已过时）；`MachOImage` 的 cached 视图；失效（invalidate）接口；现有 `_resolveRebaseCache` 等 `.nonatomic` 缓存的线程安全问题。
- **落地顺序**：本仓库发版 → MachOSwiftSection 接手抛错版初始化方法、MachOObjCSection 改用新接口，各自发版 → MachOKit 删掉三处性能改动并发版。三个 bug 的上游 PR 并行准备，提交前由用户确认。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-29 | Created as Draft | 用户提出合并 MachOKit 的 `feature/cached-view`，以免继续改上游代码 |
| 2026-09-29 | 不合并旧分支，改为在 MachOKitExtensions 实现 cached 视图 | 旧分支仍需在 `MachOFile`/`MachOImage` 本体加存储属性，改动上游文件更多；其中抄写的上游算法已落后于上游 |
| 2026-09-29 | fixups 缓存只做 `MachOFile`，用关联对象挂载 | 用户指出 `MachOImage` 已被 dyld 修正过指针，不存在 fixups；`MachOFile` 是 class，可用关联对象 |
| 2026-09-29 | 性能改动进 cached 视图，bug 修复留在 MachOKit 并提交上游 | 用户判断：性能改动是功能，上游未必接受；bug 修复无法在外层包装，且是真实 bug |
| 2026-09-29 | Accepted → In Progress | 用户在对话中批准方案 |
| 2026-09-29 | 落地 `main` 时编号 0001 | 仓库此前没有提案 |
| 2026-09-29 | MachOObjCSection 核心 target 直接依赖 MachOKitExtensions，不把 cached 视图挪回 MachOKit | 用户决定：放回 MachOKit 时 ObjCSection 的调用点照样要改，不如直接依赖。ObjCSection 文档里「核心 target 依赖它会造成包级循环」的说法在 MachOKitExtensions 独立成包后已不成立 |
| 2026-09-29 | 抛错版 `init(bitPattern:)` 移到 MachOSwiftSection | MachOObjCSection 核心 target 依赖本包后，它们遮住了标准库的可失败版本（仅 `UnsafeRawPointer(bitPattern:)` 就有 27 处调用编译不过）。用户决定：只有 MachOSwiftSection 用到，挪过去。另外考虑过开启 `MemberImportVisibility`，但要给 17 个上游文件补 `import FileIO`，放弃 |
| 2026-09-29 | 版本号定为 1.0.0 而非 0.2.0 | SwiftPM 对 `from: "0.1.2"` 的解释是 `0.1.2..<1.0.0`，发 0.2.0 会让已发布的 MachOSwiftSection 在下次解析依赖时拿到它并编译失败 |
| 2026-09-29 | 测试样本用 `/usr/bin/curl` 而非 `/bin/ls` | `/bin/ls` 的 x86_64 切片仍用 `LC_DYLD_INFO_ONLY`，覆盖不到 x86_64 的 chained fixups 格式 |
| 2026-09-29 | 测试除对 fork 的 MachOKit 外，还对 `MachOFile.swift` 恢复成上游原样的 MachOKit 跑了一遍，全部一致 | fork 的缓存实现不能作为独立参照。注意样本里不一定有原始值为 0 的槽位，`layout` 字节判断与上游读文件判断的等价性只验证了非零一侧 |
