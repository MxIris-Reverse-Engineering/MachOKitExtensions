import Foundation
import MachOKit
import OSToolbox

/// One opening of each dyld shared cache file that dependency locators search
/// by path, shared by every locator for as long as anything still holds it.
///
/// Each consumer of a dependency closure builds a locator for every root, and
/// a cache named by a `.dyldSharedCache(path:)` search path used to be opened
/// by each of them, all of its files mapped again with a descriptor apiece:
/// DockHelper paired with an archived macOS 27.0 cache held 369 descriptors on
/// that cache's 80 files in one `interface` run.
///
/// An opening is held weakly. The images a locator hands out keep their cache,
/// and through it the opening, alive; once none is left it closes, so a run
/// over dozens of caches keeps only the ones still in use open. Openings are
/// keyed by the file's identity (`DependencyFileIdentity`), so a cache file
/// replaced on disk is opened afresh.
///
/// `FullDyldCache` fills in its mapping tables and symbol cache on first use,
/// without a lock. They are read before an opening is handed out, so every
/// later reader only reads them: what `FullDyldCache.cachedHost` does for the
/// running system's cache.
enum SharedDyldCacheOpenings {
    /// The opening of the dyld shared cache whose main file is at `url`, made
    /// on the first request while no other is alive. Throws what opening the
    /// cache throws.
    static func cache(at url: URL) throws -> FullDyldCache {
        try registry.cache(at: url)
    }

    private static let registry = Registry()

    private final class Registry: Sendable {
        /// One per cache file, created under the registry's lock and filled in
        /// under its own, so a cache being opened holds up only the requests
        /// for that cache — the arrangement of `DyldCacheImageDirectory`'s
        /// registry.
        private final class Slot: Sendable {
            let cache = Mutex(WeakBox<FullDyldCache>())
        }

        private let slotsByFileIdentity = Mutex<[DependencyFileIdentity: Slot]>([:])

        func cache(at url: URL) throws -> FullDyldCache {
            guard let fileIdentity = DependencyFileIdentity(fileAt: url) else {
                return try FullDyldCache(url: url)
            }
            let slot = slotsByFileIdentity.withLock { slotsByFileIdentity in
                if let existingSlot = slotsByFileIdentity[fileIdentity] {
                    return existingSlot
                }
                let slot = Slot()
                slotsByFileIdentity[fileIdentity] = slot
                return slot
            }

            return try slot.cache.withLock { cacheReference in
                if let cache = cacheReference.value {
                    return cache
                }
                let cache = try FullDyldCache(url: url)
                _ = cache.mappingInfos
                _ = cache.mappingAndSlideInfos
                _ = try? cache.symbolCache
                cacheReference.value = cache
                return cache
            }
        }
    }
}
