import Foundation
import MachOKit
import MachOKitExtensions

/// An image the class index reads, by how it is stored: a file — standalone
/// or out of a dyld shared cache — or an image of this process.
enum IndexedImage: @unchecked Sendable {
    case file(MachOFile)
    case process(MachOImage)

    init?(_ machO: some MachORepresentableWithCache) {
        if let image = machO.asMachOImage {
            self = .process(image)
        } else if let file = machO.asMachOFile {
            self = .file(file)
        } else {
            return nil
        }
    }

    /// The identity the shared caches key the image by.
    var key: AnyHashable {
        switch self {
        case .file(let file):
            AnyHashable(file.identifier)
        case .process(let image):
            AnyHashable(image.identifier)
        }
    }

    /// The image as the stores take it.
    var representable: any MachORepresentableWithCache {
        switch self {
        case .file(let file):
            file
        case .process(let image):
            image
        }
    }

    var imagePath: String {
        switch self {
        case .file(let file):
            file.imagePath
        case .process(let image):
            image.imagePath
        }
    }

    /// The libraries the image links, in load command order: the order bind
    /// ordinals count in.
    var dependencyInstallNames: [String] {
        switch self {
        case .file(let file):
            file.dependencies.map(\.dylib.name)
        case .process(let image):
            image.dependencies.map(\.dylib.name)
        }
    }

    /// The libraries the image re-exports.
    var reexportedInstallNames: [String] {
        switch self {
        case .file(let file):
            file.dependencies.filter { $0.type == .reexport }.map(\.dylib.name)
        case .process(let image):
            image.dependencies.filter { $0.type == .reexport }.map(\.dylib.name)
        }
    }

    /// The install name of the library `ordinal` binds from — an index from
    /// 1 into the dependencies, `0` for the image itself; `nil` for a flat or
    /// weak lookup and the main executable.
    func installName(forLibraryOrdinal ordinal: Int) -> String? {
        if ordinal == 0 {
            return imagePath
        }
        let installNames = dependencyInstallNames
        guard ordinal >= 1, ordinal <= installNames.count else { return nil }
        return installNames[ordinal - 1]
    }
}
