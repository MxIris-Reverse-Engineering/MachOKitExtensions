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
///
/// Every file read from one cache shares one table, through ``table(for:)``.
/// `FullDyldCache.subCaches` builds a new `DyldCache` for every sub-cache each
/// time it is read, so a table per file held a copy of all of them per image:
/// 1,867 images read from the macOS 27 cache kept 165,689 `DyldCache` objects,
/// about 250 MB.
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

extension DyldCacheSubCacheTable {
    /// The table of the cache whose main file `mainCache` is, shared by every
    /// file read from that cache for as long as one of them keeps it.
    ///
    /// The first file to ask builds it from what its own main cache can hand
    /// over: the sub-caches of its `FullDyldCache`, or the main file alone.
    /// Either serves every other file of the cache, since both read the same
    /// bytes.
    static func table(for mainCache: DyldCache) -> DyldCacheSubCacheTable {
        registry.table(for: mainCache)
    }

    private static let registry = Registry()

    /// A dyld cache as its main file identifies it: the file's path and the
    /// UUID its header records, so a cache rebuilt at the same path is another
    /// cache.
    private struct CacheIdentity: Hashable {
        let mainCachePath: String
        let uuid: UUID

        init(mainCache: DyldCache) {
            self.mainCachePath = mainCache.url.standardizedFileURL.path
            self.uuid = mainCache.header.uuid
        }
    }

    /// The table of every cache some file still keeps one for.
    ///
    /// Tables are held weakly: the files that use a table keep it alive, and
    /// with it the cache's sub-caches and their open files. Held here, they
    /// would keep the sub-cache files of every cache a process ever read open
    /// for the rest of the process.
    private final class Registry: @unchecked Sendable {
        private struct Entry {
            weak var table: DyldCacheSubCacheTable?
        }

        private let lock = NSLock()
        private var entriesByCacheIdentity: [CacheIdentity: Entry] = [:]

        func table(for mainCache: DyldCache) -> DyldCacheSubCacheTable {
            let cacheIdentity = CacheIdentity(mainCache: mainCache)
            lock.lock()
            if let table = entriesByCacheIdentity[cacheIdentity]?.table {
                lock.unlock()
                return table
            }
            lock.unlock()

            // Built outside the lock: from the main file alone it opens every
            // sub-cache file to read its mappings, and lookups in other caches
            // need not wait for that. When two threads race, the first table
            // stored is the one both return.
            let builtTable = DyldCacheSubCacheTable(mainCache: mainCache)

            lock.lock()
            defer { lock.unlock() }
            if let table = entriesByCacheIdentity[cacheIdentity]?.table {
                return table
            }
            // Entries whose table is gone are dropped as new ones arrive, so
            // the registry grows with the caches in use at once, not with every
            // cache the process has read.
            entriesByCacheIdentity = entriesByCacheIdentity.filter { $0.value.table != nil }
            entriesByCacheIdentity[cacheIdentity] = Entry(table: builtTable)
            return builtTable
        }
    }
}
