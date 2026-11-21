# MachOKitExtensions

Shared low-level extensions on top of [MachOKit](https://github.com/p-x9/MachOKit), used by
both [MachOSwiftSection](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection) and
[MachOObjCSection](https://github.com/MxIris-Reverse-Engineering/MachOObjCSection).

## Why this package exists

This code started life as the `MachOKitExtensions` target inside MachOSwiftSection. Because
MachOSwiftSection already depends on MachOObjCSection, MachOObjCSection could not depend back on
it without forming a package-level cycle — so the ObjC side had to go without the address
arithmetic, cache resolution and load-command helpers that the Swift side took for granted.

Extracting the target into its own package breaks that cycle: both packages now depend on
`MachOKitExtensions`, and neither depends on the other.

Since 2.0.0 the package also carries the rest of MachOSwiftSection's Mach-O layer as products of
their own: the reading layer (`MachOReading`, `MachOResolving`), relative pointers, the per-image
shared cache, dependency closures, and the language-neutral half of its symbol index, on which a
new index of C and C++ symbols is built. A package can use them without depending on
MachOSwiftSection; MachOKitUI with its `SwiftSection` trait off is the first such package.
MachOSwiftSection keeps what is Swift-specific, its Swift symbol index included.

## Products

| Product | What it is |
|---|---|
| `MachOKitExtensions` | The extensions on MachOKit's types listed below |
| `MachOReading` | Reading typed values out of a file, a loaded image or this process's memory: `Readable` (conformed to by `MachOFile`, `MachOImage` and `UnsafeRawPointer`), and `ReadingContext` with `MachOContext` (addresses are offsets in a file or image) and `InProcessContext` (addresses are pointers in this process; Darwin only) |
| `MachOResolving` | `Resolvable`, a value read at an address, and `SymbolOrElement`, which names the symbol dyld binds at an address instead of reading what is not there; the `Symbol` and `Symbols` value types |
| `MachOPointers` | Relative and indirect pointers as Swift's runtime lays them out (`RelativeDirectPointer`, `RelativeIndirectablePointer`, their integer-pair forms, `SymbolOrElementPointer`), read through a `ReadingContext` |
| `MachOCaches` | `SharedCache`: one lazily built value per image, shared by every caller, with an eviction registry (behind the `Internals` SPI) |
| `MachODependencies` | The images a binary links, found in this process, on disk or in a dyld shared cache: `DependencyClosure`, `DependencySearchPath`, `FileDependencyLocator` |
| `MachOSymbols` | `SymbolIndexStore`, an index of an image's C and C++ symbols by offset, by nearest offset, by name and by export status; `SymbolLanguage`, which tells a symbol name's language from its leading bytes — C++ here, every other language through `SymbolLanguageRegistry`, where the package that owns it registers it |
| `CPlusPlusSymbols` | `CPlusPlusSymbolName`, a C++ symbol name taken apart — what it names, the scopes it sits in, its signature — `CPlusPlusSymbolIndexStore`, an image's C++ symbols arranged in a tree of the namespaces, types and functions they sit in, and `CPlusPlusClassIndexStore`, an image's C++ classes read from their run-time type information and vtables — bases and virtual functions, for stripped classes too. Built on LLVM's Itanium demangler, vendored as C++ behind a plain C interface: no C++ interoperability needed |
| `MachOBase` | `MachOKitExtensions`, `MachOReading`, `MachOResolving` and `MachOPointers` as one import |
| `MachOFoundation` | `MachOBase`, `MachOSymbols` and `MachODependencies` as one import (not `CPlusPlusSymbols`) |
| `ARM64InstructionDecoding` | Hand decoders for the few A64 encodings MachOSwiftSection's analyses read, and the trampoline shapes the linker and the dyld cache builder emit. Its interface is the `Internals` SPI, for MachOSwiftSection |
| `MachOAddressResolution` | Where a call from a Mach-O file leads, read offline: an image's address space, the stubs and stub islands on the way, what a pointer slot holds, the cache image an address lies in. `Internals` SPI, for MachOSwiftSection |
| `MachOCodeReferences` | The language-free core of MachOSwiftSection's cross-reference analysis: image memory, function tables, the instruction scan and the recognizer extension point its Objective-C and Swift layers plug into. `Internals` SPI, for MachOSwiftSection and MachOObjCSection; the analyzer itself is MachOSwiftSection's `CrossReferenceAnalysis` |
| `MachOFixtureSupport` | Test support without the testing library, for test targets only: names for the images, files and dyld shared caches tests read (structs a package extends with its own), the slice of a file this process runs (`HostSlice`), images of this process by address or path, `FixtureCompiler`, which builds a small C, C++ or Swift library or executable, from one source file or several, while the tests run, once per process, and `ForwardingReader`, a reader that only forwards |
| `MachOTestingSupport` | Test support built on Swift Testing, for test targets only: `MachOFixtureTests`, a suite base class that reads one image from its file and as this process loaded it and checks that every reader agrees (`acrossAllReaders`, `acrossAllContexts`); base classes for a file, a loaded image, a dyld shared cache and a file inside Xcode; and `ExclusiveImageAccess`, a trait that serializes every test touching the same image across suites and test targets |

## What the MachOKitExtensions module provides

| Area | Highlights |
|---|---|
| Address arithmetic | `address(forOffset:)`, `addressString(forOffset:)`, `resolveOffset(at:)` |
| Pointer tagging | `stripPointerTags(of:)` and the architecture-specific `vmaddrMask` |
| Dyld shared cache | `cache(for:)`, `cacheAndFileOffset(for:)`, `cacheAndFileOffset(fromStart:)`, `machOFile(by:)` |
| Bind / rebase | `resolveRebase(fileOffset:)`, `resolveBind(fileOffset:)`, `isBind(fileOffset:)`, and `resolveSelfBind(fileOffset:)` for a bind the image satisfies from its own exports (what `-interposable` links a pointer to an exported symbol as, the frameworks of a simulator runtime among them) |
| Cached views | `machOFile.cached` memoizes chained fixups behind the same `resolveRebase(at:)` / `resolveOptionalRebase(at:)` / `resolveBind(at:)` API, and the export trie as `exportTrie`; `DyldCacheLoaded.cachedCurrent`; `FullDyldCache.cachedHost`; `cache.cached.headerInfo(at:in:)` |
| Load commands | Typed accessors for `__TEXT`, `__DATA`, `__DATA_CONST`, `__AUTH`, `__AUTH_CONST`, build version |
| Protocols | `MachORepresentableWithCache`, `LocatableLayoutWrapper`, `MachOTargetIdentifier` |
| Reader wrappers | `MachOReaderWrapper` for a type of your own that holds a reader and forwards every read to it; `asMachOImage`, `asMachOFile` and `underlyingReader` answer for the reader beneath any layer of wrapping |

## Usage

```swift
.package(url: "https://github.com/MxIris-Reverse-Engineering/MachOKitExtensions", from: "3.0.0")
```

```swift
.product(name: "MachOKitExtensions", package: "MachOKitExtensions"),
.product(name: "MachOReading", package: "MachOKitExtensions"),
.product(name: "MachOSymbols", package: "MachOKitExtensions"),
```

```swift
import MachOKit
import MachOKitExtensions

let machOFile: MachOFile = // …
// Turn a file offset into the address it will have once loaded.
let address = machOFile.addressString(forOffset: 0x1000)
```

One reading function serves a file, a loaded image and this process alike, because it takes a
`ReadingContext` rather than a particular reader:

```swift
import MachOKit
import MachOReading

func magic<Context: ReadingContext>(at address: Context.Address, in context: Context) throws -> UInt32 {
    try context.readElement(at: address)
}

let fromFile = try magic(at: 0, in: machOFile.context)
let fromImage = try magic(at: 0, in: machOImage.context)
```

The symbol index answers for C and C++ names. Other languages are recognized by the packages that
own them: MachOSwiftSection's `SwiftSymbols` registers Swift and MachOObjCSection registers
Objective-C when their images load. The index then keeps only where those languages' symbols sit,
so `closestSymbols` answers `nil` for an address inside their code rather than naming the C function
before it. A language nobody registered counts as C:

```swift
import MachOKit
import MachOSymbols

let store = SymbolIndexStore.shared
let headerOffset = store.offset(ofSymbolNamed: "__mh_execute_header", in: machOFile)
let enclosing = store.closestSymbols(at: instructionOffset, in: machOFile)?.symbols.first?.name
let language = SymbolLanguage(ofSymbolNamed: "__ZN4llvm5Value4dumpEv")   // .cPlusPlus
```

A package that owns a language defines it and registers a recognizer for its names, once, before
any classification runs — from a C target's `__attribute__((constructor))` that calls a Swift
function exported with `@c`:

```swift
extension SymbolLanguage {
    public static let rust = SymbolLanguage(rawValue: "Rust")
}

@c(rust_symbols_register_symbol_language)
func registerRustSymbolLanguage() {
    SymbolLanguageRegistry.shared.register(.rust, where: { name in strncmp(name, "__R", 3) == 0 })
}
```

`CPlusPlusSymbols` takes C++ names apart and arranges an image's C++ symbols by scope. An Itanium
name never says whether `foo` in `foo::bar` is a namespace or a class, so a scope is a type or a
namespace only when some symbol name of the image shows it — a constructor, a vtable, a `const`
member function, a use as a parameter type — and is `.undetermined` otherwise. Each scope carries
the evidence it was judged by:

```swift
import CPlusPlusSymbols

let name = CPlusPlusSymbolName(mangledName: "__ZNK4llvm5Value4dumpEv")!
name.scopePath      // ["llvm", "Value"]
name.baseName       // "dump"
name.kind           // .function

let store = CPlusPlusSymbolIndexStore.shared
for scope in store.childScopes(of: .global, in: machOImage) where scope.kind == .type {
    let constructors = store.members(of: scope, in: machOImage).filter { $0.name.kind == .constructor }
    print(scope.qualifiedName, scope.evidence, constructors.map(\.name.demangledName))
}
```

`CPlusPlusClassIndexStore` reads an image's data instead of its symbols: every class `typeinfo`
(`std::type_info` object) and every vtable that points at one. A class whose symbols are stripped
is found by its typeinfo's name, with its bases — in other images too — and its vtables. A slot
whose function has no name of its own is named after the function the same slot holds in the
primary base's table, walking up the bases. An image of this process reaches bases in the other
loaded images, a file out of a dyld shared cache in the same cache, and a standalone file in the
libraries its dependency search paths locate:

```swift
let classes = CPlusPlusClassIndexStore.shared
let hiddenClasses = classes.classes(in: machOFile).filter { !$0.hasTypeInfoSymbol }
if let cellID = classes.class(named: "TST::CellID", in: machOFile) {
    // `@rpath` siblings are not searched unless named.
    let tables = classes.virtualTables(of: cellID, in: machOFile, dependencySearchPaths: [.machOFile(path: persistencePath), .systemDyldSharedCache])
    for function in tables.first?.functions ?? [] {
        print(function.slotIndex, function.name?.demangledName ?? "?", function.baseFunction?.className ?? "")
    }
}
```

2.0.0 adds the `MachOReading`, `MachOResolving`, `MachOPointers`, `MachOCaches`,
`MachODependencies`, `MachOSymbols`, `MachOBase` and `MachOFoundation` products, and the
`ARM64InstructionDecoding`, `MachOAddressResolution` and `MachOCodeReferences` products of
MachOSwiftSection's cross-reference analysis, and changes nothing in the `MachOKitExtensions` module, which re-exports none of them. It is a major version
because MachOSwiftSection 0.24 and earlier declare modules of those same names, and SwiftPM refuses a package graph with two modules of one
name: a `from: "1.x"` requirement keeps such a MachOSwiftSection from ever resolving together
with this release.

3.0.0 takes the Swift and Objective-C rules out of `SymbolLanguage`: `.swift` is now defined by
MachOSwiftSection's `SwiftSymbols` and `.objectiveC` by MachOObjCSection, each registered when its
image loads. Code that compared a language with `.swift` or `.objectiveC` imports that module too.
Without either package in the process, Swift and Objective-C names count as C. It also adds the
`CPlusPlusSymbols` product.

3.1.0 adds `CPlusPlusClassIndexStore` to `CPlusPlusSymbols`: an image's C++ classes read from
their run-time type information and vtables, named across images. `CPlusPlusSymbols` now depends on
`MachOReading`, `MachOAddressResolution` and `MachODependencies` of this package. Run
`swift test --filter ClassIndexDemoTests` to see what it recovers from the one-file demo in
`Tests/ClassIndexDemo/ClassIndexDemo.cpp`.

A type of your own that holds a reader and forwards every read to it declares what it wraps,
so that whatever is worked out per reader kind — absolute pointers for an image mapped into
this process, a file's own offset accounting — is worked out for the reader beneath it:

```swift
struct ImageDocument: MachORepresentableWithCache {
    let machOImage: MachOImage
    // …every requirement forwarded to `machOImage`, `identifier` included…
}

extension ImageDocument: MachOReaderWrapper {
    var base: MachOImage { machOImage }
}

let document = ImageDocument(machOImage: machOImage)
document.asMachOImage   // the image beneath, not nil
```

## Layout

`Sources/` is grouped by layer, the way MachOSwiftSection's is; each group holds the targets of
that layer, and `Package.swift` gives every target its path (`path: "Sources/<Group>/<Target>"`), so
a new target goes into a group directory and declares its path. Products and module names do not
depend on where the sources sit.

| Group | Targets |
|---|---|
| `Core` | `MachOKitExtensions` |
| `Reading` | `MachOReading`, `MachOResolving`, `MachOPointers` |
| `Images` | `MachOCaches`, `MachODependencies` |
| `Symbols` | `MachOSymbols`, `CPlusPlusDemangling`, `CPlusPlusSymbols` |
| `Analysis` | `ARM64InstructionDecoding`, `MachOAddressResolution`, `MachOCodeReferences` |
| `Umbrellas` | `MachOBase`, `MachOFoundation` |
| `TestSupport` | `MachOFixtureSupport`, `MachOTestingSupport` |

`Tests/` stays flat, one directory per test target. A test that scans a module's sources climbs from
its own `#filePath` to the package root and then into `Sources/<Group>/<Target>`.

## Platforms

macOS 10.15+, iOS 13+, watchOS 6+, tvOS 13+ and visionOS 1+.

Linux is not supported. Since 3.2.0 the package guards its shared state with the `Mutex` of
[FrameworkToolbox](https://github.com/Mx-Iris/FrameworkToolbox)'s `OSToolbox`, which is built on
`os_unfair_lock` and exists on Apple platforms only; it is used the way the standard library's
`Mutex` is, without that one's macOS 15 floor. Besides it the package depends on MachOKit,
[AssociatedObject](https://github.com/p-x9/AssociatedObject) and, for `MachOReading`,
[swift-fileio](https://github.com/p-x9/swift-fileio). `InProcessContext` and the parts of
`MachOCodeReferences` that read this process (`CodeImageSet.inProcess`,
`InProcessCrossReferenceMemory`) read this process's own Mach-O images.

## License

MachOKitExtensions is released under the MIT License. See [LICENSE](LICENSE).

`Sources/Symbols/CPlusPlusDemangling/ItaniumDemangle` holds LLVM's Itanium demangler, copied unchanged
from libc++abi, and `Sources/Symbols/CPlusPlusDemangling/CPlusPlusDemangling.cpp` holds two short excerpts
of libc++abi's `cxa_demangle.cpp`. They are part of the LLVM Project, under the Apache License
v2.0 with LLVM Exceptions. See
[Sources/Symbols/CPlusPlusDemangling/ItaniumDemangle/LICENSE.TXT](Sources/Symbols/CPlusPlusDemangling/ItaniumDemangle/LICENSE.TXT).
