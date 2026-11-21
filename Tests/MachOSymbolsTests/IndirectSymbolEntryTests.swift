import Foundation
import Testing
import MachOKit
import MachOKitExtensions
@_spi(Internals) @testable import MachOSymbols

/// An indirect symbol-table entry (`N_INDR`) re-exports another image's
/// symbol by name: its value is the string-table index of the name it stands
/// for, not an address, and the image defines nothing there. libc++
/// re-exports libc++abi's `std::exception` members one by one this way.
/// Indexed as a definition, the entry filed `std::exception::what()` at the
/// string-table index (`CPlusPlusSymbolsTests`' `IndirectSymbolEntryScopeTests`
/// covers the C++ scope tree it made up).
@Suite
struct IndirectSymbolEntryTests {
    private static let libcxxPath = "/usr/lib/libc++.1.dylib"

    /// `std::exception::what() const`, which libc++ re-exports from libc++abi.
    private static let reExportedName = "__ZNKSt9exception4whatEv"

    private static func loadedImage(at path: String) throws -> MachOImage {
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index), String(cString: name) == path, let header = _dyld_get_image_header(index) else { continue }
            return MachOImage(ptr: header)
        }
        throw MissingImage(path: path)
    }

    private struct MissingImage: Error {
        let path: String
    }

    private static func readers() throws -> [(label: String, machO: any MachORepresentableWithCache)] {
        let image = try loadedImage(at: libcxxPath)
        let hostCache = try #require(FullDyldCache.cachedHost)
        let file = try #require(hostCache.machOFile(by: .path(libcxxPath)))
        return [("loaded image", image), ("file from the host cache", file)]
    }

    @Test func libcxxReExportsThroughIndirectEntries() throws {
        let image = try Self.loadedImage(at: Self.libcxxPath)
        let entry = image.symbols.first { $0.name == Self.reExportedName }
        #expect(entry?.nlist.isIndirect == true)
        #expect(entry?.nlist.isExternal == false)
    }

    @Test func indirectEntriesAreNotIndexed() throws {
        for (label, machO) in try Self.readers() {
            let store = SymbolIndexStore(languageRegistry: .shared)
            #expect(store.offset(ofSymbolNamed: Self.reExportedName, in: machO) == nil, "\(label)")
        }
    }
}
