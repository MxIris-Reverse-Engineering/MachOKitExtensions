# 读取层：ReadingContext 与 Resolvable

> 提案：[把 MachOReading 与 MachOResolving 迁入本包](../Evolutions/draft-move-reading-and-resolving-modules.md)。这两个模块在 2.0.0 之前是 MachOSwiftSection 的 target，当时的演进记在它的提案里：0057 reading-context-migration（读取接口收成 `ReadingContext` 一份）、0075 wrapped-reader-recognition（看穿包装类型）、0088 machofile-performance（文件读取改用 MachOKit 的映射）。ABI 层与上层怎么用这一层，见 MachOSwiftSection 的 `Documentations/Internal/ReadingContextAbstraction.md`。

## 两个模块各管什么

- **MachOReading**：按偏移或地址读出类型化的值。
  - `Readable`：`MachOFile`、`MachOImage`、`UnsafeRawPointer` 都遵循，按偏移读元素、元素数组、带位置的 layout 包装（`LocatableLayoutWrapper`）与 C 字符串。
  - `ReadingContext`：把「读」与「地址怎么算」放在一起的协议。`MachOContext<MachO>` 以文件或镜像内的偏移为地址；`InProcessContext` 以本进程的指针为地址。另有三条带默认值的要求：`bindRebaseResolver`（谁能回答这个槽位是 bind 还是 rebase）、`runtimePointer(at:)`（能否给出本进程指针）、`cacheScope`（按什么范围缓存读出的结果）。
- **MachOResolving**：
  - `Resolvable`：按地址读出一个值。整数、浮点、`String`、`Optional` 与所有 `LocatableLayoutWrapper` 都有默认实现。
  - `SymbolOrElement`：槽位被 dyld 绑定到别的镜像时给出符号名（`Symbol`），否则读出元素。
  - `Symbol` / `Symbols`：符号的值类型。查找符号不在这里，由 MachOSwiftSection 的符号索引负责，`Symbols.init(offset:symbols:)` 因此是公开的。

依赖：MachOKit（至少 0.55.102，见下文「读文件」）、本包的 MachOKitExtensions 模块（`RuntimeProtocol`、`LocatableLayoutWrapper`、`MachOBindRebaseResolving`、`MachOTargetIdentifier`、`MachOReaderWrapper` 都在那里），以及 FileIO（越界读取抛它的 `FileIOError.offsetOutOfBounds`）。

## 设计来源

照 Swift runtime 的 `MemoryReader` 做：同一份读取逻辑，换一个「读取者」就能读文件，也能读本进程。

| Swift runtime（C++） | 这一层 |
|---|---|
| `MemoryReader` | `ReadingContext` |
| `InProcessMemoryReader` | `InProcessContext` |
| `CMemoryReader` | `MachOContext` |
| `RemoteAddress` | `Context.Address` |
| `RuntimeTarget<8>` / `InProcess` | `RuntimeTarget64` / `InProcess`（`RuntimeProtocol`） |

参考：`swift/include/swift/ABI/TargetLayout.h`、`swift/include/swift/Remote/MemoryReader.h`。

## 读文件：直接用 MachOKit 打开文件时做的映射

`MachOFile` 的每次读取都从 MachOKit 打开文件时映射好的字节里取（MachOKit fork 0.55.102 起的 `@_spi(Support) fileBytes`，同一次打开得到的所有实例共用一份），按偏移 `loadUnaligned`，数组一次拷进结果。这一层不再自己映射文件，也不占自己的文件描述符；映射在打开时就已建好，读取不会因为映射失败而失败。读到文件之外抛 `FileIOError.offsetOutOfBounds`，负偏移同样抛错而不是崩溃。

从 dyld cache 里读出的镜像（`isLoadedFromDyldCache`）先问偏移落在哪个 cache 文件里（MachOKitExtensions 模块的 `cacheAndFileOffset(fromStart:)`），独立文件不问：MachOKit 以前会把独立文件的路径当成 dyld cache 再打开一遍，读一个元素就映射一次整个文件。

`FileMappingTests` 钉住：同一个 cache 文件的各个读者共用一份映射、打开后被删除的文件照样读得到、越界读取抛错。在 256 个描述符的上限内读完 400 个 Swift 镜像的那个测试要经 MachOSwiftSection 读元数据，留在那边。

## 读本进程：地址掩码

`InProcessContext.addressMask` 是本进程地址里真正属于地址的那些位，去掉了指针认证与 tag 位：Mac 的用户地址在 47 位以内，iPhone 在 36 位以内，arm64e 的签名从它们上面开始。它在进程里只算一次（取自 `MachOImage.current().vmaddrMask`）；`UnsafeRawPointer.stripPointerTags()` 每次都要找当前镜像、遍历 load command。读本进程指针的代码一律用这个掩码，不写常量——MachOSwiftSection 的交叉引用扫描就靠它，所以它是公开的。

`InProcessContext` 只在 Darwin 上编译：掩码要用 `MachOImage.current()`，MachOKit 只在有 dyld 的平台上声明它，而 Linux 上的进程本来也没有 Mach-O 镜像可读。

只剩 tag 位的地址与空指针一样抛错（本包的 `init(nonZeroBitPattern:)`）。`advanceAddress` 也先剥 tag：带 tag 的基址加上偏移不是进程能用的地址。

## 缓存范围（`cacheScope`）

上层有些只读的接口要按镜像缓存结果。`ReadingContext` 用一条带默认值的要求说出自己读的是哪个范围：`MachOContext` 答 `.image(identifier:)`，`InProcessContext` 答 `.process`，其余一律 `.uncached`。

- **同一个镜像只有一个键**：`.image` 带的就是读取器的 `MachOTargetIdentifier`，经读取器和经 context 存进去的是同一条缓存。
- **身份不装箱**：每次查缓存都要问一次 `cacheScope`。文件的 identifier 是路径加 UUID，放不进 existential 的内联缓冲，包成 `AnyHashable` 每次都要堆分配，所以载荷是具体类型 `MachOTargetIdentifier`。代价是 identifier 不是这个类型的读取器经 context 读时不缓存，只慢不错。
- **默认不缓存是安全边界**：进程范围那一层按地址做键，只有地址是绝对地址时两个镜像才不会撞。以文件偏移为地址的第三方 context 若落进去，会把 A 镜像的结果当成 B 镜像的返回。
- **只暴露缓存身份，不暴露读取器**：拿到 `.image` 的调用方做不了符号查询，也无从做类型转换。

## 包装类型读取器

宿主常把 `MachOFile` / `MachOImage` 包进自己的类型、转发全部读取（MachOKitUI 的 `MachOFileSource` / `MachOImageSource`）。这一层回答「这是哪种读取器」时，一律问 MachOKitExtensions 模块的三个取法：`asMachOImage`、`asMachOFile`、`underlyingReader`。宿主的类型声明 `MachOReaderWrapper` 之后，三者都问到它底下的读取器。

- `MachOContext.bindRebaseResolver` 先看读取器自己是否遵循 `MachOBindRebaseResolving`，没有就用 `underlyingReader` 的。
- `MachOContext.runtimePointer(at:)` 建在 `asMachOImage` 上：包装的是本进程镜像时给出指针，否则为 `nil`。
- 契约：包装类型在每个偏移读到的内容与底下的读取器相同，`identifier` 也相同，所以两者共用按镜像的缓存。

`ReaderKindCastScanTests` 扫描本包的 `Sources/MachOReading` 与 `Sources/MachOResolving`，禁止 `as? MachOImage` 一类写死读取器类型的判断。MachOKitExtensions 模块不在扫描范围内：三个取法本身就是做类型转换的地方。

## 与提案的差异

调研时读的是 MachOSwiftSection 的 0.24.0；搬的是它 `next` 上删去废弃写法之后的版本，那时 0088 已经改了读文件的方式。所以：

- 没有「锁换成 `NSLock`」这一步：带 `@Mutex` 的文件映射代码在 `next` 上已经删了。本包对 MachOKit 的下限因此提到 0.55.102（`fileBytes`）。
- 搬来的测试是 `FileMappingTests` 中只测读取层的三个，不是已不存在的 `ConcurrentFileMappingTests`。
- `InProcessContext.addressMask` 和 `Symbols.init` 一样从 `package` 提为公开：`next` 上 MachOSwiftSection 的交叉引用扫描用它。
- `FileHandle` 遵循 `MachONamespacing` 时去掉了 `@retroactive`：协议在本包声明。

## 已知局限

- 本包承诺支持 Linux，但没有 Linux CI，本机也没有装 Linux 的 Swift SDK，这两个模块在 Linux 上能否编译未经验证。
- `ReadingContext` 只有 64 位的 `MachOContext`（`Runtime = RuntimeTarget64`）；32 位 Mach-O 没有对应的 context。

术语（context form / Mach-O form / pointer form、cache scope、reader wrapper）沿用 MachOSwiftSection 术语表里的定义。
