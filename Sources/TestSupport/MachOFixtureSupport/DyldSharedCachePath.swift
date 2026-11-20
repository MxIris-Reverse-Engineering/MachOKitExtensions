import Foundation
import MachOKit
import MachOKitExtensions

/// A dyld shared cache file the tests open, and what a version axis calls it.
///
/// A struct with static members rather than an enum, so that besides the
/// caches named here any archived cache can be named by its version —
/// `.macOS("26.6")` — and a package can add its own with an extension.
public struct DyldSharedCachePath: Hashable, Sendable, CustomStringConvertible {
    /// The cache's main file.
    public let path: String

    /// What a version axis calls this cache: the version an archived cache was
    /// named by, or the label a named cache states. Not necessarily a system
    /// version — ``current`` is labeled `current`.
    public let versionLabel: String

    public init(path: String, versionLabel: String) {
        self.path = path
        self.versionLabel = versionLabel
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    public var description: String {
        path
    }

    /// The running system's cache, where the system locates it, labeled
    /// `current`.
    ///
    /// The path comes from the cache this process opens once
    /// (`FullDyldCache.cachedHost`) rather than from a spelled-out location:
    /// the cache moved into the Cryptexes volume once and may move again. Empty
    /// where the system exposes no shared cache file, so opening it fails.
    public static var current: DyldSharedCachePath {
        DyldSharedCachePath(path: FullDyldCache.cachedHost?.url.path ?? "", versionLabel: "current")
    }

    /// The archived macOS cache of `version`, labeled `version`:
    /// `/Volumes/DyldSharedCaches/macOS/<version>/dyld_shared_cache_arm64e`.
    ///
    /// `version` is the directory name on the volume (`26.5.2`,
    /// `14.0(Internal)`). Whether that directory holds a cache is the caller's
    /// to check; some hold only exported headers.
    public static func macOS(_ version: String) -> DyldSharedCachePath {
        archived(platformDirectoryName: "macOS", version: version)
    }

    /// The archived iOS device cache of `version`, labeled `version`:
    /// `/Volumes/DyldSharedCaches/iOS/<version>/dyld_shared_cache_arm64e`.
    public static func iOS(_ version: String) -> DyldSharedCachePath {
        archived(platformDirectoryName: "iOS", version: version)
    }

    /// Where the archived caches live: one directory per platform, one per
    /// version below it.
    public static let archiveRootPath = "/Volumes/DyldSharedCaches"

    private static func archived(platformDirectoryName: String, version: String) -> DyldSharedCachePath {
        DyldSharedCachePath(
            path: "\(archiveRootPath)/\(platformDirectoryName)/\(version)/dyld_shared_cache_arm64e",
            versionLabel: version
        )
    }
}
