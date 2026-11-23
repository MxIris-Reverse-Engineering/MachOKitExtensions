# 0008 - C++ 签名里的类型位置，以及不带参数的外层函数

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-11-21
- **最后更新**: 2026-11-21
- **所属愿景**: 无
- **关联提案**: 本包 [0005-cplusplus-symbol-classification](0005-cplusplus-symbol-classification.md)（名字的拆分与作用域树）；下游 RuntimeViewer 的提案 `cplusplus-objects`（C++ 对象的伪头文件，它要给参数里的类型着色并建跳转）
- **实现分支 / PR**: `feature/cplusplus-signature-types`，从 `main` 切出，快进合入 `main`
- **配套文档**: 实现说明 [Internal/CPlusPlusSymbols.md](../Internal/CPlusPlusSymbols.md)（「签名里的类型位置」与作用域路径一节）
- **网页版**: 同目录同名的 `.html`

## 摘要

`CPlusPlusSymbolName` 新增 `parameterTypeReferences` 与 `returnTypeReferences`：参数文本（`parameters`）与返回类型文本（`returnType`）里每个命名类型的作用域路径，以及它在文本里的范围（`Range<String.Index>`）。位置在打印文本的同一次遍历里从 AST 节点记下，调用方不必再解析打印出来的文本。同时修一处作用域的漏判：局部实体的外层不带参数时（clang 给 ObjC++ 里 ObjC 方法的局部静态变量起名 `Z 26-[CAMetalDrawable texture] E 9onceToken`），外层也是函数作用域，不再落成「未定」。纯新增 API 加一处行为修正，随 3.3.0 发布。

## 动机

- **下游要分开显示签名里的类型。** RuntimeViewer 把一个镜像的 C++ 类打印成伪头文件，`CPlusPlusSymbolName.parameters` 是一整段文本（`(CA::Render::Surface*)`），它只能整段当普通文字输出：`CA::Render::Surface` 既不着色、也点不过去，而声明处与基类里的类名都能。要按类型分开，下游只能回头解析打印出来的文本——模板实参、函数指针、`(anonymous namespace)`、ABI 标签都会让这种解析出错，而本包手里本来就有 AST。
- **本包已经找过这些类型。** 建作用域树时，`collectTypes` 沿参数与返回类型的 AST 收集「当作类型用到」的路径（`usedAsType` 证据），只是没公开，也不知道它们在文本里的位置。
- **ObjC 方法被当成命名空间。** RuntimeViewer 在 QuartzCore 的 C++ 对象里列出了 `-[CAMetalDrawable texture]`、`-[CALayer didChangeValueForKey:]` 这类「命名空间」：它们其实是 ObjC++ 方法里的 `dispatch_once` 令牌一类局部静态变量的外层。`appendEnclosingFunction` 只在外层是 `FunctionEncoding`（带参数）时才标成函数，ObjC 方法的修饰名只有一段名字，于是外层既无证据也无提示，判成「未定」。

## 前期调研

- **打印钩子。** 引入的 `ItaniumDemangle`（libc++abi 的 `src/demangle`）里，`OutputBuffer` 有虚函数 `printLeft(const Node &)` / `printRight(const Node &)`，以及 `notifyInsertion`、`notifyDeletion`（LLVM 为 lldb 的 `TrackingOutputBuffer` 加的）。每个节点打印子节点都经过 `OB.printLeft(*child)` 或 `child->print(OB)`（后者再调 `OB.printLeft`）：`ItaniumDemangle.h` 里前者 16 处、后者 72 处，没有绕过钩子直接调 `Node::printLeft` 的地方。`Node::printLeft` 是私有的、只对 `OutputBuffer` 开放友元，派生类要调基类的 `OutputBuffer::printLeft(node)`。
- **会回头改的地方。** `OutputBuffer::insert`（`notifyInsertion`）与 `setCurrentPosition` 回退（`notifyDeletion`：`printWithComma` 去掉空的参数包展开、另两处）——记下的范围要随之挪动或丢弃。
- **名字的复用。** 替换（`S_`、`S0_`……）让同一个节点在打印里出现多次：`both(CA::Foo, CA::Foo::Bar)`（`__Z4bothN2CA3FooENS0_3BarE`）里，`CA::Foo::Bar` 的限定词就是第一个参数的那个节点。只按「节点在集合里」记会把限定词也记成一个类型。
- **ObjC 方法的局部名。** `c++filt '_ZZ26-[CAMetalDrawable texture]E9onceToken'` 得 `-[CAMetalDrawable texture]::onceToken`：`Z <encoding> E` 里的 encoding 是一个不带 `<bare-function-type>` 的 `NameType`。Itanium 文法里 `<local-name>` 的外层总是函数（`Z <function encoding> E`）。

## 提议方案

1. `CPlusPlusSymbolName.TypeReference`：`path`（与 `CPlusPlusScope.path` 同样打印的各段，含模板实参）与 `range`（在 `parameters` 或 `returnType` 里，模板实参包括在内）。`CPlusPlusSymbolName` 新增 `parameterTypeReferences`、`returnTypeReferences`，按起点排序；模板的范围包住它实参里的类型，排在它们前面；范围只会嵌套、不会交错；限定词不单列；内置类型、指针、引用、cv 限定都不算（`CA::Foo const*` 的范围只盖 `CA::Foo`）。
2. 哪些算类型，与「当作类型用到」同一套判定：`collectTypes` 抽成 `forEachNamedType`，两处共用。
3. 位置与文本同一次打印得出：`PrintedSignaturePart` 取代参数与返回类型原来的 `CachedText`，第一次取文本或位置时一起算。
4. 外层不带参数的局部名，外层的最后一段也标函数提示。
5. C 接口新增 `CPlusPlusDemanglerSignaturePart`、`CPlusPlusDemanglerByteRange` 与四个取值函数；Swift 一侧把字节偏移换成 `String.Index`（文本就是这些字节解码来的）。

### 非目标

- 作用域路径各段（函数作用域的参数）、实体模板实参（`templateArguments`）里的类型位置：下游暂时不需要；需要时照同一办法加。
- 区分类与枚举、结构体：修饰名里没有这个信息。
- 完整名字（`demangledName`）里的位置。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `Sources/Symbols/CPlusPlusDemangling/include/CPlusPlusDemangling.h` | 修改 | `CPlusPlusDemanglerByteRange`、`CPlusPlusDemanglerSignaturePart`、四个 `…SignatureType…` 函数；函数提示的注释 | 方案 5 | 2 |
| `Sources/Symbols/CPlusPlusDemangling/CPlusPlusDemangling.cpp` | 修改 | `SignatureType`、`PrintedSignaturePart`、`TypeRecordingOutputBuffer`；`forEachNamedType`（`collectTypes` 改用它）、`printSignaturePart`、`parametersPart`、`returnTypePart`；`appendEnclosingFunction` 的无参数分支 | 方案 2–4 | 1、2 |
| `Sources/Symbols/CPlusPlusSymbols/CPlusPlusSymbolName.swift` | 修改 | `TypeReference`，两个新属性，类型注释 | 方案 1 | 2 |
| `Sources/Symbols/CPlusPlusSymbols/CPlusPlusDemangler.swift` | 修改 | `ParsedName.parameterTypeReferences(in:)`、`returnTypeReferences(in:)` | 方案 5 | 2 |
| `Sources/Symbols/CPlusPlusSymbols/CPlusPlusScope.swift` | 修改 | `Kind.function` 的注释写上 ObjC 方法 | 方案 4 | 1 |
| `Tests/CPlusPlusSymbolsFixture/Fixture.cpp` | 修改 | 用汇编标签手写一个 ObjC 方法局部静态变量的名字（夹具编译器只编 C、C++、Swift） | 第 1 步行为 | 1 |
| `Tests/CPlusPlusSymbolsTests/CPlusPlusSymbolIndexStoreTests.swift` | 修改 | `objectiveCMethodWithALocalIsAFunctionScope` | 第 1 步行为 | 1 |
| `Tests/CPlusPlusSymbolsTests/CPlusPlusSymbolNameTests.swift` | 修改 | 六条类型位置的测试 | 第 2 步行为 | 2 |
| `Documentations/Internal/CPlusPlusSymbols.md` | 修改 | 作用域路径一节补无参数外层；新增「签名里的类型位置」；测试一节 | 文档同批 | 3 |
| `README.md` | 修改 | `parameterTypeReferences` 的示例 | 对外说明 | 3 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案 | 索引 | 3 |

## 架构图

```text
CPlusPlusDemangling (C++)
  CPlusPlusDemangler
-   CachedText parameters, returnType
+   PrintedSignaturePart parameters, returnType      text + [SignatureType{start, end, path}]
~   collectTypes(node)            -> forEachNamedType(node, body)   (shared walk)
+   printSignaturePart(part, roots, print)
       forEachNamedType(roots) -> set of type nodes
       TypeRecordingOutputBuffer : OutputBuffer
         printLeft hook: node in set and not inside a name -> record [start, end)
         template argument list -> records again
         notifyInsertion / notifyDeletion -> move / drop records
~   appendEnclosingFunction: bare-name encoding -> last component hinted .function

CPlusPlusSymbols (Swift)
  CPlusPlusSymbolName
+   parameterTypeReferences, returnTypeReferences: [TypeReference{path, range}]
  CPlusPlusSymbolIndexStore      (unchanged; ObjC-method scopes now .function)
```

## 详细设计

```swift
extension CPlusPlusSymbolName {
    public struct TypeReference: Hashable, Sendable {
        public let path: [String]
        public let range: Range<String.Index>
    }
}

public struct CPlusPlusSymbolName {
    // …
    public let parameterTypeReferences: [TypeReference]
    public let returnTypeReferences: [TypeReference]
}
```

```c
typedef struct { size_t start; size_t end; } CPlusPlusDemanglerByteRange;
typedef enum : int32_t { CPlusPlusDemanglerSignaturePartParameters, CPlusPlusDemanglerSignaturePartReturnType } CPlusPlusDemanglerSignaturePart;
size_t CPlusPlusDemanglerGetSignatureTypeCount(CPlusPlusDemangler *, CPlusPlusDemanglerSignaturePart);
CPlusPlusDemanglerByteRange CPlusPlusDemanglerGetSignatureTypeRange(CPlusPlusDemangler *, CPlusPlusDemanglerSignaturePart, size_t typeIndex);
size_t CPlusPlusDemanglerGetSignatureTypeComponentCount(CPlusPlusDemangler *, CPlusPlusDemanglerSignaturePart, size_t typeIndex);
CPlusPlusDemanglerText CPlusPlusDemanglerGetSignatureTypeComponentName(CPlusPlusDemangler *, CPlusPlusDemanglerSignaturePart, size_t typeIndex, size_t componentIndex);
```

- **「在名字里」的判定**：`TypeRecordingOutputBuffer` 记下一个类型节点后，到它打印完为止不再记别的节点（限定词、名字各段）；进入 `TemplateArgs` 节点时重新开始记，出来后恢复。
- **排序**：按起点升序，起点相同的按终点降序（外层在前）。
- **字节到 `String.Index`**：文本由同一段字节按 UTF-8 解码而来，偏移就是 UTF-8 偏移；万一落在字符中间（解码时替换过非法字节）就跳过这一项。
- **代价**：类型位置随 `CPlusPlusSymbolName` 一起算出（多一次 AST 遍历与按需的路径打印）。建作用域树只读 `ParsedName` 的作用域各段，不构造 `CPlusPlusSymbolName`，不受影响。

## 替代方案考量

- **下游解析参数文本**：快，但要自己处理模板、函数指针、匿名命名空间、ABI 标签，而本包有 AST。否决。
- **公开 `referencedTypePaths`，下游拿路径去文本里搜**：路径来自节点，位置却靠文本搜索，同名前缀、重复出现时会错位。否决。
- **返回带语义标注的文本（类 `NSAttributedString`）**：本包不定义展示用的标注类型；范围加路径更中性，下游自己决定怎么显示。

## 影响

### 源码兼容性（source compatibility）

纯新增：两个新属性、一个新嵌套类型。`CPlusPlusSymbolName` 是 struct，没有公开的成员逐一初始化器，新增存储属性不破坏调用点。行为修正：ObjC 方法这类外层不带参数的局部名，外层作用域的 `kind` 从 `.undetermined` 变成 `.function`——`Kind` 的文档本来就说种类会随规则改进而变。

### ABI 兼容性（条件项）

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

- 本仓库：只有 `CPlusPlusSymbols` 与它的 C 层。
- RuntimeViewer：抬到 3.3.0，伪头文件把参数与返回类型里的类型按 `TypeReference` 输出成类名记号（着色并可跳转）；QuartzCore 等 ObjC++ 镜像不再列出以 ObjC 方法命名的「命名空间」。
- MachOSwiftSection、MachOObjCSection 不读这两个属性，不受影响。

### 文档与示例

README 的 `CPlusPlusSymbols` 示例加 `parameterTypeReferences`；实现说明 `Internal/CPlusPlusSymbols.md` 补两节。

## API 演进与废弃策略

没有被替代的 API。新增 API，semver minor：3.3.0。

## 落地步骤

1. **[完成] 外层不带参数的局部名是函数作用域** —— `appendEnclosingFunction`、夹具、store 测试、`Kind.function` 注释
   - 行为：`objectiveCMethodWithALocalIsAFunctionScope`
2. **[完成] 签名里的类型位置** —— C 接口、`PrintedSignaturePart`、`TypeRecordingOutputBuffer`、`forEachNamedType`、Swift 接口
   - 行为：`parameterTypeReferencesLocateEachNamedTypeTheParametersSpell`
   - 行为：`aQualifierIsNoTypeReferenceOfItsOwn`
   - 行为：`typesInATemplateArgumentListFollowTheirTemplate`
   - 行为：`typesInsideAFunctionPointerParameterAreFound`
   - 行为：`returnTypeReferencesLocateTheReturnTypesNamedTypes`
   - 行为：`builtInTypesAndNamesWithoutASignatureHaveNoTypeReferences`
   - 行为：`demangledNameMatchesSystemCxaDemangleForEveryCPlusPlusNameOfLibCPlusPlus` 仍通过（参数的打印换了缓冲区，文本不变）
3. **[完成] 文档** —— 实现说明、README、两份索引

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-21 | Created | RuntimeViewer 的 C++ 伪头文件里参数类型不着色，且 QuartzCore 列出了以 ObjC 方法命名的命名空间；两处根子都在本包。用户选择在本包加接口、发 3.3.0（而不是在 RuntimeViewer 里解析参数文本），同一版本修掉作用域漏判。 |
| 2026-11-21 | 范围只记「当作类型用到」的节点 | 只按 `isNamedType` 记会把模板非类型实参里的名字（`&g`、表达式）也当成类型；复用 `collectTypes` 的遍历，遇到表达式就停。 |
| 2026-11-21 | 限定词不单列 | `S0_` 让 `CA::Foo::Bar` 的限定词复用 `CA::Foo` 的节点；打印一个类型的名字时不再记别的节点，进了模板实参表才重新记。测试 `aQualifierIsNoTypeReferenceOfItsOwn` 钉住。 |
| 2026-11-21 | 夹具用汇编标签 | 夹具编译器只编 C、C++、Swift，给它加 ObjC++ 要改公开枚举、波及 MachOSwiftSection；夹具里已有 `__asm__("__Z_fixture_unparsable")` 的先例。 |
| 2026-11-21 | Implemented | 测试先红后绿，全量测试通过；快进合入 `main`，发布 3.3.0。 |
