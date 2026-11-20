import Foundation
import MachOKit
import AssociatedObject
import OSToolbox

extension MachOFile {
    /// A concurrency-safe view over this file that memoizes expensive parsing
    /// results.
    ///
    /// The cache is attached to this `MachOFile` instance and released with
    /// it; a new `MachOFile` for the same file starts with an empty cache. The
    /// one exception is where the sub-caches of a dyld cache map their
    /// addresses: every file read from that cache shares it, so the sub-caches
    /// `cacheAndFileOffset(for:)` lands in are shared too.
    public var cached: MachOCached<MachOFile> {
        MachOCached(base: self, storage: cacheStorage)
    }

    // `.atomic` makes the getter retain the storage before returning it, so a
    // concurrent reader never sees it half-published.
    @AssociatedObject(.retain(.atomic))
    private var _cacheStorage: MachOCacheStorage<MachOFile>?

    /// Guards no value of its own: what it serializes is the store into
    /// `_cacheStorage`, an association of each file.
    private static let cacheStorageCreationLock = Mutex(())

    private var cacheStorage: MachOCacheStorage<MachOFile> {
        if let cacheStorage = _cacheStorage {
            return cacheStorage
        }
        // Serialize creation: two threads that both miss must end up sharing
        // one storage, or one of them would cache into a storage nobody keeps.
        return Self.cacheStorageCreationLock.withLock { _ in
            if let cacheStorage = _cacheStorage {
                return cacheStorage
            }
            let cacheStorage = MachOCacheStorage<MachOFile>()
            _cacheStorage = cacheStorage
            return cacheStorage
        }
    }
}
