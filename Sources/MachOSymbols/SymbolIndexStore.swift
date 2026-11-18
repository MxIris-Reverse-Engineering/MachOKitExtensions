import Foundation
import MachOKit
import MachOKitExtensions
import MachOResolving
@_spi(Internals) import MachOCaches

/// The C, C++ and Objective-C symbols of an image, found by offset or by
/// name. An image's index is built on first use and shared by every caller.
///
/// ```swift
/// let store = SymbolIndexStore.shared
/// let mainOffset = store.offset(ofSymbolNamed: "_main", in: machOFile)
/// let enclosingName = store.closestSymbols(at: instructionOffset, in: machOFile)?.symbols.first?.name
/// let language = SymbolLanguage(ofSymbolNamed: someSymbol.name)   // .cPlusPlus, .objectiveC, …
/// ```
///
/// Swift names are left out — MachOSwiftSection keeps them, demangled, in a
/// store of its own built on the same ``SymbolSweep``. Names are the symbol
/// table's spellings (with the leading underscore of a C name on Darwin), not
/// demangled.
///
/// Offsets are the ones every reader in this package uses: a file offset for
/// a standalone file, the unslid address minus the shared region start for
/// an image read from a dyld shared cache, the distance from the mach header
/// for a loaded image. A debug-map (STABS) entry never decides an offset, and
/// an import is never indexed.
///
/// The index of an image read in place references the image's string table
/// only when the image sits in the dyld shared cache; an image outside it can
/// be unloaded, so its names are copied. Nothing evicts an index on its own:
/// call ``remove(for:)`` when an image is no longer of interest.
public final class SymbolIndexStore: Sendable {
    public static let shared = SymbolIndexStore()

    private let cache = SharedCache<Storage>(evictionGroup: .symbolStore)

    private init() {}

    /// The symbols at exactly `offset`, in the order the symbol table lists
    /// them; `nil` when none sits there.
    public func symbols(for offset: Int, in machO: some MachORepresentableWithCache) -> Symbols? {
        guard let storage = storage(in: machO) else { return nil }
        return storage.symbols(at: offset)
    }

    /// The symbols at the greatest offset not after `offset` — the function
    /// or data an address falls in, when the symbol table names it; `nil`
    /// when no symbol sits at or before `offset`.
    ///
    /// No distance limit applies: an address far past the last symbol of a
    /// stripped image still answers that symbol, so a caller that cares
    /// bounds the distance itself.
    public func closestSymbols(at offset: Int, in machO: some MachORepresentableWithCache) -> Symbols? {
        guard let storage = storage(in: machO) else { return nil }
        return storage.closestSymbols(at: offset)
    }

    /// The offset of the symbol named `name`, spelled as the symbol table
    /// spells it; `nil` when the image defines no such C, C++ or Objective-C
    /// symbol.
    public func offset(ofSymbolNamed name: String, in machO: some MachORepresentableWithCache) -> Int? {
        guard let storage = storage(in: machO) else { return nil }
        return storage.offset(ofSymbolNamed: name)
    }

    /// Whether the image defines a C, C++ or Objective-C symbol named `name`.
    public func containsSymbol(named name: String, in machO: some MachORepresentableWithCache) -> Bool {
        offset(ofSymbolNamed: name, in: machO) != nil
    }

    /// Whether `name` has an export-trie entry in the image: a fact about
    /// the trie, not an access level. `nil` when the image carries no export
    /// information at all — an object file, say — where "not exported" would
    /// be a claim nothing supports.
    public func isExported(name: String, in machO: some MachORepresentableWithCache) -> Bool? {
        guard let storage = storage(in: machO) else { return nil }
        return storage.sweptSymbols.exportFacts.isExported(name: name, in: storage.sweptSymbols.symbolTable)
    }

    /// Whether the image's export trie had any entry at all.
    public func hasExportInformation(in machO: some MachORepresentableWithCache) -> Bool {
        storage(in: machO)?.sweptSymbols.exportFacts.hasExportInformation ?? false
    }

    /// Builds the image's index now instead of on first use.
    public func prepare(in machO: some MachORepresentableWithCache) {
        _ = storage(in: machO)
    }

    /// Whether the image's index is built.
    public func contains(in machO: some MachORepresentableWithCache) -> Bool {
        cache.contains(in: machO)
    }

    /// Drops the image's index; the next query builds it again.
    public func remove(for machO: some MachORepresentableWithCache) {
        cache.remove(for: machO)
    }

    func storage(in machO: some MachORepresentableWithCache) -> Storage? {
        cache.storage(in: machO) { Storage(sweeping: $0) }
    }
}

extension SymbolIndexStore {
    /// One image's index.
    final class Storage: Sendable {
        let sweptSymbols: SweptSymbolTable

        init(sweeping machO: some MachORepresentableWithCache) {
            self.sweptSymbols = SymbolSweep(sweeping: machO, routing: NonSwiftSymbolTableRouting())[.symbols]
        }

        func symbols(at offset: Int) -> Symbols? {
            guard let rows = sweptSymbols.rowsByOffset[offset] else { return nil }
            let symbolTable = sweptSymbols.symbolTable
            return Symbols(offset: offset, symbols: rows.map { row in
                Symbol(offset: offset, name: symbolTable.materializedName(atRow: row), isExternal: symbolTable.isExternal(atRow: row))
            })
        }

        func closestSymbols(at offset: Int) -> Symbols? {
            // The number of offsets not after `offset`: the closest one is the
            // last of them.
            var lowerBound = 0
            let sortedCanonicalOffsets = sweptSymbols.sortedCanonicalOffsets
            var upperBound = sortedCanonicalOffsets.count
            while lowerBound < upperBound {
                let middle = (lowerBound + upperBound) / 2
                if sortedCanonicalOffsets[middle] <= offset {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }
            guard lowerBound > 0 else { return nil }
            return symbols(at: sortedCanonicalOffsets[lowerBound - 1])
        }

        /// The row's offset, or `nil` for a name the image does not define
        /// — including one only a debug-map entry names, whose row was
        /// reserved but never filed under an offset.
        func offset(ofSymbolNamed name: String) -> Int? {
            let symbolTable = sweptSymbols.symbolTable
            guard let row = symbolTable.row(forName: name) else { return nil }
            let offset = symbolTable.canonicalOffset(atRow: row)
            guard sweptSymbols.rowsByOffset[offset]?.contains(row) == true else { return nil }
            return offset
        }
    }
}

/// Files every name but a Swift one into one offset-indexed table. Names of
/// an image outside the shared cache are copied: a pure C image can be
/// unloaded.
struct NonSwiftSymbolTableRouting: SymbolTableRouting {
    enum Table: Hashable, Sendable {
        case symbols
    }

    func table(forSymbolNamed name: UnsafePointer<CChar>, language: SymbolLanguage) -> Table? {
        language == .swift ? nil : .symbols
    }

    func offsetIndexing(in table: Table) -> SymbolOffsetIndexing {
        .byOffsetWithSortedOffsets
    }

    var mayReferenceStringTablesOfLoadedImages: Bool {
        false
    }
}
