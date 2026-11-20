# Draft - `Sources/` 按层分组

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-20
- **最后更新**: 2026-11-20
- **所属愿景**: 无
- **关联提案**: MachOSwiftSection [0055-group-sources-by-layer](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0055-group-sources-by-layer.md)（同样的做法，本包照着对齐）；MachOSwiftSection `draft-shared-macho-testing-support`（同一条分支、同一次发版）
- **实现分支 / PR**: `feature/shared-macho-testing-support`，与测试支持统一同批，随 3.2.0 发布
- **配套文档**: README 的 Layout 一节（分组表与新 target 的放法）
- **网页版**: 同目录同名的 `.html`

## 摘要

16 个源码 target 从平铺的 `Sources/<Target>` 分进 7 个层级目录：`Core`、`Reading`、`Images`、`Symbols`、`Analysis`、`Umbrellas`、`TestSupport`。`Package.swift` 给每个 target 写明 `path: "Sources/<Group>/<Target>"`；product、模块名与公开 API 都不变，使用方不受影响。`Tests/` 仍然平铺。

## 动机

- **平铺看不出层次。** 2.0.0 迁入 MachOSwiftSection 的 Mach-O 层，3.x 又加了 C++ 与交叉引用的模块，`Sources/` 下已有 16 个目录，读取层、符号、分析、汇总模块与测试支持混在一起，新人得翻 `Package.swift` 的依赖才看得出谁在谁下面。
- **两个包对齐。** MachOSwiftSection 在 0055 已按层分组，规则写在它的 `AGENTS.md`；两个包按同一种方式组织，来回切换时不用换思路。

## 前期调研

- **依赖方向**（`Package.swift`）：`MachOKitExtensions` 在最底下；`MachOReading` → `MachOResolving` → `MachOPointers` 是读取层；`MachOCaches`、`MachODependencies` 只依赖 `MachOKit` 与 `MachOKitExtensions`，是按镜像的基础设施；`MachOSymbols`、`CPlusPlusDemangling`、`CPlusPlusSymbols` 是符号；`ARM64InstructionDecoding`、`MachOAddressResolution`、`MachOCodeReferences` 是交叉引用的分析层；`MachOBase`、`MachOFoundation` 只是汇总 import；`MachOFixtureSupport`、`MachOTestingSupport` 是测试支持。
- **按路径读源码的地方**：两个源码扫描测试从自己的 `#filePath` 爬到包根再拼 `Sources/<Target>`（`Tests/MachOCodeReferencesTests/SourceScanTests.swift:136`、`Tests/MachOReadingTests/ReaderKindCastScanTests.swift:70`）。源码里没有依赖目录深度的 `#filePath`。
- **别的仓库**：MachOSwiftSection 的 `TuistScript.sh` 扫上游包的源码时取清单里的 `path`，没有才退到 `Sources/<name>`（`:636`、`:667`），不受影响；MachOSwiftSection、MachOObjCSection、RuntimeViewer、MachOKitUI 都没有按路径引用本包的源码。
- **文档**：README、`Internal/CPlusPlusSymbols.md`、`Internal/CPlusPlusClasses.md`、`Internal/ReadingContextAbstraction.md` 里写着源码路径。旧提案（0002–0006）里的路径是当时的记录。

## 提议方案

1. 按依赖层分组：

   | 分组 | target |
   |---|---|
   | `Core` | `MachOKitExtensions` |
   | `Reading` | `MachOReading`、`MachOResolving`、`MachOPointers` |
   | `Images` | `MachOCaches`、`MachODependencies` |
   | `Symbols` | `MachOSymbols`、`CPlusPlusDemangling`、`CPlusPlusSymbols` |
   | `Analysis` | `ARM64InstructionDecoding`、`MachOAddressResolution`、`MachOCodeReferences` |
   | `Umbrellas` | `MachOBase`、`MachOFoundation` |
   | `TestSupport` | `MachOFixtureSupport`、`MachOTestingSupport` |

2. `Package.swift` 给每个 target 写 `path:`（在 `dependencies` 之后、`exclude` 之前）。SwiftPM 默认的 `Sources/<Target>` 从此不再适用：新 target 放进某个分组目录并写明路径。
3. 两个源码扫描测试改成拼 `Sources/<Group>/<Target>`。
4. 规则写进 README 的 Layout 一节（本包没有 agent 指令文件）。

### 非目标

- 改 target、product、模块名。
- 给 `Tests/` 分组：一个测试 target 一个目录，已经够清楚，与 MachOSwiftSection 一致。
- 改旧提案里的路径。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `Sources/<Target>/`（16 个目录） | 移动 | `git mv` 到 `Sources/<Group>/<Target>/` | 按层分组 | 1 |
| `Package.swift` | 修改 | 16 个 target 写明 `path:` | 路径不再是默认值 | 1 |
| `Tests/MachOCodeReferencesTests/SourceScanTests.swift`、`Tests/MachOReadingTests/ReaderKindCastScanTests.swift` | 修改 | 扫描的目录改成分组后的路径 | 它们按 `#filePath` 拼路径 | 2 |
| `README.md` | 修改 | 新增 Layout 一节；许可一节里 `CPlusPlusDemangling` 的路径 | 规则与路径 | 3 |
| `Documentations/Internal/CPlusPlusSymbols.md`、`CPlusPlusClasses.md`、`ReadingContextAbstraction.md` | 修改 | 源码路径 | 路径变了 | 3 |

## 架构图

```text
Sources/
  Core/          MachOKitExtensions
  Reading/       MachOReading, MachOResolving, MachOPointers
  Images/        MachOCaches, MachODependencies
  Symbols/       MachOSymbols, CPlusPlusDemangling, CPlusPlusSymbols
  Analysis/      ARM64InstructionDecoding, MachOAddressResolution, MachOCodeReferences
  Umbrellas/     MachOBase, MachOFoundation
  TestSupport/   MachOFixtureSupport, MachOTestingSupport
Tests/           (flat, one directory per test target)
```

## 详细设计

- **分组的依据是依赖方向**：每组只依赖排在它前面的组（`Analysis` 依赖 `Reading`，`Symbols` 依赖 `Images` 与 `Reading`），`Umbrellas` 只把前面几组汇成一个 import，`TestSupport` 只给测试用。
- **`Images` 放什么**：按镜像共享的缓存（`MachOCaches`）与镜像之间的依赖闭包（`MachODependencies`），两者都是「以镜像为单位」的基础设施，依赖相同。
- **源码扫描测试**：路径从 `#filePath` 爬三层到包根（测试文件 → 测试目录 → `Tests` → 包根），再进 `Sources/<Group>/<Target>`。两个测试都断言至少扫到若干文件，所以路径错了会直接失败，不会扫空了照样通过——这次移动时它们正是这样报出来的。

## 替代方案考量

- **`MachOCaches` 放进 `Core`，`MachODependencies` 单独成组 `Dependencies`**：`Core` 收下最底层的两块，但依赖闭包一个 target 自成一组。用户选择了 `Images` 的分法。
- **保持平铺**：不动最省事，但层次只能靠读清单，与 MachOSwiftSection 也不一致。

## 影响

### 源码兼容性（source compatibility）

无：product、模块名与公开 API 都不变。

### ABI 兼容性（条件项）

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

无。使用方按 product 依赖，不按路径；MachOSwiftSection 的 Tuist 开发 workspace 读清单里的 `path`。

### 文档与示例

README 新增 Layout 一节；实现说明里的源码路径同步更新。

## 落地步骤

1. **移动目录与清单**（完成）—— `Sources/`、`Package.swift`
   - 行为：全量 `swift test` 编译通过
2. **源码扫描测试的路径**（完成）—— `SourceScanTests`、`ReaderKindCastScanTests`
   - 行为：两个测试仍扫到全部源码文件并通过
3. **文档**（完成）—— README、三份实现说明
   - 收尾判断：不另写实现说明，规则写在 README 的 Layout 一节；没有新术语。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-20 | Created as Draft | 用户要求把 target 按层分组、不再平铺在 `Sources/` 根目录，照 MachOSwiftSection 0055 的做法。 |
| 2026-11-20 | 分组用 `Images` 收下 `MachOCaches` 与 `MachODependencies` | 用户选择。否决：`MachOCaches` 放进 `Core`、依赖闭包单独一组。 |
| 2026-11-20 | 与测试支持统一同一条分支、随 3.2.0 发布 | 用户选择。否决：单独分支、另行发版。 |
| 2026-11-20 | 状态 → Accepted → In Progress | 用户批准，开始实现。 |
| 2026-11-20 | 实现完成，待用户看过后收尾 | 移动后两个源码扫描测试按旧路径扫空、断言失败，改成分组后的路径后通过。Ultra 上（Xcode 27.2）全量 `swift test` 通过，原始退出码 0。文档：README 加 Layout 一节，三份实现说明的路径已改；不另写实现说明；没有新术语。 |
