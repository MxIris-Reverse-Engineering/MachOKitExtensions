#if canImport(Darwin)
import Testing
import MachOKit
import MachOKitExtensions

struct DyldCacheLoadedCachedTests {
    @Test("cachedCurrent is the mapping current reports")
    func cachedCurrentMatchesCurrent() throws {
        let current = try #require(DyldCacheLoaded.current)
        #expect(DyldCacheLoaded.cachedCurrent?.ptr == current.ptr)
    }

    @Test("headerInfo(at:in:) returns the entry headerInfos(in:) lists at that index")
    func headerInfoMatchesHeaderInfos() throws {
        let cache = try #require(DyldCacheLoaded.current)
        let headerOptimization = try #require(cache.objcOptimization?.headerOptimizationRO64(in: cache))
        let headerInfos = Array(headerOptimization.headerInfos(in: cache))
        try #require(!headerInfos.isEmpty)
        let mismatchedIndices = headerInfos.indices.filter { index in
            let cachedHeaderInfo = cache.cached.headerInfo(at: index, in: headerOptimization)
            return cachedHeaderInfo?.offset != headerInfos[index].offset
                || cachedHeaderInfo?.index != headerInfos[index].index
        }
        #expect(mismatchedIndices.isEmpty)
    }

    @Test("headerInfo(at:in:) is nil outside the list")
    func headerInfoOutsideTheListIsNil() throws {
        let cache = try #require(DyldCacheLoaded.current)
        let headerOptimization = try #require(cache.objcOptimization?.headerOptimizationRO64(in: cache))
        #expect(cache.cached.headerInfo(at: -1, in: headerOptimization) == nil)
        #expect(cache.cached.headerInfo(at: headerOptimization.count, in: headerOptimization) == nil)
    }
}
#endif
