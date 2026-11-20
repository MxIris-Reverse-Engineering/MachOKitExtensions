import MachOKit
import MachOKitExtensions
import MachOResolving
@_spi(Internals) import MachOCaches
@_spi(Internals) import MachOSymbols

/// The C++ symbols of an image, arranged by the scopes they sit in. An
/// image's index is built on first use and shared by every caller.
///
/// ```swift
/// let store = CPlusPlusSymbolIndexStore.shared
/// for scope in store.childScopes(of: .global, in: machO) { … }          // top level
/// if let value = store.scope(named: "llvm::Value", in: machO) {
///     let constructors = store.members(of: value, in: machO).filter { $0.name.kind == .constructor }
/// }
/// let names = store.symbols(for: functionOffset, in: machO).map(\.name.demangledName)
/// ```
///
/// The index holds the image's defined C++ symbols — symbol table and
/// export trie, as `MachOSymbols`' ``SymbolIndexStore`` collects them — and
/// a tree of the scopes they sit in: every scope that holds a symbol, and
/// every scope above it. A scope is a ``CPlusPlusScope/Kind/type`` or a
/// ``CPlusPlusScope/Kind/namespace`` only when some symbol name shows it
/// (see ``CPlusPlusScope/Evidence``). Where a name files its symbol is
/// ``CPlusPlusSymbolName``'s ``CPlusPlusSymbolName/scopePath``: a vtable
/// sits in its class, a thunk in the class of the function it reaches.
///
/// The index keeps the tree, not the names taken apart: the symbols a query
/// returns are parsed again then, which takes microseconds a name. Offsets
/// are the ones ``SymbolIndexStore`` uses. Nothing evicts an index on its
/// own: call ``remove(for:)`` when an image is no longer of interest.
///
/// `Sendable`: an index is immutable once built, and the cache locks itself.
public final class CPlusPlusSymbolIndexStore: Sendable {
    public static let shared = CPlusPlusSymbolIndexStore(languageRegistry: .shared)

    private let cache = SharedCache<Storage>(evictionGroup: .cPlusPlusSymbolStore)

    /// The registry the sweep classifies names through. C++ is decided before
    /// any registered language, so registrations never change the index.
    private let languageRegistry: SymbolLanguageRegistry

    /// A store of its own, sweeping through `languageRegistry` — for tests;
    /// everything else uses ``shared``.
    init(languageRegistry: SymbolLanguageRegistry) {
        self.languageRegistry = languageRegistry
    }

    /// The scopes directly inside `scope`, ascending by name.
    /// ``CPlusPlusScope/global`` gives the top-level ones.
    public func childScopes(of scope: CPlusPlusScope, in machO: some MachORepresentableWithCache) -> [CPlusPlusScope] {
        guard let storage = storage(in: machO), let scopeIndex = storage.scopeIndex(of: scope) else { return [] }
        return storage.scopes[scopeIndex].childIndices.map { storage.scopes[$0].scope }
    }

    /// The scope whose ``CPlusPlusScope/qualifiedName`` is `qualifiedName`;
    /// `nil` when no C++ symbol of the image sits in it or below it. The
    /// empty name is ``CPlusPlusScope/global``.
    public func scope(named qualifiedName: String, in machO: some MachORepresentableWithCache) -> CPlusPlusScope? {
        guard let storage = storage(in: machO), let scopeIndex = storage.scopeIndexByQualifiedName[qualifiedName] else { return nil }
        return storage.scopes[scopeIndex].scope
    }

    /// The symbols directly inside `scope` — functions, data, its vtable and
    /// typeinfo — ascending by offset.
    public func members(of scope: CPlusPlusScope, in machO: some MachORepresentableWithCache) -> [CPlusPlusSymbol] {
        guard let storage = storage(in: machO), let scopeIndex = storage.scopeIndex(of: scope) else { return [] }
        let demangler = CPlusPlusDemangler()
        return storage.scopes[scopeIndex].memberRows.compactMap { storage.symbol(atRow: $0, using: demangler) }
    }

    /// The C++ symbols at exactly `offset`, in symbol-table order; empty when
    /// none sits there.
    public func symbols(for offset: Int, in machO: some MachORepresentableWithCache) -> [CPlusPlusSymbol] {
        guard let storage = storage(in: machO), let rows = storage.sweptSymbols.rowsByOffset[offset] else { return [] }
        let symbolTable = storage.sweptSymbols.symbolTable
        let demangler = CPlusPlusDemangler()
        return rows.filter { symbolTable.canonicalOffset(atRow: $0) == offset }.compactMap { storage.symbol(atRow: $0, using: demangler) }
    }

    /// The C++ symbol whose name is `mangledName`, spelled as the symbol
    /// table spells it; `nil` when the image defines no such symbol, or the
    /// demangler does not parse it.
    public func symbol(named mangledName: String, in machO: some MachORepresentableWithCache) -> CPlusPlusSymbol? {
        guard let storage = storage(in: machO), let row = storage.definedRow(forName: mangledName) else { return nil }
        return storage.symbol(atRow: row, using: CPlusPlusDemangler())
    }

    /// The image's names that look like C++ (`__Z…`) but that the demangler
    /// does not parse, ascending by offset.
    public func unparsedSymbols(in machO: some MachORepresentableWithCache) -> [Symbol] {
        guard let storage = storage(in: machO) else { return [] }
        return storage.unparsedRows.map(storage.plainSymbol(atRow:))
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
        cache.storage(in: machO) { Storage(sweeping: $0, languageRegistry: languageRegistry) }
    }
}

extension CPlusPlusSymbolIndexStore {
    /// One image's index.
    final class Storage: Sendable {
        /// A scope of the tree. The global scope is the first.
        struct ScopeRecord: Sendable {
            let scope: CPlusPlusScope
            let parentIndex: Int?
            /// Ascending by name.
            let childIndices: [Int]
            /// Ascending by offset.
            let memberRows: [UInt32]
        }

        let sweptSymbols: SweptSymbolTable

        let scopes: [ScopeRecord]

        /// Every scope by ``CPlusPlusScope/qualifiedName``.
        let scopeIndexByQualifiedName: [String: Int]

        /// Rows whose names the demangler does not parse, ascending by
        /// offset.
        let unparsedRows: [UInt32]

        init(sweeping machO: some MachORepresentableWithCache, languageRegistry: SymbolLanguageRegistry) {
            let sweep = SymbolSweep(sweeping: machO, routing: CPlusPlusSymbolTableRouting(), languageRegistry: languageRegistry)
            let sweptSymbols = sweep[.symbols]
            let symbolTable = sweptSymbols.symbolTable
            var builder = ScopeTreeBuilder()
            var unparsedRows: [UInt32] = []
            let demangler = CPlusPlusDemangler()
            for row in 0 ..< UInt32(symbolTable.rowCount) {
                guard Self.isDefined(row: row, in: sweptSymbols) else { continue }
                let isParsed = symbolTable.withNameBytes(atRow: row) { nameBytes in
                    demangler.withParsedName(bytes: nameBytes) { builder.add(row: row, parsedName: $0) }
                } != nil
                if !isParsed {
                    unparsedRows.append(row)
                }
            }
            let offsetOfRow = { (row: UInt32) in symbolTable.canonicalOffset(atRow: row) }
            let scopes = builder.finish(memberOrder: { (offsetOfRow($0), $0) < (offsetOfRow($1), $1) })
            self.sweptSymbols = sweptSymbols
            self.scopes = scopes
            self.scopeIndexByQualifiedName = Dictionary(scopes.indices.map { (scopes[$0].scope.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first })
            self.unparsedRows = unparsedRows.sorted { (offsetOfRow($0), $0) < (offsetOfRow($1), $1) }
        }

        /// Whether the row's name is defined at its offset, rather than
        /// only named by a debug-map entry, which reserves a row but never
        /// files it.
        private static func isDefined(row: UInt32, in sweptSymbols: SweptSymbolTable) -> Bool {
            sweptSymbols.rowsByOffset[sweptSymbols.symbolTable.canonicalOffset(atRow: row)]?.contains(row) == true
        }

        func scopeIndex(of scope: CPlusPlusScope) -> Int? {
            scope.path.isEmpty ? 0 : scopeIndexByQualifiedName[scope.qualifiedName]
        }

        func definedRow(forName name: String) -> UInt32? {
            guard let row = sweptSymbols.symbolTable.row(forName: name), Self.isDefined(row: row, in: sweptSymbols) else { return nil }
            return row
        }

        func plainSymbol(atRow row: UInt32) -> Symbol {
            let symbolTable = sweptSymbols.symbolTable
            return Symbol(offset: symbolTable.canonicalOffset(atRow: row), name: symbolTable.materializedName(atRow: row), isExternal: symbolTable.isExternal(atRow: row))
        }

        /// The row's symbol with its name parsed again; `nil` for a name the
        /// demangler does not parse.
        func symbol(atRow row: UInt32, using demangler: CPlusPlusDemangler) -> CPlusPlusSymbol? {
            let symbol = plainSymbol(atRow: row)
            guard let name = demangler.withParsedName(symbol.name, { CPlusPlusSymbolName(mangledName: symbol.name, parsedName: $0) }) else { return nil }
            return CPlusPlusSymbol(symbol: symbol, name: name)
        }
    }
}

extension CPlusPlusSymbolIndexStore {
    /// Grows the scope tree one parsed name at a time, then decides every
    /// scope's kind.
    struct ScopeTreeBuilder {
        private struct PendingScope {
            let name: String
            let baseName: String
            let parentIndex: Int?
            var isFunction = false
            var evidence: CPlusPlusScope.Evidence = []
            var childIndexByName: [String: Int] = [:]
            var memberRows: [UInt32] = []
        }

        private var pendingScopes = [PendingScope(name: "", baseName: "", parentIndex: nil)]

        /// The paths of named types some signature uses as types. Applied
        /// once every scope exists, and only to scopes that exist.
        private var referencedTypePaths: Set<[String]> = []

        mutating func add(row: UInt32, parsedName: CPlusPlusDemangler.ParsedName) {
            var scopeIndex = 0
            for componentIndex in 0 ..< parsedName.scopeComponentCount {
                let componentName = parsedName.scopeComponentName(at: componentIndex)
                if let childIndex = pendingScopes[scopeIndex].childIndexByName[componentName] {
                    scopeIndex = childIndex
                } else {
                    let childIndex = pendingScopes.count
                    pendingScopes.append(PendingScope(name: componentName, baseName: parsedName.scopeComponentBaseName(at: componentIndex), parentIndex: scopeIndex))
                    pendingScopes[scopeIndex].childIndexByName[componentName] = childIndex
                    scopeIndex = childIndex
                }
                switch parsedName.scopeComponentHint(at: componentIndex) {
                case .none:
                    break
                case .namespace:
                    pendingScopes[scopeIndex].evidence.insert(.mangledAsNamespace)
                case .type:
                    pendingScopes[scopeIndex].evidence.insert(.mangledAsType)
                case .function:
                    pendingScopes[scopeIndex].isFunction = true
                }
            }
            pendingScopes[scopeIndex].memberRows.append(row)
            if scopeIndex != 0 {
                pendingScopes[scopeIndex].evidence.formUnion(Self.evidence(forScopeOf: parsedName))
            }
            for path in parsedName.referencedTypePaths {
                referencedTypePaths.insert(path)
            }
        }

        /// What a name shows about the scope it files its symbol in.
        private static func evidence(forScopeOf parsedName: CPlusPlusDemangler.ParsedName) -> CPlusPlusScope.Evidence {
            var evidence: CPlusPlusScope.Evidence = []
            let kind = parsedName.kind
            if kind == .constructor || kind == .destructor {
                evidence.insert(.constructorOrDestructor)
            } else if kind == .virtualTable || kind == .virtualTableTable || kind == .constructionVirtualTable {
                evidence.insert(.virtualTable)
            } else if kind == .typeInfo || kind == .typeInfoName {
                evidence.insert(.typeInfo)
            } else if kind.isThunk {
                evidence.insert(.thunk)
            }
            if !parsedName.functionQualifiers.isEmpty {
                evidence.insert(.qualifiedMemberFunction)
            }
            return evidence
        }

        /// The finished tree: evidence of use applied, kinds decided,
        /// children sorted by name and members by `memberOrder`.
        mutating func finish(memberOrder: (UInt32, UInt32) -> Bool) -> [Storage.ScopeRecord] {
            for path in referencedTypePaths {
                var scopeIndex: Int? = 0
                for component in path {
                    scopeIndex = scopeIndex.flatMap { pendingScopes[$0].childIndexByName[component] }
                }
                if let scopeIndex, scopeIndex != 0 {
                    pendingScopes[scopeIndex].evidence.insert(.usedAsType)
                }
            }
            var paths: [[String]] = []
            paths.reserveCapacity(pendingScopes.count)
            for pendingScope in pendingScopes {
                // A parent always precedes its children.
                paths.append(pendingScope.parentIndex.map { paths[$0] + [pendingScope.name] } ?? [])
            }
            return pendingScopes.indices.map { scopeIndex in
                let pendingScope = pendingScopes[scopeIndex]
                let kind: CPlusPlusScope.Kind = if pendingScope.isFunction {
                    .function
                } else if scopeIndex == 0 || pendingScope.evidence.contains(.mangledAsNamespace) {
                    .namespace
                } else if !pendingScope.evidence.isDisjoint(with: .anyType) {
                    .type
                } else {
                    .undetermined
                }
                let childIndices = pendingScope.childIndexByName.sorted { $0.key < $1.key }.map(\.value)
                return Storage.ScopeRecord(
                    scope: CPlusPlusScope(path: paths[scopeIndex], baseName: pendingScope.baseName, kind: kind, evidence: pendingScope.evidence),
                    parentIndex: pendingScope.parentIndex,
                    childIndices: childIndices,
                    memberRows: pendingScope.memberRows.sorted(by: memberOrder)
                )
            }
        }
    }
}

/// Files C++ names into one table indexed by offset; leaves every other
/// language out. Names of an image outside the shared cache are copied: a
/// C++ image can be unloaded.
struct CPlusPlusSymbolTableRouting: SymbolTableRouting {
    enum Table: Hashable, Sendable {
        case symbols
    }

    func table(forSymbolNamed name: UnsafePointer<CChar>, language: SymbolLanguage) -> Table? {
        language == .cPlusPlus ? .symbols : nil
    }

    func offsetIndexing(in table: Table) -> SymbolOffsetIndexing {
        .byOffset
    }

    var mayReferenceStringTablesOfLoadedImages: Bool {
        false
    }
}
