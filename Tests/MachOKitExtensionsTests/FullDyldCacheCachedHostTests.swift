#if canImport(Darwin)
import Testing
import MachOKit
import MachOKitExtensions

struct FullDyldCacheCachedHostTests {
    @Test("cachedHost opens the cache host opens")
    func cachedHostOpensTheHostCache() throws {
        let host = try #require(FullDyldCache.host)
        #expect(FullDyldCache.cachedHost?.url == host.url)
    }

    @Test("cachedHost hands back one cache for the whole process")
    func cachedHostIsOpenedOnce() throws {
        let firstRead = try #require(FullDyldCache.cachedHost)
        let secondRead = try #require(FullDyldCache.cachedHost)
        #expect(firstRead === secondRead)
    }
}
#endif
