/// Decides, name by name, which of a store's tables a ``SymbolSweep`` files a
/// symbol under.
///
/// A store keeps the names of one family of symbols — this package's
/// ``SymbolIndexStore`` the C, C++ and Objective-C ones, MachOSwiftSection's
/// Swift store the Swift ones — and builds on the same sweep by handing it a
/// routing. Each table the routing names gets its own rows, offset index,
/// export facts and local-symbol fact.
@_spi(Internals)
public protocol SymbolTableRouting: Sendable {
    /// The tables this routing files symbols into.
    associatedtype Table: Hashable, Sendable

    /// The table a symbol belongs in, or `nil` to leave it out of every
    /// table.
    ///
    /// Asked once for each defined symbol-table entry and once for each
    /// export-trie entry; an import is never offered. `name` is the
    /// NUL-terminated name as the symbol table spells it, valid only for the
    /// duration of the call; `language` is ``SymbolLanguage`` read from it
    /// already.
    func table(forSymbolNamed name: UnsafePointer<CChar>, language: SymbolLanguage) -> Table?

    /// How the sweep files `table`'s rows by offset, beyond by name.
    func offsetIndexing(in table: Table) -> SymbolOffsetIndexing

    /// Whether rows read from an in-process image outside the dyld shared
    /// cache may point into that image's string table instead of copying
    /// their names.
    ///
    /// `true` only when every image whose names this routing files is one
    /// dyld never unloads — dyld pins every image carrying Swift or
    /// Objective-C content. Rows of an image inside the shared cache always
    /// point in: the cache is never unmapped.
    var mayReferenceStringTablesOfLoadedImages: Bool { get }
}

/// How a ``SymbolSweep`` files a table's rows by offset.
///
/// A struct with static members rather than an enum, so that another form of
/// offset index can be added without breaking a routing's `switch`.
@_spi(Internals)
public struct SymbolOffsetIndexing: Hashable, Sendable {
    private enum Kind: Hashable, Sendable {
        case nameOnly
        case byOffset
        case byOffsetWithSortedOffsets
    }

    private let kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    /// Rows are found by name alone.
    public static let nameOnly = SymbolOffsetIndexing(kind: .nameOnly)

    /// Rows are also found by offset: ``SweptSymbolTable/rowsByOffset``.
    public static let byOffset = SymbolOffsetIndexing(kind: .byOffset)

    /// ``byOffset``, plus every canonical offset a row is filed under in
    /// ascending order — ``SweptSymbolTable/sortedCanonicalOffsets`` — for a
    /// nearest-offset search. Costs one integer per offset, which a store
    /// that never searches by proximity should not pay.
    public static let byOffsetWithSortedOffsets = SymbolOffsetIndexing(kind: .byOffsetWithSortedOffsets)

    var indexesByOffset: Bool {
        kind != .nameOnly
    }

    var keepsSortedOffsets: Bool {
        kind == .byOffsetWithSortedOffsets
    }
}
