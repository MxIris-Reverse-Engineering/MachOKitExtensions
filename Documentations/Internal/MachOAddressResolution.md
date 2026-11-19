# MachOAddressResolution

从 Mach-O 文件里离线读出「一次调用最终落到哪」所需的几样东西：一个镜像的地址空间（`ImageAddressSpace`）、调用途经的跳板链（`StubChainResolver`）、任意指针槽里装着谁（`SlotResolver`），以及 dyld shared cache 里某个地址属于哪个镜像（`CacheImageLocator`）。不认识 Swift、ObjC 的任何元数据。

- 来历：MachOSwiftSection 提案 0097 把它从那边的 `SwiftThunkAnalysis` 抽成 `CodeAddressResolution`，accessor thunk 读取与交叉引用的文件模式共用；提案 [move-cross-reference-layers](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/draft-move-cross-reference-layers.md) 把它搬来本包，改名 `MachOAddressResolution`，随 2.0.0 发布。
- 依赖：MachOKit、`MachOKitExtensions`、`MachOReading`（`MachOFile.readElements`）、[ARM64InstructionDecoding](ARM64InstructionDecoding.md)（跳板形状）。
- 使用方：本包的 [MachOCodeReferences](MachOCodeReferences.md)（文件模式）；MachOSwiftSection 的 `SwiftThunkAnalysis`（`MachOThunkEnvironment` 经它读槽、读桩、找 cache 镜像）与 `SwiftDeclarationRendering`（导出表偏移换地址）。
- 接口都是 `@_spi(Internals) public`，只给这些使用方用，不承诺稳定。

## 四个类型

| 类型 | 做什么 |
|---|---|
| `ImageAddressSpace` | MachOSwiftSection 口径的 offset 与虚拟地址互换；段范围判断「在不在本镜像」；符号表的 `n_value`、导出表的相对 mach header 偏移各自换成地址 |
| `CacheImageLocator` | cache 里按地址找镜像（按 `imageInfos` 的加载地址二分），按路径懒打开并保留；镜像导出表里某个地址是哪个名字 |
| `StubChainResolver` | 读一个地址上的跳板（GOT 桩、ld64 改写的桩、stub island、27 的 cache 共用 selector 桩），给出这一跳（`Hop`）；或者从一个地址起一路跟到终点，记下每一跳 |
| `SlotResolver` | 任意指针槽里装着谁：bind 给符号名，rebase 给未滑动的目标地址。GOT、auth GOT、ObjC 的各类引用槽、ivar 偏移变量共用，哪个节算哪种槽由调用方说 |

## 关键契约

- **地址的口径**：cache 镜像的 offset 是「未滑动虚拟地址减 `sharedRegionStart`」，不是文件偏移；另外三种口径看着能用却会算出邻居镜像里的地址。来龙去脉写在 `ImageAddressSpace` 的文档注释里。cache 镜像的 offset 换算对整个 cache 都答得出，「在不在本镜像」只能用 `containsAddress(_:)` 的段范围判断。
- **导出表的偏移相对 mach header**：一律经 `address(forExportedSymbolOffset:)` 换算，dylib、可执行文件、cache 镜像通用。
- **槽先看 bind 再看 rebase**：独立文件的导入是 bind，给的是名字；`MachOKitExtensions.resolveRebase(fileOffset:)` 对 cache 镜像答的是「目标减 `sharedRegionStart`」、对独立文件答的是链式 fixup 存的「相对首选加载地址的偏移」，`SlotResolver` 统一换成未滑动地址（独立文件按 `__TEXT` 加偏移，`ImageAddressSpace.address(forHeaderOffset:)`）。可执行文件的 `__TEXT` 在 0x100000000，把偏移直接当地址用会解错 4 GiB（MachOSwiftSection 0097 修过一次，回归测试在那边的 `FileModeTests`）。没有链式 fixup、靠 opcode rebase 的旧文件，`SlotResolver` 答不出。独立文件里绑到自己导出符号的 bind（self-bind）在这里只是名字，换成地址是交叉引用文件模式的事。
- **跳板按形状认，载入之后必须紧跟经同一寄存器的跳转**：开头是 `adrp; ldr` 的普通函数（读一个 Swift 字段偏移的 getter 就是）在前两条指令上和 GOT 桩一模一样，回归测试在 MachOSwiftSection 的 `ARM64TrampolineTests.aFunctionLoadingAGlobalIsNoSlotStub`。
- **链的长度有上限**：`StubChainResolver.maximumHops` 是 8（一般一跳，每跨一个 subcache 多一跳）。`hops(from:isDestination:followSlot:)` 的 `isDestination` 让调用方在已知的函数起点停下，`followSlot` 由调用方决定怎么解一个槽。cache 共用的 selector 桩是链的终点：它把 selector 字符串的地址放进 `x1`，`Hop.registerSettingStub` 记下寄存器号与常量；这个常量是 selector 由 ObjC 层解释，本模块不认识 selector。
- **自己不做按镜像缓存**：`CacheImageLocator` 内部用一把锁保护已打开镜像与导出名表；按镜像共用一个 locator 是调用方的事（MachOSwiftSection 的线程读取器把它放在 `thunkResolution` 组的 `SharedCache` 里，见 [SharedCache.md](SharedCache.md)），本模块因此不依赖 `MachOCaches`。

## 测试

`MachOAddressResolutionTests`（只在带 dyld shared cache 的 arm64 进程里跑，拿进程里 dyld 已经 rebase、bind 过的内容当标准答案）：

- `stubChainCarriesTheSelectorRegisterConstantOfACacheSharedSelectorStub`：AppKit 文件里经 cache 共用 selector 桩的调用，`x1` 的常量在文件里读出的 selector，与进程内存里同一地址（加上 cache 的 slide）上的字符串一致（核对 50 处）。搬来之前它对照的是 MachOSwiftSection 分析器在同一条指令上认出的发送。
- `stubChainRecordsEveryStubIslandHop`：iOS 26.3.1 设备 cache 的 SwiftUI，经 stub island 的调用一百条以上，每一跳都从上一跳的终点开始，链停在不是跳板、落在某个镜像里的地址上。卷上没有这个 cache 时跳过。
- `slotResolverMatchesTheProcessForEveryGlobalOffsetTableSlotOfAppKit`：AppKit 的每个 GOT 与 auth GOT 槽，文件里解出的目标等于进程里的指针去掉签名（`InProcessContext.addressMask`）、减去 slide；其中有指向 AppKit 自己的（类对象）。
- `cacheImageLocatorFindsTheImageAnAddressLiesIn`：AppKit 与 libobjc 的 `__TEXT` 里的地址找回各自的镜像。

要 MachOSwiftSection 的 SymbolTestsCore 夹具的 `slotResolverResolvesStandaloneBinds` 留在那边（`StandaloneBindSlotTests`）；accessor thunk 读取经本模块的结果由那边的 `SwiftThunkAnalysisTests` 全套守着。
