import Foundation
import MachOKit
import MachOKitExtensions
import OSToolbox

/// Finds, inside a dyld shared cache, the image an address belongs to.
///
/// The main cache header lists every image with its load address; the image
/// whose address is the greatest one not above the target is the one that
/// contains it (`__TEXT` segments are laid out contiguously in address
/// order). Images are opened on first use and kept, because one caller
/// typically reaches into the same few images (`SwiftUICore`,
/// `libswiftCore`) many times.
///
/// Was `CacheImageResolver` in `SwiftThunkAnalysis` (evolution proposal
/// `offline-cross-references-and-symbolication`). It keeps no per-image
/// cache of itself: the accessor-thunk reader keeps one locator per image in
/// its own `SharedCache`, with its own eviction group.
///
/// `@unchecked Sendable` because it holds the `DyldCache` it opens images
/// from, which MachOKit does not declare `Sendable`, and opens them from
/// whichever thread asks. What it opens and builds is behind a `Mutex`.
@_spi(Internals) public final class CacheImageLocator: @unchecked Sendable {
    /// What the locator opens and builds, behind one lock.
    private struct State {
        var openedImagesByPath: [String: MachOFile?] = [:]
        var exportedAddressesByImagePath: [String: [UInt64: String]] = [:]
    }

    private let cache: DyldCache
    private let imagesByAddress: [(address: UInt64, path: String)]
    private let state = Mutex(State())

    /// The locator for the cache `machO` was read from; `nil` for a file not
    /// read out of a cache.
    @_spi(Internals) public init?(cacheOf machO: MachOFile) {
        guard let cache = machO.cache else { return nil }
        let mainCache = cache.mainCache ?? cache
        guard let imageInfos = mainCache.imageInfos else { return nil }
        var images: [(address: UInt64, path: String)] = []
        for imageInfo in imageInfos {
            guard let path = imageInfo.path(in: mainCache) else { continue }
            images.append((address: UInt64(imageInfo.layout.address), path: path))
        }
        guard !images.isEmpty else { return nil }
        self.cache = cache
        self.imagesByAddress = images.sorted { $0.address < $1.address }
    }

    /// The path of the image whose `__TEXT` starts at or below `address`
    /// closest to it.
    @_spi(Internals) public func imagePath(containing address: UInt64) -> String? {
        // Greatest load address not above the target.
        var low = 0
        var high = imagesByAddress.count
        while low < high {
            let middle = (low + high) / 2
            if imagesByAddress[middle].address <= address { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        return imagesByAddress[low - 1].path
    }

    @_spi(Internals) public func image(containing address: UInt64) -> MachOFile? {
        guard let path = imagePath(containing: address) else { return nil }
        let storedImage = state.withLock { state in
            state.openedImagesByPath[path]
        }
        if let storedImage {
            return storedImage
        }
        // Opened outside the lock; the first one stored is the one every
        // caller gets, so they share its caches.
        let opened = cache.machOFile(by: .path(path))
        return state.withLock { state in
            if let alreadyOpened = state.openedImagesByPath[path] { return alreadyOpened }
            state.openedImagesByPath[path] = opened
            return opened
        }
    }

    /// Which of `names` — symbols, by their exported spelling — the address
    /// in `image` is, if any. The table of the image is built for the first
    /// question and kept: later questions about the image must ask among the
    /// same names.
    ///
    /// The export trie's offsets are header-relative
    /// (``ImageAddressSpace/address(forExportedSymbolOffset:)``). Through the
    /// file-offset conversion they land in a cache image's `__LINKEDIT`, so
    /// the table would hold wrong addresses and never match.
    @_spi(Internals) public func exportedName(atAddress address: UInt64, in image: MachOFile, among names: some Sequence<String>) -> String? {
        let path = image.imagePath
        let storedAddressesByName = state.withLock { state in
            state.exportedAddressesByImagePath[path]
        }
        if let storedAddressesByName {
            return storedAddressesByName[address]
        }
        // Searched outside the lock: the answer is a function of the image,
        // so whichever caller stores it first stores the same table.
        var addressesByName: [UInt64: String] = [:]
        let addressSpace = ImageAddressSpace(of: image)
        for name in names {
            guard let exported = image.exportTrie?.search(by: name),
                  let exportedSymbolOffset = exported.offset,
                  let exportedAddress = addressSpace.address(forExportedSymbolOffset: exportedSymbolOffset)
            else { continue }
            addressesByName[exportedAddress] = name
        }
        state.withLock { state in
            if state.exportedAddressesByImagePath[path] == nil {
                state.exportedAddressesByImagePath[path] = addressesByName
            }
        }
        return addressesByName[address]
    }
}
