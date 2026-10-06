import Foundation
@_spi(Support) import MachOKit

/// Which sub-cache file of a dyld cache maps an address, with each sub-cache
/// built at most once.
///
/// The table holds the mapping ranges of every sub-cache, so a lookup is one
/// binary search rather than a walk over the sub-caches, and the sub-cache it
/// lands in comes back as the same instance every time. A cache opened through
/// `FullDyldCache` hands its sub-caches over up front; they share the full
/// cache's open files. A cache opened from its main file alone has to open
/// each sub-cache file to read its mappings, and closes it again: only the
/// sub-caches a lookup lands in stay open, instead of all 80 files of a macOS 27
/// cache for every image read from it.
final class DyldCacheSubCacheTable: @unchecked Sendable {
    private struct MappedRange {
        let address: UInt64
        let size: UInt64
        let fileOffset: UInt64
        let subCacheIndex: Int
    }

    private let mainCache: DyldCache
    private let subCacheEntries: [DyldSubCacheEntry]
    /// Sorted by address. Ranges of different files never overlap.
    private let mappedRanges: [MappedRange]
    private let lock = NSLock()
    private var subCaches: [DyldCache?]

    init(mainCache: DyldCache) {
        let subCacheEntries = mainCache.subCaches.map { Array($0) } ?? []
        var subCaches: [DyldCache?] = Array(repeating: nil, count: subCacheEntries.count)
        if let fullCache = mainCache._cachedFullCache {
            let fullCacheSubCaches: [DyldCache] = fullCache.subCaches
            if fullCacheSubCaches.count == subCacheEntries.count {
                subCaches = fullCacheSubCaches
            }
        }

        var mappedRanges: [MappedRange] = []
        for subCacheIndex in subCacheEntries.indices {
            // A sub-cache opened here only to read its mappings closes its
            // file again when this iteration lets go of it.
            let subCache = subCaches[subCacheIndex] ?? (try? subCacheEntries[subCacheIndex].subcache(for: mainCache))
            for mappingInfo in subCache?.mappingInfos ?? [] {
                mappedRanges.append(MappedRange(
                    address: mappingInfo.address,
                    size: mappingInfo.size,
                    fileOffset: mappingInfo.fileOffset,
                    subCacheIndex: subCacheIndex
                ))
            }
        }

        self.mainCache = mainCache
        self.subCacheEntries = subCacheEntries
        self.mappedRanges = mappedRanges.sorted { $0.address < $1.address }
        self.subCaches = subCaches
    }

    /// The sub-cache that maps `address` and the file offset it maps it to, as
    /// `DyldCacheRepresentable.fileOffset(of:)` computes it from the same
    /// mapping.
    func cacheAndFileOffset(for address: UInt64) -> (DyldCache, UInt64)? {
        // The last range starting at or below the address is the only one
        // that can contain it.
        var lowerBound = mappedRanges.startIndex
        var upperBound = mappedRanges.endIndex
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if mappedRanges[middle].address <= address {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound > mappedRanges.startIndex else { return nil }
        let mappedRange = mappedRanges[lowerBound - 1]
        guard address - mappedRange.address < mappedRange.size,
              let subCache = subCache(at: mappedRange.subCacheIndex) else {
            return nil
        }
        return (subCache, address - mappedRange.address + mappedRange.fileOffset)
    }

    private func subCache(at subCacheIndex: Int) -> DyldCache? {
        lock.lock()
        if let subCache = subCaches[subCacheIndex] {
            lock.unlock()
            return subCache
        }
        lock.unlock()

        // Opened outside the lock; when two threads race, the first one
        // stored is the one both return.
        guard let openedSubCache = try? subCacheEntries[subCacheIndex].subcache(for: mainCache) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        if let subCache = subCaches[subCacheIndex] {
            return subCache
        }
        subCaches[subCacheIndex] = openedSubCache
        return openedSubCache
    }
}
