import Foundation
import MachOKit
import AssociatedObject

public protocol MachORepresentableWithCache: MachORepresentable, Sendable {
    associatedtype Cache: DyldCacheRepresentable
    associatedtype Identifier: Hashable

    var imagePath: String { get }
    var identifier: Identifier { get }
    var cache: Cache? { get }
    var startOffset: Int { get }
    func resolveOffset(at address: UInt64) -> Int
}

public enum MachOTargetIdentifier: Hashable {
    case image(UnsafeRawPointer)
    case file(String)
    /// A file-backed image keyed additionally by its `LC_UUID`. The same install
    /// path can back *different* binaries — the SwiftUI image of two simulator
    /// runtimes lives at `/System/.../SwiftUI` in both — so keying on the path
    /// alone collides in `SharedCache`-backed per-image caches (the symbol
    /// index, …), letting the second-indexed binary read the first's data. The
    /// linker-assigned UUID is unique per build, so it keeps the keys apart.
    /// Preferred over ``versionedFile`` because two consecutive OS builds can
    /// share the same platform and SDK. An image read from a dyld shared cache
    /// is keyed by ``dyldCacheImage`` instead.
    case uuidFile(path: String, uuid: UUID)
    /// A file-backed image keyed additionally by its `LC_BUILD_VERSION`
    /// (platform + SDK). Fallback for binaries that have no `LC_UUID` load
    /// command; weaker than ``uuidFile`` since two OS builds can report the same
    /// platform and SDK.
    case versionedFile(path: String, platform: UInt32, sdk: UInt32)
    /// An image read from a dyld shared cache, keyed additionally by the UUID
    /// of the cache it was read from. `LC_UUID` cannot tell two caches' copies
    /// of one build apart — SwiftUI is the same binary, UUID included, in the
    /// macOS 13.5 and 13.6 caches — yet each cache places it at its own
    /// addresses, and every offset read through the image belongs to that
    /// cache. Keyed by ``uuidFile``, the two copies shared their per-image
    /// caches, and the copy read second followed the first one's class object
    /// offsets into its own cache. `cacheUUID` is the main cache's, so an image
    /// keeps one identity whether its cache was opened as the main file alone
    /// or with every subcache.
    case dyldCacheImage(path: String, uuid: UUID?, cacheUUID: UUID)
}

extension MachOFile {
    public func resolveOffset(at address: UInt64) -> Int {
        if let offset = fileOffset(of: address) {
            return offset.cast()
        } else {
            return stripPointerTags(of: address).cast()
        }
    }
}

extension MachOImage {
    public func resolveOffset(at address: UInt64) -> Int {
        Int(stripPointerTags(of: address)) - Int(bitPattern: ptr)
    }
}

extension MachOFile: MachORepresentableWithCache, @unchecked @retroactive Sendable {
    /// Guards the one store of ``identifier``'s value.
    private static let identifierStoreLock = NSLock()

    @AssociatedObject(.retain(.nonatomic))
    private var storedIdentifier: MachOTargetIdentifier?

    /// Computed on the first read and stored once for this `MachOFile`
    /// instance.
    ///
    /// Every `SharedCache` lookup reads it, so every read after the first is
    /// one lock-free association lookup. That is safe because the value is
    /// stored once, under a lock, and never replaced: the association's
    /// nonatomic getter hands it out unretained, and nothing releases it while
    /// the file lives. Stored without the lock, threads racing on a fresh file
    /// each stored their own value, and one reader could be handed a value
    /// another's store had just released — on arm64e the isa check traps.
    public var identifier: MachOTargetIdentifier {
        if let storedIdentifier {
            return storedIdentifier
        }
        let computedIdentifier = makeIdentifier()
        Self.identifierStoreLock.lock()
        defer { Self.identifierStoreLock.unlock() }
        if let storedIdentifier {
            return storedIdentifier
        }
        storedIdentifier = computedIdentifier
        return computedIdentifier
    }

    /// Reads the load commands **once** and derives the cache identity from the
    /// strongest discriminator available: for an image read from a dyld shared
    /// cache, the cache it was read from plus its `LC_UUID`; otherwise
    /// `LC_UUID` (unique per build), then `LC_BUILD_VERSION` (platform + SDK),
    /// then the bare install path. The result is stored by ``identifier``
    /// because it is read on every `SharedCache` lookup and `loadCommands`
    /// performs file I/O.
    private func makeIdentifier() -> MachOTargetIdentifier {
        let loadCommands = loadCommands
        let uuid = loadCommands.info(of: LoadCommand.uuid)?.uuid
        if let cache {
            return .dyldCacheImage(path: imagePath, uuid: uuid, cacheUUID: cache.mainCacheHeader.uuid)
        }
        if let uuid {
            return .uuidFile(path: imagePath, uuid: uuid)
        }
        if let buildVersionCommand = loadCommands.buildVersionCommand {
            return .versionedFile(path: imagePath, platform: buildVersionCommand.layout.platform, sdk: buildVersionCommand.layout.sdk)
        }
        return .file(imagePath)
    }

    public var startOffset: Int {
        if let cache {
            headerStartOffsetInCache + cache.fileStartOffset.cast()
        } else {
            headerStartOffset
        }
    }
}

extension MachOImage: MachORepresentableWithCache, @unchecked @retroactive Sendable {
    public var imagePath: String {
        path ?? ""
    }

    public var identifier: MachOTargetIdentifier {
        .image(ptr)
    }

    public var cache: DyldCacheLoaded? {
        // The cache builder flags every image it links into the cache. The load
        // address is no evidence either way: an image outside the cache that is
        // loaded once the process has mapped enough memory sits above
        // `sharedRegionStart` too.
        guard header.isInDyldCache else { return nil }
        return DyldCacheLoaded.cachedCurrent
    }

    public var startOffset: Int {
        if let cache {
            return cache.mainCacheHeader.sharedRegionStart.cast()
        } else {
            return 0
        }
    }
}

extension MachORepresentableWithCache {
    public func address(forOffset offset: Int) -> UInt64 {
        if let machOImage = asMachOImage, let cache = machOImage.cache, let slide = cache.slide {
            let startOffset = Int(bitPattern: machOImage.ptr) - slide
            return .init(startOffset + offset)
        } else if let cache {
            return .init(cache.mainCacheHeader.sharedRegionStart.cast() + offset)
        } else {
            return UInt64((loadCommands.text64?.virtualMemoryAddress ?? loadCommands.text?.virtualMemoryAddress) ?? 0) + UInt64(offset)
        }
    }

    public func addressString(forOffset offset: Int) -> String {
        String(address(forOffset: offset), radix: 16, uppercase: true)
    }
}
