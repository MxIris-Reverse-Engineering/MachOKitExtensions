import Foundation
import MachOKit
import MachOKitExtensions
import MachODependencies
@_spi(Internals) import MachOAddressResolution

/// Finds what an image refers to in other images: the image and offset of a
/// base's typeinfo, the image an address lies in, and whether an address is
/// code.
///
/// An image of this process reaches the other loaded images; a file out of
/// a dyld shared cache, the other images of the same cache; a standalone
/// file, the libraries its dependency search paths locate, following
/// re-exports.
final class BaseClassLocator: @unchecked Sendable {
    /// Re-exports are followed at most this deep.
    static let maximumReexportDepth = 4

    /// A cache image's data address is looked for in at most this many of
    /// its libraries.
    static let maximumSearchedLibraryCount = 512

    private let fileLocator: FileDependencyLocator?
    private let lock = NSLock()
    private var cacheImageLocatorsByCachePath: [String: CacheImageLocator] = [:]
    private var codeRangesByImagePath: [String: Range<UInt64>?] = [:]
    private var textAddressesByInstallNameByCachePath: [String: [String: UInt64]] = [:]
    /// Cache images by a data address found in them.
    private var dataImagesByAddress: [UInt64: MachOFile] = [:]
    /// The segments of the cache images searched so far.
    private var knownSegmentRanges: [(range: Range<UInt64>, image: MachOFile)] = []
    private var imagePathsWithKnownSegments: Set<String> = []

    /// A locator for references out of `root`. For a standalone file,
    /// `dependencySearchPaths` locates its libraries — by default the paths
    /// inferred from where it sits, and this Mac's dyld shared cache.
    init(root: IndexedImage, dependencySearchPaths: [DependencySearchPath]?) {
        if case .file(let file) = root, file.cache == nil {
            let searchPaths = dependencySearchPaths ?? DependencySearchPath.inferred(forRoot: file) + [.systemDyldSharedCache]
            fileLocator = FileDependencyLocator(
                searchPaths: searchPaths,
                preferredCPU: file.header.cpu,
                platforms: DependencyPlatforms.platforms(of: file)
            )
        } else {
            fileLocator = nil
        }
    }

    /// The image and typeinfo offset `reference`, read in `image`, reaches.
    func locate(_ reference: TypeInfoReference, from image: IndexedImage) -> (image: IndexedImage, offset: Int)? {
        switch reference {
        case .local(let offset):
            return (image, offset)
        case .boundSymbol(let name, let installName):
            let loadNames = installName.map { [$0] } ?? image.dependencyInstallNames
            for loadName in loadNames {
                if let definition = definition(of: name, inLibraryNamed: loadName, depth: 0) {
                    return definition
                }
            }
            return nil
        case .address(let address):
            return self.image(containingData: address, from: image)
        }
    }

    /// The image another image's data `address` lies in. In a dyld shared
    /// cache the images' data lies apart from their text, so the image whose
    /// text precedes the address is checked against its segments, and
    /// failing that the libraries `image` links are searched.
    func image(containingData address: UInt64, from image: IndexedImage) -> (image: IndexedImage, offset: Int)? {
        guard case .file(let file) = image, let cache = file.cache, let cacheImageLocator = cacheImageLocator(for: file) else {
            return self.image(containing: address, from: image)
        }
        let sharedRegionStart = UInt64(cache.mainCacheHeader.sharedRegionStart)
        guard address >= sharedRegionStart else { return nil }
        func found(_ library: MachOFile) -> (image: IndexedImage, offset: Int) {
            (.file(library), Int(address - sharedRegionStart))
        }
        lock.lock()
        let known = dataImagesByAddress[address] ?? knownSegmentRanges.first { $0.range.contains(address) }?.image
        lock.unlock()
        if let known {
            return found(known)
        }
        if let candidate = cacheImageLocator.image(containing: address), Self.segments(of: candidate, contain: address) {
            remember(candidate, containing: address)
            return found(candidate)
        }
        var visitedInstallNames: Set<String> = [file.imagePath]
        var pendingInstallNames = image.dependencyInstallNames
        var nextIndex = 0
        while nextIndex < pendingInstallNames.count, nextIndex < Self.maximumSearchedLibraryCount {
            let installName = pendingInstallNames[nextIndex]
            nextIndex += 1
            guard visitedInstallNames.insert(installName).inserted,
                  let library = cacheImage(atInstallName: installName, of: file, using: cacheImageLocator) else {
                continue
            }
            rememberSegments(of: library)
            if Self.segments(of: library, contain: address) {
                remember(library, containing: address)
                return found(library)
            }
            pendingInstallNames += IndexedImage.file(library).dependencyInstallNames
        }
        return nil
    }

    /// The image another image's `address` lies in, and the address as an
    /// offset in it.
    func image(containing address: UInt64, from image: IndexedImage) -> (image: IndexedImage, offset: Int)? {
        switch image {
        case .file(let file):
            guard let cacheImageLocator = cacheImageLocator(for: file),
                  let other = cacheImageLocator.image(containing: address),
                  let cache = other.cache else {
                return nil
            }
            let sharedRegionStart = UInt64(cache.mainCacheHeader.sharedRegionStart)
            guard address >= sharedRegionStart else { return nil }
            return (.file(other), Int(address - sharedRegionStart))
        case .process:
            #if canImport(Darwin)
            guard let (other, headerAddress) = Self.processImage(containing: address) else { return nil }
            return (.process(other), Int(address - headerAddress))
            #else
            return nil
            #endif
        }
    }

    /// Whether another image's `address` lies in that image's code.
    func isCode(_ address: UInt64, from image: IndexedImage) -> Bool {
        switch image {
        case .file(let file):
            guard let cacheImageLocator = cacheImageLocator(for: file),
                  let path = cacheImageLocator.imagePath(containing: address) else {
                return false
            }
            return codeRange(forImagePath: path) {
                cacheImageLocator.image(containing: address).flatMap { other in
                    other.segments.first { $0.segmentName == "__TEXT" }.map {
                        UInt64($0.virtualMemoryAddress) ..< UInt64($0.virtualMemoryAddress) + UInt64($0.virtualMemorySize)
                    }
                }
            }?.contains(address) ?? false
        case .process:
            #if canImport(Darwin)
            guard let (other, headerAddress) = Self.processImage(containing: address) else { return false }
            return codeRange(forImagePath: other.imagePath) {
                other.segments.first { $0.segmentName == "__TEXT" }.map { headerAddress ..< headerAddress + UInt64($0.virtualMemorySize) }
            }?.contains(address) ?? false
            #else
            return false
            #endif
        }
    }

    /// The image a standalone file's bind to `symbolName` from `loadName`
    /// reaches, following re-exports.
    private func definition(of symbolName: String, inLibraryNamed loadName: String, depth: Int) -> (image: IndexedImage, offset: Int)? {
        guard depth <= Self.maximumReexportDepth, let fileLocator, let library = fileLocator.locate(loadName: loadName) else {
            return nil
        }
        // A library can re-export a symbol of another one by listing it in
        // its export trie, with the other library's ordinal and the name it
        // has there.
        if let exported = library.cached.exportTrie?.search(by: symbolName), exported.flags.contains(.reexport) {
            guard let ordinal = exported.ordinal,
                  let installName = IndexedImage.file(library).installName(forLibraryOrdinal: Int(ordinal)) else {
                return nil
            }
            return definition(of: exported.importedName.flatMap { $0.isEmpty ? nil : $0 } ?? symbolName, inLibraryNamed: installName, depth: depth + 1)
        }
        if let symbol = CPlusPlusSymbolIndexStore.shared.symbol(named: symbolName, in: library) {
            return (.file(library), symbol.offset)
        }
        // Or re-export a whole library.
        for reexportedName in IndexedImage.file(library).reexportedInstallNames {
            if let definition = definition(of: symbolName, inLibraryNamed: reexportedName, depth: depth + 1) {
                return definition
            }
        }
        return nil
    }

    private func cacheImageLocator(for file: MachOFile) -> CacheImageLocator? {
        guard let cache = file.cache else { return nil }
        let cachePath = (cache.mainCache ?? cache).url.path
        lock.lock()
        if let existing = cacheImageLocatorsByCachePath[cachePath] {
            lock.unlock()
            return existing
        }
        lock.unlock()
        guard let created = CacheImageLocator(cacheOf: file) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let existing = cacheImageLocatorsByCachePath[cachePath] {
            return existing
        }
        cacheImageLocatorsByCachePath[cachePath] = created
        return created
    }

    /// The image of `file`'s cache installed at `installName`.
    private func cacheImage(atInstallName installName: String, of file: MachOFile, using cacheImageLocator: CacheImageLocator) -> MachOFile? {
        guard let cache = file.cache else { return nil }
        let mainCache = cache.mainCache ?? cache
        let cachePath = mainCache.url.path
        lock.lock()
        var textAddressesByInstallName = textAddressesByInstallNameByCachePath[cachePath]
        lock.unlock()
        if textAddressesByInstallName == nil {
            var built: [String: UInt64] = [:]
            if let imageInformations = mainCache.imageInfos {
                for imageInformation in imageInformations {
                    if let path = imageInformation.path(in: mainCache) {
                        built[path] = UInt64(imageInformation.layout.address)
                    }
                }
            }
            lock.lock()
            textAddressesByInstallNameByCachePath[cachePath] = built
            lock.unlock()
            textAddressesByInstallName = built
        }
        return textAddressesByInstallName?[installName].flatMap { cacheImageLocator.image(containing: $0) }
    }

    private func remember(_ library: MachOFile, containing address: UInt64) {
        lock.lock()
        dataImagesByAddress[address] = library
        lock.unlock()
    }

    private func rememberSegments(of library: MachOFile) {
        lock.lock()
        defer { lock.unlock() }
        guard imagePathsWithKnownSegments.insert(library.imagePath).inserted else { return }
        for segment in library.segments where segment.segmentName != "__LINKEDIT" && segment.segmentName != "__TEXT" {
            let start = UInt64(segment.virtualMemoryAddress)
            knownSegmentRanges.append((start ..< start + UInt64(segment.virtualMemorySize), library))
        }
    }

    /// Whether one of the image's segments, other than `__LINKEDIT`, holds
    /// the unslid `address`.
    private static func segments(of file: MachOFile, contain address: UInt64) -> Bool {
        file.segments.contains { segment in
            segment.segmentName != "__LINKEDIT"
                && address >= UInt64(segment.virtualMemoryAddress)
                && address - UInt64(segment.virtualMemoryAddress) < UInt64(segment.virtualMemorySize)
        }
    }

    private func codeRange(forImagePath path: String, compute: () -> Range<UInt64>?) -> Range<UInt64>? {
        lock.lock()
        if let known = codeRangesByImagePath[path] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let computed = compute()
        lock.lock()
        codeRangesByImagePath[path] = computed
        lock.unlock()
        return computed
    }

    #if canImport(Darwin)
    /// The loaded image `address` lies in, and its header's address.
    private static func processImage(containing address: UInt64) -> (image: MachOImage, headerAddress: UInt64)? {
        var information = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)),
              dladdr(pointer, &information) != 0,
              let header = information.dli_fbase else {
            return nil
        }
        return (MachOImage(ptr: header.assumingMemoryBound(to: mach_header.self)), UInt64(UInt(bitPattern: header)))
    }
    #endif
}
