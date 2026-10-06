#if canImport(Darwin)
import Foundation
import Testing
import MachOKit
import MachOKitExtensions

/// The host's dyld cache, opened the two ways MachOKit offers.
enum HostDyldCacheLoading: String, CaseIterable, CustomTestStringConvertible {
    /// Every file of the cache at once, through `FullDyldCache`.
    case fullCache
    /// The main file alone, each sub-cache opened when something reaches it.
    case mainFileOnly

    var testDescription: String { rawValue }

    func image(atPath imagePath: String, inCacheAt url: URL) throws -> MachOFile? {
        switch self {
        case .fullCache:
            try FullDyldCache(url: url).machOFile(by: .path(imagePath))
        case .mainFileOnly:
            try DyldCache(url: url).machOFile(by: .path(imagePath))
        }
    }
}

/// Two images of the host's dyld cache whose headers sit in two different
/// sub-cache files, neither of them the main file: a lookup from the first
/// image to the second one's header has to cross into another sub-cache.
/// Where that header lives is taken from `FullDyldCache`'s own lookup, which
/// knows every file of the cache.
struct CrossSubCacheProbe: Sendable {
    let cacheURL: URL
    let imagePath: String
    let targetAddress: UInt64
    let targetFileURL: URL
    let targetFileOffset: UInt64

    static let host: CrossSubCacheProbe? = try? make()

    private static func make() throws -> CrossSubCacheProbe? {
        guard let cacheURL = DyldCache.host?.url else { return nil }
        let fullCache = try FullDyldCache(url: cacheURL)
        guard let imageInfos = fullCache.imageInfos else { return nil }
        var firstImage: (path: String, fileURL: URL)?
        for imageInfo in imageInfos {
            guard let imagePath = imageInfo.path(in: fullCache),
                  let (cache, fileOffset) = fullCache.cacheAndFileOffset(for: imageInfo.address),
                  cache.url != fullCache.url else {
                continue
            }
            guard let firstImage else {
                firstImage = (imagePath, cache.url)
                continue
            }
            if cache.url != firstImage.fileURL {
                return CrossSubCacheProbe(
                    cacheURL: cacheURL,
                    imagePath: firstImage.path,
                    targetAddress: imageInfo.address,
                    targetFileURL: cache.url,
                    targetFileOffset: fileOffset
                )
            }
        }
        return nil
    }
}

@Suite(.enabled(if: CrossSubCacheProbe.host != nil, "needs a host dyld cache that spreads its images over several sub-cache files"))
struct DyldCacheSubCacheLookupTests {
    @Test("an address in another sub-cache resolves to the file and offset the full cache maps it to", arguments: HostDyldCacheLoading.allCases)
    func anAddressInAnotherSubCacheResolvesToItsFile(loading: HostDyldCacheLoading) throws {
        let probe = try #require(CrossSubCacheProbe.host)
        let image = try #require(try loading.image(atPath: probe.imagePath, inCacheAt: probe.cacheURL))

        let (cache, fileOffset) = try #require(image.cacheAndFileOffset(for: probe.targetAddress))

        #expect(cache.url == probe.targetFileURL)
        #expect(fileOffset == probe.targetFileOffset)
    }

    /// A lookup that crossed into another sub-cache used to build that
    /// sub-cache afresh every time — through `FullDyldCache`, together with all
    /// of its siblings — so whatever a reader had cached on the instance it got
    /// last time was gone, and every read of another image's bytes started over.
    @Test("repeated lookups into another sub-cache hand back the same cache", arguments: HostDyldCacheLoading.allCases)
    func repeatedLookupsShareOneSubCache(loading: HostDyldCacheLoading) throws {
        let probe = try #require(CrossSubCacheProbe.host)
        let image = try #require(try loading.image(atPath: probe.imagePath, inCacheAt: probe.cacheURL))

        let firstLookup = try #require(image.cacheAndFileOffset(for: probe.targetAddress))
        let secondLookup = try #require(image.cacheAndFileOffset(for: probe.targetAddress))

        #expect(firstLookup.0 === secondLookup.0)
    }
}
#endif
