import Foundation
import MachOKit
import MachOKitExtensions

/// One pass over an image's symbol table and export trie, filing each name
/// into the table its routing chooses.
///
/// ```swift
/// let sweep = SymbolSweep(sweeping: machO, routing: someRouting)
/// let swept = sweep[.symbols]
/// swept.symbolTable.row(forName: "_main")
/// ```
///
/// What the sweep decides for every symbol, whatever the routing:
///
/// - an import (`N_UNDF` with `N_EXT`) is never filed;
/// - a debug-map (STABS) entry only reserves its name's row: it never decides
///   an offset, and the row keeps the place the debug map gives it, which is
///   source order;
/// - one offset may hold many rows (aliases, identical code folding), but a
///   row is listed once per offset;
/// - a file's symbol value is a virtual address, converted to the offset the
///   rest of the package uses (``SymbolValueOffsetConverter``), and its row is
///   listed under both;
/// - every export-trie entry counts as export information, routed or not.
///
/// Rows of an in-process image point into its string table instead of
/// copying names when the image cannot be unloaded — see
/// ``SymbolTableRouting/mayReferenceStringTablesOfLoadedImages``.
@_spi(Internals)
public struct SymbolSweep<Routing: SymbolTableRouting>: Sendable {
    private let sweptTablesByTable: [Routing.Table: SweptSymbolTable]

    private let emptyTable: SweptSymbolTable

    /// What the sweep filed under `table`; an empty table when the routing
    /// filed nothing there.
    public subscript(table: Routing.Table) -> SweptSymbolTable {
        sweptTablesByTable[table] ?? emptyTable
    }

    public init(sweeping machO: some MachORepresentableWithCache, routing: Routing) {
        let machOImage = machO.asMachOImage
        let mappedSymbols64 = machOImage?.symbols64
        let mappedSymbols32 = machOImage?.symbols32
        let mappedStringTableBase = mappedSymbols64.map { UnsafeRawPointer($0.stringBase) } ?? mappedSymbols32.map { UnsafeRawPointer($0.stringBase) }
        let referencesMappedNames = mappedStringTableBase != nil
            && (routing.mayReferenceStringTablesOfLoadedImages || machOImage?.header.isInDyldCache == true)
        let builderStringTableBase = referencesMappedNames ? mappedStringTableBase : nil

        var accumulators: [Routing.Table: TableAccumulator] = [:]
        func makeAccumulator(for table: Routing.Table) -> TableAccumulator {
            TableAccumulator(mappedStringTableBase: builderStringTableBase, indexesRowsByOffset: routing.indexesRowsByOffset(in: table))
        }

        // Symbol-table leg for a loaded image: names are read in place
        // through `nameC`, and a `String` is made only for a routed name, as
        // the builder's de-duplication key. A loaded image's symbol values are
        // already offsets from its header, so canonical == raw here.
        func collectMappedSymbolRows(_ mappedSymbols: some Sequence<MachOImage.Symbol>, stringBase: UnsafeRawPointer) {
            for symbol in mappedSymbols where !symbol.nlist.isExternal {
                let nameC = symbol.nameC
                guard let table = routing.table(forSymbolNamed: nameC, language: SymbolLanguage(ofSymbolNameBytes: nameC)) else { continue }
                let name = String(cString: nameC)
                let offset = symbol.offset
                if referencesMappedNames {
                    let mappedNameByteOffset = UnsafeRawPointer(nameC) - stringBase
                    let nameByteLength = strlen(nameC)
                    accumulators[table, default: makeAccumulator(for: table)].collectSymbol(
                        named: name,
                        mappedNameByteOffset: mappedNameByteOffset,
                        nameByteLength: nameByteLength,
                        rawOffset: offset,
                        canonicalOffset: offset,
                        isDebuggingEntry: symbol.nlist.isDebuggingEntry,
                        isLocal: symbol.nlist.isLocal
                    )
                } else {
                    accumulators[table, default: makeAccumulator(for: table)].collectSymbol(
                        named: name,
                        rawOffset: offset,
                        canonicalOffset: offset,
                        isDebuggingEntry: symbol.nlist.isDebuggingEntry,
                        isLocal: symbol.nlist.isLocal
                    )
                }
            }
        }

        if let mappedSymbols64, let mappedStringTableBase {
            collectMappedSymbolRows(mappedSymbols64, stringBase: mappedStringTableBase)
        } else if let mappedSymbols32, let mappedStringTableBase {
            collectMappedSymbolRows(mappedSymbols32, stringBase: mappedStringTableBase)
        } else {
            // Symbol-table leg for every other reader: names are decoded per
            // entry and copied into the table's private buffer, and a symbol
            // value is converted to the offset the index files it under.
            let symbolValueOffsetConverter = SymbolValueOffsetConverter(for: machO)
            for symbol in machO.symbols where !symbol.nlist.isExternal {
                let name = symbol.name
                guard let table = name.withCString({ routing.table(forSymbolNamed: $0, language: SymbolLanguage(ofSymbolNameBytes: $0)) }) else { continue }
                let rawOffset = symbol.offset
                accumulators[table, default: makeAccumulator(for: table)].collectSymbol(
                    named: name,
                    rawOffset: rawOffset,
                    canonicalOffset: symbolValueOffsetConverter.offset(forSymbolValue: rawOffset),
                    isDebuggingEntry: symbol.nlist.isDebuggingEntry,
                    isLocal: symbol.nlist.isLocal
                )
            }
        }

        // Export-trie leg. Nothing else remembers trie membership — the
        // symbol-table legs see an exported symbol only if the table lists
        // it, and the rows minted here are conditional — so the facts are
        // recorded as the trie is walked. A trie offset counts from the
        // image's header; a file's index offsets count from its start offset
        // (a dyld cache image's, from the shared region).
        var hasExportInformation = false
        let exportedSymbolOffsetBase = machO.asMachOFile == nil ? 0 : machO.startOffset
        for exportedSymbol in machO.exportedSymbols {
            hasExportInformation = true
            let name = exportedSymbol.name
            guard let table = name.withCString({ routing.table(forSymbolNamed: $0, language: SymbolLanguage(ofSymbolNameBytes: $0)) }) else { continue }
            accumulators[table, default: makeAccumulator(for: table)].collectExportedSymbol(
                named: name,
                rawOffset: exportedSymbol.offset,
                offsetBase: exportedSymbolOffsetBase
            )
        }

        self.sweptTablesByTable = accumulators.mapValues { $0.freeze(hasExportInformation: hasExportInformation) }
        self.emptyTable = TableAccumulator(mappedStringTableBase: nil, indexesRowsByOffset: false).freeze(hasExportInformation: hasExportInformation)
    }
}

/// What a sweep filed under one table.
@_spi(Internals)
public struct SweptSymbolTable: Sendable {
    public let symbolTable: SymbolTable

    /// Rows by offset — the raw symbol value and, when it differs, the
    /// canonical offset. Empty for a table the routing does not index by
    /// offset.
    public let rowsByOffset: [Int: SymbolRowBucket]

    public let exportFacts: SymbolExportFacts

    /// Whether a local (`N_EXT` clear), non-debug symbol was filed here,
    /// counting one whose name the packed layout refused. `false` for an
    /// image stripped of its local symbols, which keeps only its exports.
    public let hasLocalSymbols: Bool
}

/// The export-trie facts of one swept table.
@_spi(Internals)
public struct SymbolExportFacts: Sendable {
    /// Whether the image's export trie had any entry, whatever the routing
    /// kept. Without one, "not exported" is no distinction worth drawing, so
    /// ``isExported(name:in:)`` answers `nil`.
    public let hasExportInformation: Bool

    /// One bit per row of the table: set when the row's name has an
    /// export-trie entry. Padded to `(rowCount + 63) / 64` words.
    private let exportedRowBitmap: [UInt64]

    /// Exported names with no row: offset-less trie entries (re-exports) and
    /// names whose row the packed layout refused. Expected empty or tiny.
    private let exportedNamesWithoutRows: Set<String>

    init(hasExportInformation: Bool, exportedRowBitmap: [UInt64], exportedNamesWithoutRows: Set<String>) {
        self.hasExportInformation = hasExportInformation
        self.exportedRowBitmap = exportedRowBitmap
        self.exportedNamesWithoutRows = exportedNamesWithoutRows
    }

    /// Whether `row` of the table these facts belong to has an export-trie
    /// entry. `false` when the image carries no export information.
    public func isExported(row: UInt32) -> Bool {
        let rowIndex = Int(row)
        guard rowIndex >> 6 < exportedRowBitmap.count else { return false }
        return exportedRowBitmap[rowIndex >> 6] & (1 << UInt64(rowIndex & 63)) != 0
    }

    /// `nil` when the image carries no export information; otherwise whether
    /// `name` has an export-trie entry. `symbolTable` is the table these
    /// facts belong to.
    public func isExported(name: String, in symbolTable: SymbolTable) -> Bool? {
        guard hasExportInformation else { return nil }
        if let row = symbolTable.row(forName: name) {
            return isExported(row: row)
        }
        return exportedNamesWithoutRows.contains(name)
    }
}

/// One table's state while a sweep runs.
private struct TableAccumulator {
    private var builder: SymbolTableBuilder

    private let indexesRowsByOffset: Bool

    private var rowsByOffset: [Int: SymbolRowBucket] = [:]

    private var hasLocalSymbols = false

    private var exportedRowBitmap: [UInt64] = []

    private var exportedNamesWithoutRows: Set<String> = []

    init(mappedStringTableBase: UnsafeRawPointer?, indexesRowsByOffset: Bool) {
        self.builder = SymbolTableBuilder(mappedStringTableBase: mappedStringTableBase)
        self.indexesRowsByOffset = indexesRowsByOffset
    }

    /// Files a symbol-table entry whose name points into the image's mapped
    /// string table.
    mutating func collectSymbol(
        named name: String,
        mappedNameByteOffset: Int,
        nameByteLength: Int,
        rawOffset: Int,
        canonicalOffset: Int,
        isDebuggingEntry: Bool,
        isLocal: Bool
    ) {
        if isDebuggingEntry {
            builder.reserveRow(forName: name, mappedNameByteOffset: mappedNameByteOffset, nameByteLength: nameByteLength, canonicalOffset: canonicalOffset)
            return
        }
        if isLocal {
            hasLocalSymbols = true
        }
        // A `nil` row means the name's binary-supplied geometry exceeds the
        // packed budgets (a malformed or hostile string table): the symbol is
        // skipped instead of trapping.
        guard let (row, isNewRow) = builder.canonicalRow(
            forName: name,
            mappedNameByteOffset: mappedNameByteOffset,
            nameByteLength: nameByteLength,
            canonicalOffset: canonicalOffset,
            isExternal: false
        ) else { return }
        registerRow(row, rawOffset: rawOffset, canonicalOffset: canonicalOffset, isNewRow: isNewRow)
    }

    /// Files a symbol-table entry whose name goes into the table's private
    /// buffer.
    mutating func collectSymbol(
        named name: String,
        rawOffset: Int,
        canonicalOffset: Int,
        isDebuggingEntry: Bool,
        isLocal: Bool
    ) {
        if isDebuggingEntry {
            builder.reserveRow(forName: name, canonicalOffset: canonicalOffset)
            return
        }
        if isLocal {
            hasLocalSymbols = true
        }
        guard let (row, isNewRow) = builder.canonicalRow(forName: name, canonicalOffset: canonicalOffset, isExternal: false) else { return }
        registerRow(row, rawOffset: rawOffset, canonicalOffset: canonicalOffset, isNewRow: isNewRow)
    }

    /// Records an export-trie entry: its row's bit when the name has a row
    /// already, a new row when the entry carries an offset, and the name
    /// alone otherwise.
    mutating func collectExportedSymbol(named name: String, rawOffset: Int?, offsetBase: Int) {
        if let existingRow = builder.existingRow(forName: name) {
            recordExportedRow(existingRow)
        } else if let rawOffset {
            let canonicalOffset = rawOffset + offsetBase
            // The name has no row yet, so this always mints one. A trie name
            // is a decoded string with no home in the mapped string table, so
            // it takes the private buffer on every reader.
            guard let (row, isNewRow) = builder.canonicalRow(forName: name, canonicalOffset: canonicalOffset, isExternal: false) else {
                // Refused by the packed-reference budget: the export fact
                // still stands, it just has no row.
                exportedNamesWithoutRows.insert(name)
                return
            }
            registerRow(row, rawOffset: rawOffset, canonicalOffset: canonicalOffset, isNewRow: isNewRow)
            recordExportedRow(row)
        } else {
            // An offset-less entry (a re-export): exported, no row.
            exportedNamesWithoutRows.insert(name)
        }
    }

    /// Lists `row` under its raw offset and, when it differs, its canonical
    /// one.
    ///
    /// A row repeats under an offset for two reasons, each headed off without
    /// scanning the bucket: raw and canonical offsets coincide whenever there
    /// is nothing to adjust, which comparing them settles; and two entries of
    /// the same name at the same address (aliases, weak definitions) fold
    /// onto one row, which only an existing row can do — a freshly minted row
    /// index is greater than every row issued so far, so no bucket holds it.
    /// Scanning instead would go quadratic on a degenerate address where
    /// thousands of names pile onto one offset.
    private mutating func registerRow(_ row: UInt32, rawOffset: Int, canonicalOffset: Int, isNewRow: Bool) {
        guard indexesRowsByOffset else { return }
        appendRow(row, atOffset: rawOffset, mayAlreadyBeListed: !isNewRow)
        if canonicalOffset != rawOffset {
            appendRow(row, atOffset: canonicalOffset, mayAlreadyBeListed: !isNewRow)
        }
    }

    private mutating func appendRow(_ row: UInt32, atOffset offset: Int, mayAlreadyBeListed: Bool) {
        if mayAlreadyBeListed, rowsByOffset[offset]?.contains(row) == true {
            return
        }
        rowsByOffset[offset, default: .empty].append(row)
    }

    /// Row indices only grow, so the bitmap grows monotonically; it is padded
    /// to full width at freeze.
    private mutating func recordExportedRow(_ row: UInt32) {
        let wordIndex = Int(row) >> 6
        while exportedRowBitmap.count <= wordIndex {
            exportedRowBitmap.append(0)
        }
        exportedRowBitmap[wordIndex] |= 1 << UInt64(Int(row) & 63)
    }

    func freeze(hasExportInformation: Bool) -> SweptSymbolTable {
        let symbolTable = builder.freeze()
        var exportedRowBitmap = exportedRowBitmap
        let exportedRowBitmapWordCount = (symbolTable.rowCount + 63) / 64
        while exportedRowBitmap.count < exportedRowBitmapWordCount {
            exportedRowBitmap.append(0)
        }
        return SweptSymbolTable(
            symbolTable: symbolTable,
            rowsByOffset: rowsByOffset,
            exportFacts: SymbolExportFacts(
                hasExportInformation: hasExportInformation,
                exportedRowBitmap: exportedRowBitmap,
                exportedNamesWithoutRows: exportedNamesWithoutRows
            ),
            hasLocalSymbols: hasLocalSymbols
        )
    }
}
