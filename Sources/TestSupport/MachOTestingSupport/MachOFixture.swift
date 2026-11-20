import Foundation
import MachOKit
import MachOKitExtensions
import MachOFixtureSupport

/// Where a ``MachOFixtureTests`` suite gets the image it reads both from disk
/// and from this process.
public struct MachOFixture: Sendable, CustomStringConvertible {
    enum Source: Sendable {
        /// A file on disk, and the name the process knows it by once loaded.
        case file(url: URL, imageName: String, loadsIntoProcess: Bool)
        /// An image the process already holds, found through an address in it.
        case loadedImage(path: String, headerAddress: UInt)
        /// The address given lies in no loaded image.
        case unresolvedAnchor
    }

    let source: Source

    /// The image built to `fileURL`, found in this process by `imageName` —
    /// the name `MachOImage(name:)` looks up, such as `SymbolTestsCore`.
    /// With `loadsIntoProcess`, the suite `dlopen`s the file first.
    public init(fileURL: URL, imageName: String, loadsIntoProcess: Bool) {
        self.source = .file(url: fileURL.standardizedFileURL, imageName: imageName, loadsIntoProcess: loadsIntoProcess)
    }

    /// The image of this process that holds `anchor` — a function or a global
    /// defined in it, or its `#dsohandle` — and the file dyld loaded it from.
    /// The image must have a file of its own: an image of the shared cache
    /// has none, see `ProcessImages.cacheFileAndLoadedImage(path:)`.
    public init(imageContaining anchor: UnsafeRawPointer) {
        var information = Dl_info()
        guard dladdr(anchor, &information) != 0, let path = information.dli_fname, let header = information.dli_fbase else {
            self.source = .unresolvedAnchor
            return
        }
        self.source = .loadedImage(path: String(cString: path), headerAddress: UInt(bitPattern: header))
    }

    public var description: String {
        switch source {
        case .file(let url, let imageName, let loadsIntoProcess):
            "\(imageName) at \(url.path)\(loadsIntoProcess ? ", loaded on demand" : "")"
        case .loadedImage(let path, _):
            path
        case .unresolvedAnchor:
            "an address in no loaded image"
        }
    }

    /// The fixture's file, sliced for this process, and its loaded image.
    func readers() throws -> (file: MachOFile, image: MachOImage) {
        switch source {
        case .file(let url, let imageName, let loadsIntoProcess):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MachOFixtureError.fileMissing(path: url.path)
            }
            let file = try HostSlice.machOFile(at: url)
            if loadsIntoProcess, dlopen(url.path, RTLD_LAZY) == nil {
                throw MachOFixtureError.imageNotLoaded(name: imageName, dynamicLoaderError: Self.lastDynamicLoaderError())
            }
            guard let image = MachOImage(name: imageName) else {
                throw MachOFixtureError.imageNotLoaded(name: imageName, dynamicLoaderError: Self.lastDynamicLoaderError())
            }
            return (file, image)
        case .loadedImage(let path, let headerAddress):
            let file = try HostSlice.machOFile(at: URL(fileURLWithPath: path))
            guard let header = UnsafePointer<mach_header>(bitPattern: headerAddress) else {
                throw MachOFixtureError.noImageContainsAnchor
            }
            return (file, MachOImage(ptr: header))
        case .unresolvedAnchor:
            throw MachOFixtureError.noImageContainsAnchor
        }
    }

    private static func lastDynamicLoaderError() -> String? {
        dlerror().map { String(cString: $0) }
    }
}

/// A ``MachOFixture`` could not be read.
public enum MachOFixtureError: Error, CustomStringConvertible {
    /// No file at the path; a fixture built into the package is not built yet.
    case fileMissing(path: String)
    /// The process holds no image of the name, after loading it if asked to.
    case imageNotLoaded(name: String, dynamicLoaderError: String?)
    /// The anchor given lies in no image this process loaded.
    case noImageContainsAnchor

    public var description: String {
        switch self {
        case .fileMissing(let path):
            "no fixture file at \(path)"
        case .imageNotLoaded(let name, let dynamicLoaderError):
            "this process holds no image named \(name)" + (dynamicLoaderError.map { "; dlerror: \($0)" } ?? "")
        case .noImageContainsAnchor:
            "the fixture's anchor lies in no image this process loaded"
        }
    }
}
