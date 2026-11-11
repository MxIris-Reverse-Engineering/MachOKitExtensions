#if canImport(Darwin)
import Foundation
import Testing
@_spi(Support) import MachOKit
import MachOKitExtensions
import MachOReading

/// A `MachOFile` is read through the mapping MachOKit made when it opened the
/// file (`fileBytes`), which every value assembled from that opening shares
/// (MachOSwiftSection's proposal `machofile-performance`, made before the
/// reading layer moved into this package).
///
/// MachOKit hands out a new `DyldCache` for every image a `FullDyldCache`
/// enumerates, this package another for every sub-cache an image's reads
/// cross into, and a dependency locator makes a `MachOFile` of its own for
/// every image it locates. Mapped once per instance, a cache file was mapped
/// again for each of them, and each mapping held a descriptor until a process
/// reading many images ran out of them. The reading layer now reads
/// MachOKit's mapping, so it maps nothing and holds no descriptor of its own.
///
/// The test that reads several hundred Swift images of the host's cache under
/// an XPC service's descriptor limit stayed in MachOSwiftSection: it reads
/// them through MachOSwiftSection's metadata.
@Suite
struct FileMappingTests {
    private static var hostCacheURL: URL? {
        DyldCache.host?.url
    }

    /// Images of one cache file, their cache instances and the sub-cache
    /// instance another image's read crosses into the file through all read
    /// one mapping.
    @Test(.enabled(if: hostCacheURL != nil))
    func readersOfOneCacheFileShareOneMapping() throws {
        let cache = try FullDyldCache(url: try #require(Self.hostCacheURL))
        let images = Array(cache.machOFiles())
        let imagesByFile = Dictionary(grouping: images, by: \.url.path)
        let (filePath, imagesOfOneFile) = try #require(imagesByFile.first { $0.key != cache.url.path && $0.value.count >= 2 })
        let firstImage = imagesOfOneFile[0]
        let secondImage = imagesOfOneFile[1]
        let firstImageCache = try #require(firstImage.cache)
        let secondImageCache = try #require(secondImage.cache)
        // What makes the sharing necessary: MachOKit gives each image a cache
        // instance of its own.
        try #require(firstImageCache !== secondImageCache)

        // Another image's read of the first image's header crosses into the
        // first image's file through a sub-cache instance of its own.
        let otherImage = try #require(images.first { $0.url.path != filePath && $0.url.path != cache.url.path })
        let headerAddress = try #require(cache.imageInfos?.first { $0.path(in: cache) == firstImage.imagePath }?.address)
        let (crossedCache, _) = try #require(otherImage.cacheAndFileOffset(for: headerAddress))

        let mappingStart = try #require(firstImage.fileBytes.baseAddress)
        #expect(secondImage.fileBytes.baseAddress == mappingStart)
        #expect(firstImageCache.fileBytes.baseAddress == mappingStart)
        #expect(secondImageCache.fileBytes.baseAddress == mappingStart)
        #expect(crossedCache.fileBytes.baseAddress == mappingStart)
    }

    /// A read never goes back to the file's path: removed after it was
    /// opened, the file still reads through the mapping made when it was
    /// opened.
    @Test func aRemovedFileStillReadsThroughTheMappingMadeWhenItWasOpened() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileMappingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let copyURL = temporaryDirectory.appendingPathComponent("dyld")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/lib/dyld"), to: copyURL)
        let machOFile = try #require(try Self.firstMachOFile(at: copyURL))
        try FileManager.default.removeItem(at: copyURL)

        let magic: UInt32 = try machOFile.readElement(offset: 0)
        #expect(magic == machOFile.header.magic?.rawValue)
    }

    /// A read outside the file throws rather than reading past the mapping.
    @Test func aReadPastTheEndOfTheFileThrows() throws {
        let machOFile = try #require(try Self.firstMachOFile(at: URL(fileURLWithPath: "/usr/lib/dyld")))
        let pastTheEnd = machOFile.fileBytes.count - machOFile.headerStartOffset
        #expect(throws: (any Error).self) {
            let _: UInt64 = try machOFile.readElement(offset: pastTheEnd - 4)
        }
        #expect(throws: (any Error).self) {
            let _: [UInt32] = try machOFile.readElements(offset: pastTheEnd - 8, numberOfElements: 4)
        }
        #expect(throws: (any Error).self) {
            _ = try machOFile.readString(offset: pastTheEnd + 1)
        }
    }

    private static func firstMachOFile(at url: URL) throws -> MachOFile? {
        switch try MachOKit.loadFromFile(url: url) {
        case .machO(let machOFile):
            return machOFile
        case .fat(let fatFile):
            return try fatFile.machOFiles().first
        }
    }
}
#endif
