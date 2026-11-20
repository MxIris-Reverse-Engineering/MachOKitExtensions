import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import MachOFixtureSupport

/// A suite that reads one file from disk: the slice of ``fileName`` for this
/// process's CPU. Subclasses override ``fileName``.
@MainActor
open class MachOFileTests: Sendable {
    public let machOFile: MachOFile

    open class var fileName: MachOFileName { .Finder }

    public init() async throws {
        self.machOFile = try HostSlice.machOFile(at: Self.fileName.url)
    }
}

/// A suite that reads one image this process has loaded. Subclasses override
/// ``imageName``.
@MainActor
open class MachOImageTests: Sendable {
    public let machOImage: MachOImage

    open class var imageName: MachOImageName { .Foundation }

    public init() async throws {
        self.machOImage = try #require(MachOImage(named: Self.imageName))
    }
}

/// A suite that reads a file inside Xcode. Subclasses override ``fileName``.
open class XcodeMachOFileTests {
    public let machOFile: MachOFile

    open class var fileName: XcodeMachOFileName { .sharedFrameworks(.DNTDocumentationModel) }

    public init() async throws {
        self.machOFile = try HostSlice.machOFile(at: Self.fileName.url)
    }
}

/// A suite that reads a dyld shared cache: its main file, its first sub-cache,
/// the whole cache, and an image out of each.
///
/// The running system's cache (``DyldSharedCachePath/current``, the default)
/// is the one the process opens once, `FullDyldCache.cachedHost`, so suites
/// share its mapped files instead of each opening all of them again. Any
/// other ``cachePath`` is opened afresh for the suite.
@MainActor
open class DyldCacheTests: Sendable {
    public let mainCache: DyldCache

    public let subCache: DyldCache

    public let fullCache: FullDyldCache

    public let machOFileInMainCache: MachOFile

    public let machOFileInSubCache: MachOFile

    public let machOFileInCache: MachOFile

    open class var platform: MachOKit.Platform { .macOS }

    open class var mainCacheImageName: MachOImageName { .SwiftUI }

    open class var cacheImageName: MachOImageName { .SwiftUI }

    open class var cachePath: DyldSharedCachePath { .current }

    public init() async throws {
        let cachePath = Self.cachePath
        if cachePath == .current {
            self.fullCache = try #require(FullDyldCache.cachedHost, "this system exposes no dyld shared cache file")
            self.mainCache = fullCache.mainCache
        } else {
            self.mainCache = try DyldCache(path: cachePath)
            self.fullCache = try FullDyldCache(path: cachePath)
        }
        self.subCache = try required(mainCache.subCaches?.first?.subcache(for: mainCache))
        self.machOFileInCache = try #require(fullCache.machOFile(named: Self.cacheImageName))
        self.machOFileInMainCache = try #require(mainCache.machOFile(named: Self.mainCacheImageName))
        self.machOFileInSubCache = try #require(subCache.machOFiles().first(where: { _ in true }))
    }
}
