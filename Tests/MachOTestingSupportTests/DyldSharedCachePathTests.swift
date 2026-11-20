import Foundation
import Testing
import MachOKit
import MachOFixtureSupport

/// `DyldSharedCachePath` builds an archived cache's path and label from its
/// version, and finds the running system's cache where the system says it is.
@Suite
struct DyldSharedCachePathTests {
    @Test("A version names the cache file in that version's directory on the volume, and labels it")
    func archivedCachePathsKeepTheirLayout() {
        let internalBuild = DyldSharedCachePath.macOS("14.0(Internal)")
        #expect(internalBuild.path == "/Volumes/DyldSharedCaches/macOS/14.0(Internal)/dyld_shared_cache_arm64e")
        #expect(internalBuild.versionLabel == "14.0(Internal)")

        let device = DyldSharedCachePath.iOS("27.0")
        #expect(device.path == "/Volumes/DyldSharedCaches/iOS/27.0/dyld_shared_cache_arm64e")
        #expect(device.versionLabel == "27.0")
        #expect(device.url == URL(fileURLWithPath: device.path))
    }

    /// MachOKit asks dyld for the path; `current` must land on the same file
    /// rather than on a location spelled out in the source.
    @Test("The current cache is the file the system says it runs")
    func currentCachePathIsTheOneTheSystemLocates() throws {
        let systemPath = try #require(DyldCache.host?.url.path, "this system exposes no dyld shared cache file")
        #expect(DyldSharedCachePath.current.path == systemPath)
        #expect(DyldSharedCachePath.current.versionLabel == "current")
    }
}
