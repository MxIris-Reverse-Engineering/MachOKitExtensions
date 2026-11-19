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
| `CPlusPlusSymbols` | `CPlusPlusSymbolName`, a C++ symbol name taken apart — what it names, the scopes it sits in, its signature — and `CPlusPlusSymbolIndexStore`, an image's C++ symbols arranged in a tree of the namespaces, types and functions they sit in. Built on LLVM's Itanium demangler, vendored as C++ behind a plain C interface: no C++ interoperability needed |
| `MachOBase` | `MachOKitExtensions`, `MachOReading`, `MachOResolving` and `MachOPointers` as one import |
| `MachOFoundation` | `MachOBase`, `MachOSymbols` and `MachODependencies` as one import (not `CPlusPlusSymbols`) |
| `ARM64InstructionDecoding` | Hand decoders for the few A64 encodings MachOSwiftSection's analyses read, and the trampoline shapes the linker and the dyld cache builder emit. Its interface is the `Internals` SPI, for MachOSwiftSection |
| `MachOAddressResolution` | Where a call from a Mach-O file leads, read offline: an image's address space, the stubs and stub islands on the way, what a pointer slot holds, the cache image an address lies in. `Internals` SPI, for MachOSwiftSection |
| `MachOCodeReferences` | The language-free core of MachOSwiftSection's cross-reference analysis: image memory, function tables, the instruction scan and the recognizer extension point its Objective-C and Swift layers plug into. `Internals` SPI, for MachOSwiftSection and MachOObjCSection; the analyzer itself is MachOSwiftSection's `CrossReferenceAnalysis` |

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

## Platforms

macOS 10.15+, iOS 13+, watchOS 6+, tvOS 13+, visionOS 1+, and Linux.

Linux support matters here because MachOObjCSection supports Linux, and it would have regressed
had this package pulled in Apple-only dependencies. The package therefore depends only on
MachOKit, [AssociatedObject](https://github.com/p-x9/AssociatedObject) — which routes through
[swift-object-association](https://github.com/p-x9/swift-object-association) on
non-Objective-C platforms — and, for `MachOReading`, [swift-fileio](https://github.com/p-x9/swift-fileio),
which MachOKit depends on already. `InProcessContext` reads this process's own Mach-O images, so
it exists on Darwin only, as do the parts of `MachOCodeReferences` that read this
process (`CodeImageSet.inProcess`, `InProcessCrossReferenceMemory`); its file mode is
platform-neutral, though it has not been built on Linux. `CPlusPlusSymbols` compiles C++17 and
links the C++ standard library; it has not been built on Linux either.

## License

MachOKitExtensions is released under the MIT License. See [LICENSE](LICENSE).

`Sources/CPlusPlusDemangling/ItaniumDemangle` holds LLVM's Itanium demangler, copied unchanged
from libc++abi, and `Sources/CPlusPlusDemangling/CPlusPlusDemangling.cpp` holds two short excerpts
of libc++abi's `cxa_demangle.cpp`. They are part of the LLVM Project, under the Apache License
v2.0 with LLVM Exceptions. See
[Sources/CPlusPlusDemangling/ItaniumDemangle/LICENSE.TXT](Sources/CPlusPlusDemangling/ItaniumDemangle/LICENSE.TXT).
