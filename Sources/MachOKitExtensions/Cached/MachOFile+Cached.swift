import Foundation
import MachOKit
import AssociatedObject

extension MachOFile {
    /// A concurrency-safe view over this file that memoizes expensive parsing
    /// results.
    ///
    /// The cache is attached to this `MachOFile` instance and released with
    /// it; a new `MachOFile` for the same file starts with an empty cache.
    public var cached: MachOCached<MachOFile> {
        MachOCached(base: self, storage: cacheStorage)
    }

    // `.atomic` makes the getter retain the storage before returning it, so a
    // concurrent reader never sees it half-published.
    @AssociatedObject(.retain(.atomic))
    private var _cacheStorage: MachOCacheStorage<MachOFile>?

    private static let cacheStorageCreationLock = NSLock()

    private var cacheStorage: MachOCacheStorage<MachOFile> {
        if let cacheStorage = _cacheStorage {
            return cacheStorage
        }
        // Serialize creation: two threads that both miss must end up sharing
        // one storage, or one of them would cache into a storage nobody keeps.
        Self.cacheStorageCreationLock.lock()
        defer { Self.cacheStorageCreationLock.unlock() }
        if let cacheStorage = _cacheStorage {
            return cacheStorage
        }
        let cacheStorage = MachOCacheStorage<MachOFile>()
        _cacheStorage = cacheStorage
        return cacheStorage
    }
}
