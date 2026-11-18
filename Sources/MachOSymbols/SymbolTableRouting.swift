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

    /// Whether the sweep files `table`'s rows by offset as well as by name.
    func indexesRowsByOffset(in table: Table) -> Bool

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
