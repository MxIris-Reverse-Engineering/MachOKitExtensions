import Foundation
import MachOKit
import MachOKitExtensions

/// The images this process has loaded, and the files they came from.
public enum ProcessImages {
    /// The loaded image that holds `address` — a function or a global of the
    /// image, or its `#dsohandle`.
    public static func image(containing address: UnsafeRawPointer) -> MachOImage? {
        var information = Dl_info()
        guard dladdr(address, &information) != 0, let header = information.dli_fbase else {
            return nil
        }
        return MachOImage(ptr: header.assumingMemoryBound(to: mach_header.self))
    }

    /// The path dyld loaded the image that holds `address` from.
    public static func path(ofImageContaining address: UnsafeRawPointer) -> String? {
        var information = Dl_info()
        guard dladdr(address, &information) != 0, let path = information.dli_fname else {
            return nil
        }
        return String(cString: path)
    }

    /// The loaded image whose path is `path`, the install name for an image
    /// of the shared cache.
    public static func image(atPath path: String) -> MachOImage? {
        for index in 0 ..< _dyld_image_count() {
            guard let name = _dyld_get_image_name(index), String(cString: name) == path,
                  let header = _dyld_get_image_header(index) else {
                continue
            }
            return MachOImage(ptr: header)
        }
        return nil
    }

    /// The image of this Mac's shared cache at `path` — read from the cache
    /// the process opens once (`FullDyldCache.cachedHost`) — and the same
    /// image as this process loaded it.
    public static func cacheFileAndLoadedImage(path: String) throws -> (file: MachOFile, image: MachOImage) {
        guard let hostCache = FullDyldCache.cachedHost else {
            throw ProcessImageError.noSharedCache
        }
        guard let file = hostCache.machOFile(by: .path(path)) else {
            throw ProcessImageError.notInSharedCache(path: path)
        }
        guard let image = image(atPath: path) else {
            throw ProcessImageError.notLoaded(path: path)
        }
        return (file, image)
    }
}

public enum ProcessImageError: Error, CustomStringConvertible {
    /// The system exposes no shared cache file.
    case noSharedCache
    /// The shared cache holds no image at the path.
    case notInSharedCache(path: String)
    /// This process has not loaded an image from the path.
    case notLoaded(path: String)

    public var description: String {
        switch self {
        case .noSharedCache:
            "this system exposes no dyld shared cache file"
        case .notInSharedCache(let path):
            "the dyld shared cache holds no image at \(path)"
        case .notLoaded(let path):
            "this process has not loaded \(path)"
        }
    }
}
