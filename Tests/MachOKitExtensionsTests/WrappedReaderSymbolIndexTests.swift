import Foundation
import Testing
import MachOKit
import MachOKitExtensions
@_spi(Internals) import MachOSymbols

/// A host's wrapper — MachOKitUI's `MachOFileSource` — around a file read
/// out of the system dyld shared cache.
///
/// A file read out of a cache files its symbols at `value − sharedRegionStart`.
/// That accounting is worked out from `asMachOFile`, so a wrapper the symbol
/// sweep could not see through would file every symbol at its raw value.
///
/// Combine is an image no other test of this package reads, so the index
/// this test builds for it is built through the wrapper.
@Suite
struct WrappedReaderSymbolIndexTests {
    @Test func wrappedReaderSeesTheSameOffsetsAsTheReaderItWraps() throws {
        let hostCache = try #require(FullDyldCache.cachedHost)
        let combine = try #require(hostCache.machOFile(by: .name("Combine")))
        let wrapper = ForwardingReader<MachOFile, DeclaredWrapper>(combine)
        let store = SymbolIndexStore.shared
        store.remove(for: wrapper)

        // A name defined more than once (a static function of two object
        // files) keeps one row, at the last definition the table lists.
        let symbolValueOffsetConverter = SymbolValueOffsetConverter(for: combine)
        var expectedOffsetByName: [String: Int] = [:]
        for symbol in combine.symbols where !symbol.nlist.isExternal && !symbol.nlist.isDebuggingEntry && SymbolLanguage(ofSymbolNamed: symbol.name) == .c {
            expectedOffsetByName[symbol.name] = symbolValueOffsetConverter.offset(forSymbolValue: symbol.offset)
        }
        try #require(!expectedOffsetByName.isEmpty)
        var misplacedCount = 0
        for (name, expectedOffset) in expectedOffsetByName.prefix(500) where store.offset(ofSymbolNamed: name, in: wrapper) != expectedOffset {
            misplacedCount += 1
        }
        #expect(misplacedCount == 0)
    }
}
