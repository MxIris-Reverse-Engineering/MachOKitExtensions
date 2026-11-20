import Foundation
@_spi(Support) import MachOKit

extension DyldCache {
    /// Every sub-cache file of this main cache as a `DyldCache`, in the order
    /// the main cache header lists them. Call it on the main cache: a
    /// sub-cache header lists no sub-caches.
    ///
    /// A cache opened through `FullDyldCache` hands all of them over in one
    /// pass. Asking MachOKit's `DyldSubCacheEntry.subcache(for:)` once per
    /// entry instead assembles every sub-cache of the full cache to return
    /// one, so walking the entries that way built up to the square of the
    /// sub-cache count — some 6,400 caches for the 80 files of macOS 27. A
    /// cache opened from its main file alone has no full cache to take them
    /// from; each sub-cache file is opened when the sequence reaches it.
    var subCacheFiles: AnySequence<DyldCache> {
        if let fullCache = _cachedFullCache {
            return AnySequence(fullCache.subCaches)
        }
        guard let subCacheEntries = subCaches else {
            return AnySequence([])
        }
        return AnySequence(subCacheEntries.lazy.compactMap { try? $0.subcache(for: self) })
    }
}
