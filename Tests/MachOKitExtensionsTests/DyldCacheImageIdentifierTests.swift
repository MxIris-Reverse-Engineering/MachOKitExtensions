#if canImport(Darwin)
import Foundation
import Testing
import MachOKit
import MachOKitExtensions

private enum ArchivedCaches {
    static let swiftUIPath = "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI"

    static func url(of version: String) -> URL {
        URL(fileURLWithPath: "/Volumes/DyldSharedCaches/macOS/\(version)/dyld_shared_cache_arm64e")
    }

    static var areAvailable: Bool {
        ["13.5", "13.6"].allSatisfy { FileManager.default.fileExists(atPath: url(of: $0).path) }
    }
}

/// The macOS 13.5 and 13.6 dyld caches carry the same SwiftUI build — the same
/// `LC_UUID` — at different addresses. Keyed by the image alone, the two copies
/// shared their per-image caches downstream, and the copy read second followed
/// the first one's class object offsets into its own cache.
@Suite(.enabled(if: ArchivedCaches.areAvailable, "needs the archived macOS 13.5 and 13.6 dyld caches"))
struct DyldCacheImageIdentifierTests {
    @Test("one build in two caches has two identities")
    func oneBuildInTwoCachesHasTwoIdentities() throws {
        let olderCacheImage = try #require(DyldCache(url: ArchivedCaches.url(of: "13.5")).machOFile(by: .path(ArchivedCaches.swiftUIPath)))
        let newerCacheImage = try #require(DyldCache(url: ArchivedCaches.url(of: "13.6")).machOFile(by: .path(ArchivedCaches.swiftUIPath)))

        let olderUUID = try #require(olderCacheImage.loadCommands.info(of: LoadCommand.uuid)?.uuid)
        let newerUUID = try #require(newerCacheImage.loadCommands.info(of: LoadCommand.uuid)?.uuid)
        try #require(olderUUID == newerUUID, "the premise: both caches carry the same build")

        #expect(olderCacheImage.identifier != newerCacheImage.identifier)
    }

    @Test("an image keeps its identity whether its cache was opened with or without the subcaches")
    func anImageKeepsItsIdentityAcrossLoadingModes() throws {
        let url = ArchivedCaches.url(of: "13.5")
        let mainFileImage = try #require(DyldCache(url: url).machOFile(by: .path(ArchivedCaches.swiftUIPath)))
        let fullCacheImage = try #require(FullDyldCache(url: url).machOFile(by: .path(ArchivedCaches.swiftUIPath)))

        #expect(mainFileImage.identifier == fullCacheImage.identifier)
    }
}
#endif
