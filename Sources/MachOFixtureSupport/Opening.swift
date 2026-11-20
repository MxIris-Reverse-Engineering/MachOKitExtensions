import Foundation
import MachOKit
import MachOKitExtensions

/// The file named `fileName`, as MachOKit reads it: one Mach-O or a fat file.
/// A bundle is read through its executable.
public func loadFromFile(named fileName: MachOFileName) throws -> File {
    try File.loadFromFile(url: fileName.url)
}

extension MachOImage {
    /// The image named `imageName` if this process has loaded it.
    public init?(named imageName: MachOImageName) {
        self.init(name: imageName.name)
    }
}

extension FullDyldCache {
    /// A new instance over the cache at `path`. ``DyldSharedCachePath/current``
    /// is better read through `FullDyldCache.cachedHost`, which the process
    /// opens once.
    public convenience init(path: DyldSharedCachePath) throws {
        try self.init(url: path.url)
    }

    public func machOFile(named imageName: MachOImageName) -> MachOFile? {
        machOFile(by: .name(imageName.name))
    }
}

extension DyldCache {
    /// A new instance over the main file of the cache at `path`.
    public convenience init(path: DyldSharedCachePath) throws {
        try self.init(url: path.url)
    }

    public func machOFile(named imageName: MachOImageName) -> MachOFile? {
        machOFile(by: .name(imageName.name))
    }
}
