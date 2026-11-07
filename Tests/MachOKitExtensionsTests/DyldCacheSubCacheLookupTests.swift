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

    /// Opens the cache once and returns a reader that makes a new `MachOFile`
    /// on every call, the way an indexer reads one image after another from a
    /// cache it opened once.
    func imageReader(forCacheAt url: URL) throws -> (_ imagePath: String) -> MachOFile? {
        switch self {
        case .fullCache:
            let cache = try FullDyldCache(url: url)
            return { cache.machOFile(by: .path($0)) }
        case .mainFileOnly:
            let cache = try DyldCache(url: url)
            return { cache.machOFile(by: .path($0)) }
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

    /// Each file used to keep a table of its own, so the same lookup from two
    /// files of one cache landed in two copies of the sub-cache. Through
    /// `FullDyldCache` every table held a fresh copy of all of the cache's
    /// sub-caches: a process that read 1,867 images of the macOS 27 cache kept
    /// 165,689 `DyldCache` objects, about 250 MB. The two files here are two
    /// reads of the same image, so the cache is all they have in common.
    @Test("files read from one cache share the sub-cache a lookup lands in", arguments: HostDyldCacheLoading.allCases)
    func filesOfOneCacheShareOneSubCache(loading: HostDyldCacheLoading) throws {
        let probe = try #require(CrossSubCacheProbe.host)
        let readImage = try loading.imageReader(forCacheAt: probe.cacheURL)
        let firstImage = try #require(readImage(probe.imagePath))
        let secondImage = try #require(readImage(probe.imagePath))
        try #require(firstImage !== secondImage, "each read has to make a new MachOFile")

        let firstLookup = try #require(firstImage.cacheAndFileOffset(for: probe.targetAddress))
        let secondLookup = try #require(secondImage.cacheAndFileOffset(for: probe.targetAddress))

        #expect(firstLookup.0 === secondLookup.0)
    }

    /// Whatever shares the sub-caches between files must not keep them once
    /// no file read from the cache is left, or a process reading many caches
    /// one after another would hold the sub-cache files of every one of them.
    /// It runs in a child process: the other tests here read the same cache
    /// at the same time, and any file of theirs keeps the sub-caches alive.
    @Test("a sub-cache is released with the last file read from its cache")
    func subCacheIsReleasedWithTheLastFile() async {
        await #expect(processExitsWith: .success) {
            var everySubCacheWasReleased = true
            for loading in HostDyldCacheLoading.allCases {
                let subCacheOutlivedItsFiles = DyldCacheSubCacheLookupTests.subCacheOutlivesItsFiles(loading: loading)
                #expect(subCacheOutlivedItsFiles == false, "\(loading.rawValue): the sub-cache outlived every file read from its cache")
                everySubCacheWasReleased = everySubCacheWasReleased && subCacheOutlivedItsFiles == false
            }
            exit(everySubCacheWasReleased ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    // MARK: - Exit test bodies

    /// Whether the sub-cache a lookup landed in is still alive once the file
    /// that looked it up, and the cache it was read from, are gone; `nil` when
    /// the lookup could not be made.
    static func subCacheOutlivesItsFiles(loading: HostDyldCacheLoading) -> Bool? {
        guard let probe = CrossSubCacheProbe.host else { return nil }
        weak var landedSubCache: DyldCache?
        var lookupWasMade = false
        // Opening a cache autoreleases; the pool lets go of those references
        // before the check.
        autoreleasepool {
            guard let readImage = try? loading.imageReader(forCacheAt: probe.cacheURL),
                  let image = readImage(probe.imagePath),
                  let (subCache, _) = image.cacheAndFileOffset(for: probe.targetAddress) else {
                return
            }
            landedSubCache = subCache
            lookupWasMade = true
        }
        guard lookupWasMade else { return nil }
        return landedSubCache != nil
    }
}
#endif
