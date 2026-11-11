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

Since 2.0.0 the package also carries MachOSwiftSection's reading layer, `MachOReading` and
`MachOResolving`, as products of their own, so that a package can read typed values out of a
Mach-O without depending on MachOSwiftSection. MachOKitUI with its `SwiftSection` trait off is the
first such package.

## Products

| Product | What it is |
|---|---|
| `MachOKitExtensions` | The extensions on MachOKit's types listed below |
| `MachOReading` | Reading typed values out of a file, a loaded image or this process's memory: `Readable` (conformed to by `MachOFile`, `MachOImage` and `UnsafeRawPointer`), and `ReadingContext` with `MachOContext` (addresses are offsets in a file or image) and `InProcessContext` (addresses are pointers in this process; Darwin only) |
| `MachOResolving` | `Resolvable`, a value read at an address, and `SymbolOrElement`, which names the symbol dyld binds at an address instead of reading what is not there; the `Symbol` and `Symbols` value types |

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
.package(url: "https://github.com/MxIris-Reverse-Engineering/MachOKitExtensions", from: "2.0.0")
```

```swift
.product(name: "MachOKitExtensions", package: "MachOKitExtensions"),
.product(name: "MachOReading", package: "MachOKitExtensions"),
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

2.0.0 adds the `MachOReading` and `MachOResolving` products and changes nothing in the
`MachOKitExtensions` module. It is a major version because MachOSwiftSection 0.24 and earlier
declare modules of those same names, and SwiftPM refuses a package graph with two modules of one
name: a `from: "1.x"` requirement keeps such a MachOSwiftSection from ever resolving together
with this release.

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
it exists on Darwin only.

## License

MachOKitExtensions is released under the MIT License. See [LICENSE](LICENSE).
