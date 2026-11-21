import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import MachOSymbols
@testable import CPlusPlusSymbols

/// libc++ re-exports libc++abi's `std::exception` members one by one through
/// indirect symbol-table entries (`N_INDR`), and defines nothing of the class
/// itself. Indexed as definitions, those entries made up a `std::exception`
/// scope of libc++'s own, its members at string-table indexes
/// (`MachOSymbolsTests`' `IndirectSymbolEntryTests`).
@Suite
struct IndirectSymbolEntryScopeTests {
    private static let libcxxPath = "/usr/lib/libc++.1.dylib"

    private struct MissingImage: Error {
        let path: String
    }

    private static func readers() throws -> [(label: String, machO: any MachORepresentableWithCache)] {
        var loadedImage: MachOImage?
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index), String(cString: name) == libcxxPath, let header = _dyld_get_image_header(index) else { continue }
            loadedImage = MachOImage(ptr: header)
        }
        guard let loadedImage else { throw MissingImage(path: libcxxPath) }
        let hostCache = try #require(FullDyldCache.cachedHost)
        let file = try #require(hostCache.machOFile(by: .path(libcxxPath)))
        return [("loaded image", loadedImage), ("file from the host cache", file)]
    }

    @Test func indirectEntriesMakeNoCPlusPlusScope() throws {
        for (label, machO) in try Self.readers() {
            let store = CPlusPlusSymbolIndexStore(languageRegistry: .shared)
            #expect(store.symbol(named: "__ZNKSt9exception4whatEv", in: machO) == nil, "\(label)")
            #expect(store.scope(named: "std::exception", in: machO) == nil, "\(label)")
        }
    }
}
