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

## What it provides

| Area | Highlights |
|---|---|
| Address arithmetic | `address(forOffset:)`, `addressString(forOffset:)`, `resolveOffset(at:)` |
| Pointer tagging | `stripPointerTags(of:)` and the architecture-specific `vmaddrMask` |
| Dyld shared cache | `cache(for:)`, `cacheAndFileOffset(for:)`, `cacheAndFileOffset(fromStart:)`, `machOFile(by:)` |
| Bind / rebase | `resolveRebase(fileOffset:)`, `resolveBind(fileOffset:)`, `isBind(fileOffset:)` |
| Cached views | `machOFile.cached` memoizes chained fixups behind the same `resolveRebase(at:)` / `resolveOptionalRebase(at:)` / `resolveBind(at:)` API; `DyldCacheLoaded.cachedCurrent`; `cache.cached.headerInfo(at:in:)` |
| Load commands | Typed accessors for `__TEXT`, `__DATA`, `__DATA_CONST`, `__AUTH`, `__AUTH_CONST`, build version |
| Protocols | `MachORepresentableWithCache`, `LocatableLayoutWrapper`, `MachOTargetIdentifier` |

## Usage

```swift
.package(url: "https://github.com/MxIris-Reverse-Engineering/MachOKitExtensions", from: "1.0.0")
```

```swift
import MachOKit
import MachOKitExtensions

let machOFile: MachOFile = // …
// Turn a file offset into the address it will have once loaded.
let address = machOFile.addressString(forOffset: 0x1000)
```

## Platforms

macOS 10.15+, iOS 13+, watchOS 6+, tvOS 13+, visionOS 1+, and Linux.

Linux support matters here because MachOObjCSection supports Linux, and it would have regressed
had this package pulled in Apple-only dependencies. The package therefore depends only on
MachOKit and [AssociatedObject](https://github.com/p-x9/AssociatedObject) — the latter routes
through [swift-object-association](https://github.com/p-x9/swift-object-association) on
non-Objective-C platforms.

## License

MachOKitExtensions is released under the MIT License. See [LICENSE](LICENSE).
