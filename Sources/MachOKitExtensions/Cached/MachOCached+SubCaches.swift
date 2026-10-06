import MachOKit

extension MachOCached where Base == MachOFile {
    /// Where the sub-caches of the dyld cache this file was read from map
    /// their addresses, built on first use; `nil` for a file not read from a
    /// dyld cache.
    ///
    /// Building the sub-caches per address lookup made every read of another
    /// image's bytes start from a fresh cache: through `FullDyldCache` that
    /// meant assembling all of its sub-caches again, from the main file alone
    /// it meant opening the file again, and either way whatever a reader kept
    /// on the instance it got last time was gone.
    var subCacheTable: DyldCacheSubCacheTable? {
        storage.memoized(\.subCacheTable) {
            guard let mainCache = base.cache?.mainCache else { return nil }
            return DyldCacheSubCacheTable(mainCache: mainCache)
        }
    }
}
