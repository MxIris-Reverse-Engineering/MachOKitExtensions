# MachOFixtureSupport 与 MachOTestingSupport：两个包共用的测试支持

> 实现说明，随代码维护。读者：维护者，以及在本包或 MachOSwiftSection 里写测试的人。
> 来自 MachOSwiftSection 提案 [shared-macho-testing-support](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/draft-shared-macho-testing-support.md)（由那边维护唯一提案）：MachOSwiftSection 测试支持里与 Swift 无关的部分搬到这里，本包自己测试里各写一份的辅助也换成这里的版本。

## 模块定位

两个 product，按「要不要依赖 Testing」拆开：

- `MachOFixtureSupport`：不 import Testing。给测试要读的镜像起名字、打开 cache 与文件、挑本进程的 slice、找进程里的镜像、测试运行时现编小库，以及几样零碎的东西（只转发的包装读取器、`TestActor`、`ProcessMemory`、`.print()`）。只依赖 `MachOKit` 与 `MachOKitExtensions`。
- `MachOTestingSupport`：import Testing，依赖前者与 `MachOReading`。测试基类（`MachOFileTests`、`MachOImageTests`、`DyldCacheTests`、`XcodeMachOFileTests`、`MachOFixtureTests`）、跨读取器断言、按镜像互斥的 trait `ExclusiveImageAccess`。

两个包里与 Swift 有关的测试支持（夹具内容、baseline、覆盖率、快照）留在 MachOSwiftSection。

## 契约

1. **只链接到测试 target。** 这两个 product 带 `Process`、现编库、对 `CustomStringConvertible` 与 `Error` 的 `print()` 扩展，进了正式代码会污染使用方。
2. **相对路径的锚点由调用方传。** 包内夹具（编进自己源码树的二进制）用 `MachOFileName(path:relativeTo:)` 命名，锚点一般是调用方的 `URL(fileURLWithPath: #filePath)`：这个模块不知道别的包的源码在哪。相对路径按 `URL(fileURLWithPath:relativeTo:)` 的规则解析，文件 URL 以它所在的目录为基准。
3. **本机 cache 进程内共用一份。** `DyldSharedCachePath.current` 的路径取自 `FullDyldCache.cachedHost`（进程只打开一次），不写死 Cryptexes 卷上的位置；`DyldCacheTests` 读本机 cache 时也用 `cachedHost` 和它的 `mainCache`。确实要一个新实例的测试显式写 `DyldCache(path: .current)` 或 `FullDyldCache(path:)`。
4. **名字类型都是 struct 加静态成员。** `MachOImageName`、`MachOFileName`、`XcodeMachOFileName`、`DyldSharedCachePath` 都能用 extension 补本包自己的条目，以后加镜像不破坏调用方。静态成员照镜像本名拼写（`.SwiftUI`、`.Foundation`），因为值就是镜像名。

## 文件对照

| 模块 | 文件 | 内容 |
|---|---|---|
| `MachOFixtureSupport` | `DyldSharedCachePath` | cache 的主文件路径与版本轴标签；`current`、`macOS(_:)`、`iOS(_:)`（归档卷 `/Volumes/DyldSharedCaches/<平台>/<版本>/`） |
| | `MachOImageName`、`MachOFileName`、`XcodeMachOFileName` | 进程里镜像的名字、磁盘上的文件（含 `.app`、`.framework`）、Xcode 里的文件 |
| | `Opening` | `loadFromFile(named:)`、`MachOImage(named:)`、`DyldCache` / `FullDyldCache` 的 `init(path:)` 与 `machOFile(named:)` |
| | `HostSlice` | 挑本进程 CPU 的 slice |
| | `ProcessImages` | 按地址或路径找进程里的镜像；cache 里的文件与进程里同一镜像成对返回 |
| | `FixtureCompiler` | 测试运行时经 `xcrun` 编 C、C++、Swift 动态库（只在 macOS） |
| | `ForwardingReader` | 只转发、不加逻辑的包装读取器，`DeclaredWrapper` 时遵循 `MachOReaderWrapper` |
| | `TestActor`、`ProcessMemory`、`Printing` | 测试用的全局 actor、进程内存读数、`.print()` |
| `MachOTestingSupport` | `ExclusiveImageAccess` | 跨 suite、跨测试 target 按镜像互斥的 trait |
| | `ImageTestBases` | `MachOFileTests`、`MachOImageTests`、`XcodeMachOFileTests`、`DyldCacheTests` |
| | `MachOFixture`、`MachOFixtureTests` | 不绑定夹具的跨读取器基类 |

## 选 slice（`HostSlice`）

先找 CPU 类型相同、去掉能力位后子类型也相同的 slice，再退到 CPU 类型相同的任意一个，都没有就抛 `HostSliceError`。arm64e 进程拿到 arm64e 的 slice；arm64 进程读系统二进制时拿到 arm64e 的。单架构文件不论 CPU 都直接用。本进程的 CPU 取主可执行文件的头（`_dyld_get_image_header(0)`）。

## 跨读取器基类（`MachOFixtureTests`）

子类覆写 `class var fixture: MachOFixture` 说明镜像从哪来，两种来源：

- `MachOFixture(fileURL:imageName:loadsIntoProcess:)`：磁盘上的文件；`loadsIntoProcess` 时先 `dlopen`，再按 `imageName`（`MachOImage(name:)` 认的名字，路径最后一段去掉扩展名）找进程里的镜像。
- `MachOFixture(imageContaining:)`：进程里已经有的镜像，用其中一个地址（函数、全局变量或 `#dsohandle`）找到，文件路径取自 `dladdr`。shared cache 里的镜像没有自己的文件，不能这样用，改用 `ProcessImages.cacheFileAndLoadedImage(path:)`。

读不到时初始化抛 `MachOFixtureError`（文件不存在、进程里没有这个镜像、地址不在任何镜像里）。基类据此建出 `machOFile`（本进程 CPU 的 slice）、`machOImage`，以及 `fileContext`、`imageContext`、`inProcessContext`。初始化是 `async throws`，与 MachOSwiftSection 原来的基类一致。

跨读取器的写法：

| 写法 | 用途 |
|---|---|
| `acrossAllReaders(file:image:inProcess:)` / `acrossAllContexts(file:image:inProcess:)` | 三个闭包，进程内那个可选；结果都要等于文件那份，返回它 |
| `acrossAllReaders(fileSubject, imageSubject) { subject in … }` | 被测对象成对传入，一个闭包 |
| `acrossAllContexts(fileSubject, imageSubject) { subject, context in … }` | 同上，闭包另拿到对应的 `any ReadingContext`；收 `some ReadingContext` 的接口经 SE-0352 隐式打开 |
| `acrossAllReaders { machO in … }` | 被测的就是读取器本身：闭包先拿到 `machOFile`，再拿到 `machOImage`（`any MachORepresentableWithCache`） |
| `usingInProcessOnly { context in … }` | 只有进程内才有的东西（运行时建的 metadata） |

不一致时记一个 issue，注释写明哪两个读取器分歧（`MachOFile vs MachOImage diverged`、`MachOFile vs InProcess diverged`、`fileContext vs imageContext diverged`），Testing 会把两边的值都打出来。

**比较的必须是与读取器无关的值。** 同一份数据在文件里与加载后的偏移不同（`__DATA` 段的文件偏移不等于它在内存里离头部的距离），所以本包 C++ 测试先把结果投影成去掉偏移的形状（`Tests/CPlusPlusSymbolsTests/ClassIndexFixtures.swift` 的 `ClassShape`、`VirtualTableShape`）再比较；偏移之间的关系（「基类指向 `Shape` 的 typeinfo」「address point 在 vtable 符号之后多远」）在闭包里各自算成布尔值或距离再返回。另一个已知的差别：对另一个镜像里的基类，文件读出的是绑定所写的库（`libc++.1.dylib`），进程里读出的是 dyld 实际找到符号的库（`libc++abi.dylib`，被 libc++ 重新导出），所以形状里只记「在另一个镜像」。

## 现编小库（`FixtureCompiler`）

`FixtureCompiler.shared.dynamicLibrary(named:language:source:arguments:)` 把源码编成 `lib<名字>.dylib`，install name 是 `@rpath/lib<名字>.dylib`，返回它的 URL。

- **每份请求只编一次**：名字、语言、源码、参数四样都相同就返回同一个文件；失败的结果也留着，下次原样抛出同一个 `FixtureCompilationError`（带命令、退出码和编译器写到 stderr 的全部内容）。所有构建共用一把锁，编译次数少，串行无妨。
- **产物位置**：进程的临时目录下 `MachOFixtureSupport-<pid>-<UUID>/<序号>-<名字>/`，每份一个目录；进程退出时由 `atexit` 删掉。`productsDirectory` 给出根目录。
- **库之间互相链接**：在参数里写 `-L <另一个库的目录> -l<它的名字>`。要找到被链接的库，测试显式给搜索路径（`DependencySearchPath.machOFile(path:)`），不依赖两者放在同一目录。
- **去掉本地符号**：用链接参数 `-Wl,-x`，效果与原来的 `strip -x` 相同，隐藏可见性的符号不进符号表。
- Swift 源码用 `swiftc -emit-library -module-name <名字>`；只有一个文件、没有 `main` 时加 `-parse-as-library`。
- 只在 macOS 上编译（依赖 `Process` 与 `xcrun`）。

## 按镜像互斥（`ExclusiveImageAccess`）

`.serialized` 只管一个容器内部的顺序，全局 actor 在 `await` 处会让出、挡不住交错，所以用 `TestScoping` 包住整个测试体，按字符串键加一把进程级、不可重入的锁。所有碰同一镜像的 suite 都要声明，只声明一边等于没有。键是双方拼写一致的任意字符串；本包只提供按字符串的初始化，使用方可以加按自己夹具名字的便捷初始化，让拼错变成编译错误。

## `.print()` 与静默

`CustomStringConvertible` 与 `Error` 的 `print()` 在环境变量 `MACHO_TESTING_SILENT=1` 时什么都不打（`TestOutput.isSilent`）。MachOSwiftSection 原来用编译条件 `SILENT_TEST`，那是它清单加在自己 target 上的，到不了这个模块，所以改成运行时读环境变量；CI 要静默就设这个变量。

## 已知局限

- `MachOFixture(imageContaining:)` 不支持 shared cache 里的镜像（见上）。
- `FixtureCompiler` 的锁覆盖整个编译，多个测试同时要不同的库时彼此等待。
- `XcodeMachOFileName` 的清单取自某一版 Xcode；找不到文件时 `url` 不带扩展名，读取时才报错。
