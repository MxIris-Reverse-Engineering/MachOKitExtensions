import Foundation
import MachOKit
import MachOKitExtensions
import MachOResolving
@_spi(Internals) import MachOCaches

/// The C and C++ symbols of an image, found by offset or by name. An image's
/// index is built on first use and shared by every caller.
///
/// ```swift
/// let store = SymbolIndexStore.shared
/// let mainOffset = store.offset(ofSymbolNamed: "_main", in: machOFile)
/// let enclosingName = store.closestSymbols(at: instructionOffset, in: machOFile)?.symbols.first?.name
/// let language = SymbolLanguage(ofSymbolNamed: someSymbol.name)   // .cPlusPlus, .c, or a registered language
/// ```
///
/// The names of every language another package registered with
/// ``SymbolLanguageRegistry`` are left out — Swift once MachOSwiftSection's
/// `SwiftSymbols` is linked (it keeps them, demangled, in a store of its own
/// built on the same ``SymbolSweep``), Objective-C once MachOObjCSection is.
/// Only where they sit is kept, so that ``closestSymbols(at:in:)`` does not
/// take an address inside their code for part of the C function before it.
/// So the index's contents depend on which packages the process links: a
/// language nobody registered counts as C. Names are the symbol table's
/// spellings (with the leading underscore of a C name on Darwin), not
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
/// call ``remove(for:)`` when an image is no longer of interest. An index
/// built before a language registered is dropped on the store's next query,
/// and built again.
///
/// `@unchecked Sendable`: the one mutable property is behind a lock.
public final class SymbolIndexStore: @unchecked Sendable {
    public static let shared = SymbolIndexStore(languageRegistry: .shared)

    private let cache = SharedCache<Storage>(evictionGroup: .symbolStore)

    /// Which languages count as some other package's, and stay out.
    private let languageRegistry: SymbolLanguageRegistry

    private let observedLanguageGenerationLock = NSLock()

    /// The registry generation every index in the cache was built at or
    /// after. Guarded by `observedLanguageGenerationLock`.
    private var observedLanguageGeneration = 0

    /// A store of its own, classifying through `languageRegistry` — for
    /// tests; everything else uses ``shared``.
    init(languageRegistry: SymbolLanguageRegistry) {
        self.languageRegistry = languageRegistry
    }

    /// The symbols at exactly `offset`, in the order the symbol table lists
    /// them; `nil` when none sits there.
    public func symbols(for offset: Int, in machO: some MachORepresentableWithCache) -> Symbols? {
        guard let storage = storage(in: machO) else { return nil }
        return storage.symbols(at: offset)
    }

    /// The symbols at the greatest offset not after `offset` — the function
    /// or data an address falls in, when the symbol table names it; `nil`
    /// when no C or C++ symbol sits at or before `offset`, and `nil` when a
    /// registered language's symbol sits closer: the address lies in that
    /// language's code.
    ///
    /// No distance limit applies: an address far past the last symbol of a
    /// stripped image still answers that symbol, so a caller that cares
    /// bounds the distance itself.
    public func closestSymbols(at offset: Int, in machO: some MachORepresentableWithCache) -> Symbols? {
        guard let storage = storage(in: machO) else { return nil }
        return storage.closestSymbols(at: offset)
    }

    /// The offset of the symbol named `name`, spelled as the symbol table
    /// spells it; `nil` when the image defines no such C or C++ symbol.
    public func offset(ofSymbolNamed name: String, in machO: some MachORepresentableWithCache) -> Int? {
        guard let storage = storage(in: machO) else { return nil }
        return storage.offset(ofSymbolNamed: name)
    }

    /// Whether the image defines a C or C++ symbol named `name`.
    public func containsSymbol(named name: String, in machO: some MachORepresentableWithCache) -> Bool {
        offset(ofSymbolNamed: name, in: machO) != nil
    }

    /// Whether `name` has an export-trie entry in the image: a fact about
    /// the trie, not an access level. `nil` when the image carries no export
    /// information at all — an object file, say — where "not exported" would
    /// be a claim nothing supports. A registered language's name answers
    /// `false`: the index does not keep it.
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

    /// The image's index, built with every language registered so far.
    ///
    /// When a language has registered since the store last looked, every
    /// index is dropped first. An index whose build began before a
    /// registration that came in meanwhile is caught by its own generation
    /// and built once more.
    func storage(in machO: some MachORepresentableWithCache) -> Storage? {
        let generation = languageRegistry.generation
        dropIndexesBuiltBefore(generation: generation)
        guard let storage = cache.storage(in: machO, buildUsing: { Storage(sweeping: $0, classifier: languageRegistry.classifier()) }) else { return nil }
        guard storage.languageGeneration < generation else { return storage }
        cache.remove(for: machO)
        return cache.storage(in: machO) { Storage(sweeping: $0, classifier: languageRegistry.classifier()) }
    }

    private func dropIndexesBuiltBefore(generation: Int) {
        observedLanguageGenerationLock.lock()
        let isNewGeneration = generation > observedLanguageGeneration
        if isNewGeneration {
            observedLanguageGeneration = generation
        }
        observedLanguageGenerationLock.unlock()
        if isNewGeneration {
            cache.removeAll()
        }
    }
}

extension SymbolIndexStore {
    /// One image's index.
    final class Storage: Sendable {
        let sweptSymbols: SweptSymbolTable

        /// Where every registered language's symbols sit, ascending.
        let boundaryOffsets: [Int]

        /// The registry generation the index was classified at.
        let languageGeneration: Int

        init(sweeping machO: some MachORepresentableWithCache, classifier: SymbolLanguageClassifier) {
            let sweep = SymbolSweep(sweeping: machO, routing: CAndCPlusPlusSymbolTableRouting(), classifier: classifier)
            self.sweptSymbols = sweep[.symbols]
            self.boundaryOffsets = sweep[.boundaries].sortedCanonicalOffsets
            self.languageGeneration = classifier.generation
        }

        func symbols(at offset: Int) -> Symbols? {
            guard let rows = sweptSymbols.rowsByOffset[offset] else { return nil }
            let symbolTable = sweptSymbols.symbolTable
            return Symbols(offset: offset, symbols: rows.map { row in
                Symbol(offset: offset, name: symbolTable.materializedName(atRow: row), isExternal: symbolTable.isExternal(atRow: row))
            })
        }

        /// The C or C++ symbols nearest at or before `offset`, unless a
        /// registered language's symbol sits nearer. At an offset both share
        /// (an alias, folded identical code), the C or C++ symbols answer.
        func closestSymbols(at offset: Int) -> Symbols? {
            guard let symbolOffset = Self.lastOffset(notAfter: offset, in: sweptSymbols.sortedCanonicalOffsets) else { return nil }
            if let boundaryOffset = Self.lastOffset(notAfter: offset, in: boundaryOffsets), boundaryOffset > symbolOffset {
                return nil
            }
            return symbols(at: symbolOffset)
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

        /// The greatest of `sortedOffsets` not after `offset`.
        private static func lastOffset(notAfter offset: Int, in sortedOffsets: [Int]) -> Int? {
            // The number of offsets not after `offset`: the closest one is
            // the last of them.
            var lowerBound = 0
            var upperBound = sortedOffsets.count
            while lowerBound < upperBound {
                let middle = (lowerBound + upperBound) / 2
                if sortedOffsets[middle] <= offset {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }
            return lowerBound > 0 ? sortedOffsets[lowerBound - 1] : nil
        }
    }
}

/// Files C and C++ names into one offset-indexed table, and where every
/// registered language's names sit into a table of boundaries that keeps no
/// names. Names of an image outside the shared cache are copied: a pure C
/// image can be unloaded.
struct CAndCPlusPlusSymbolTableRouting: SymbolTableRouting {
    enum Table: Hashable, Sendable {
        case symbols
        case boundaries
    }

    func table(forSymbolNamed name: UnsafePointer<CChar>, language: SymbolLanguage) -> Table? {
        language == .c || language == .cPlusPlus ? .symbols : .boundaries
    }

    func offsetIndexing(in table: Table) -> SymbolOffsetIndexing {
        switch table {
        case .symbols:
            .byOffsetWithSortedOffsets
        case .boundaries:
            .sortedOffsetsOnly
        }
    }

    var mayReferenceStringTablesOfLoadedImages: Bool {
        false
    }
}
