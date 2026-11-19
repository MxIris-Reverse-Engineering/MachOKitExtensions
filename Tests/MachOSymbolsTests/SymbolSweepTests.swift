import Foundation
import Testing
import MachOKit
import MachOKitExtensions
@_spi(Internals) @testable import MachOSymbols

/// Files C++ names under `.cPlusPlus`, the Objective-C runtime stand-in's
/// names under `.objectiveCRuntime` (not indexed by offset) and C names under
/// `.other`. Sweeps with it use ``StandInRecognition/objectiveCRuntimeRegistry``.
private struct LanguageRouting: SymbolTableRouting {
    enum Table: Hashable, Sendable {
        case cPlusPlus
        case objectiveCRuntime
        case other
    }

    var mayReferenceStringTablesOfLoadedImages: Bool

    func table(forSymbolNamed name: UnsafePointer<CChar>, language: SymbolLanguage) -> Table? {
        switch language {
        case .cPlusPlus:
            .cPlusPlus
        case .objectiveCRuntimeStandIn:
            .objectiveCRuntime
        default:
            .other
        }
    }

    func offsetIndexing(in table: Table) -> SymbolOffsetIndexing {
        table == .objectiveCRuntime ? .nameOnly : .byOffset
    }
}

private let languageRegistry = StandInRecognition.objectiveCRuntimeRegistry

/// Files every name, Swift included, under one table, indexed as asked.
private struct EverythingRouting: SymbolTableRouting {
    enum Table: Hashable, Sendable {
        case all
    }

    var indexing: SymbolOffsetIndexing = .byOffset

    var mayReferenceStringTablesOfLoadedImages: Bool { true }

    func table(forSymbolNamed name: UnsafePointer<CChar>, language: SymbolLanguage) -> Table? {
        .all
    }

    func offsetIndexing(in table: Table) -> SymbolOffsetIndexing {
        indexing
    }
}

/// Files the Objective-C runtime stand-in's names as offsets alone, and
/// every other name with rows — the shape of the C/C++ store's routing.
private struct BoundaryRouting: SymbolTableRouting {
    enum Table: Hashable, Sendable {
        case symbols
        case boundaries
    }

    var mayReferenceStringTablesOfLoadedImages: Bool { false }

    func table(forSymbolNamed name: UnsafePointer<CChar>, language: SymbolLanguage) -> Table? {
        language == .objectiveCRuntimeStandIn ? .boundaries : .symbols
    }

    func offsetIndexing(in table: Table) -> SymbolOffsetIndexing {
        table == .boundaries ? .sortedOffsetsOnly : .byOffsetWithSortedOffsets
    }
}

/// A Mach-O file without an export trie: an object file carries `LC_SYMTAB`
/// alone. (The kernel would too, but MachOKit cannot read its segment
/// addresses, which do not fit an `Int`.)
private let objectFilePath = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/lazydylib1.o"

@Suite
struct SymbolSweepTests {
    private static func loadedImage(named name: String) throws -> MachOImage {
        try #require(MachOImage(name: name), "\(name) is not loaded")
    }

    /// The arm64e slice of `/usr/bin/curl`: a main executable, whose
    /// `__TEXT` sits at 0x100000000, so a symbol value and the file offset
    /// the sweep files it under differ.
    private static func curl() throws -> MachOFile {
        switch try MachOKit.loadFromFile(url: URL(fileURLWithPath: "/usr/bin/curl")) {
        case .machO(let machOFile):
            return machOFile
        case .fat(let fatFile):
            let machOFiles = try fatFile.machOFiles()
            return try #require(machOFiles.first { $0.header.cpuType == .arm64 } ?? machOFiles.first)
        }
    }

    @Test func sweepFilesEachNameIntoTheTableItsRoutingChooses() throws {
        let sweep = SymbolSweep(sweeping: try Self.loadedImage(named: "Foundation"), routing: LanguageRouting(mayReferenceStringTablesOfLoadedImages: false), languageRegistry: languageRegistry)
        let expectedLanguagesByTable: [(LanguageRouting.Table, Set<SymbolLanguage>)] = [
            (.cPlusPlus, [.cPlusPlus]),
            (.objectiveCRuntime, [.objectiveCRuntimeStandIn]),
            (.other, [.c]),
        ]
        for (table, expectedLanguages) in expectedLanguagesByTable {
            let symbolTable = sweep[table].symbolTable
            var misfiledCount = 0
            for row in 0 ..< symbolTable.rowCount where !expectedLanguages.contains(SymbolLanguage(ofSymbolNamed: symbolTable.materializedName(atRow: UInt32(row)), registry: languageRegistry)) {
                misfiledCount += 1
            }
            #expect(misfiledCount == 0, "\(table)")
        }
        #expect(sweep[.objectiveCRuntime].symbolTable.rowCount > 0)
        #expect(sweep[.other].symbolTable.rowCount > 0)
    }

    /// The same image swept with and without the stand-in registered: its
    /// Objective-C runtime names leave the C table only when the registry the
    /// sweep is given knows them.
    @Test func sweepClassifiesThroughTheRegistryItIsGiven() throws {
        let foundation = try Self.loadedImage(named: "Foundation")
        let routing = LanguageRouting(mayReferenceStringTablesOfLoadedImages: false)
        let withStandIn = SymbolSweep(sweeping: foundation, routing: routing, languageRegistry: languageRegistry)
        let withoutStandIn = SymbolSweep(sweeping: foundation, routing: routing, languageRegistry: SymbolLanguageRegistry())
        let runtimeNameCount = withStandIn[.objectiveCRuntime].symbolTable.rowCount
        try #require(runtimeNameCount > 0)
        #expect(withoutStandIn[.objectiveCRuntime].symbolTable.rowCount == 0)
        #expect(withoutStandIn[.other].symbolTable.rowCount == withStandIn[.other].symbolTable.rowCount + runtimeNameCount)
    }

    @Test func sweepSkipsImportedSymbols() throws {
        let curl = try Self.curl()
        let definedNames = Set(curl.symbols.filter { !$0.nlist.isExternal }.map(\.name))
        let importedNames = curl.symbols.filter { $0.nlist.isExternal && !definedNames.contains($0.name) }.map(\.name)
        try #require(!importedNames.isEmpty)

        let sweep = SymbolSweep(sweeping: curl, routing: EverythingRouting())
        let filedImports = importedNames.filter { sweep[.all].symbolTable.row(forName: $0) != nil }
        #expect(filedImports.isEmpty, "\(filedImports.prefix(3))")
    }

    @Test func tableNotIndexedByOffsetHasNoOffsetRows() throws {
        let sweep = SymbolSweep(sweeping: try Self.loadedImage(named: "Foundation"), routing: LanguageRouting(mayReferenceStringTablesOfLoadedImages: false), languageRegistry: languageRegistry)
        #expect(sweep[.objectiveCRuntime].symbolTable.rowCount > 0)
        #expect(sweep[.objectiveCRuntime].rowsByOffset.isEmpty)
        #expect(!sweep[.other].rowsByOffset.isEmpty)
    }

    /// A debug build of this test bundle keeps its debug map: an `N_GSYM` /
    /// `N_FUN` entry under the very name of a symbol it describes. The entry
    /// must not move the symbol's row to its own value.
    @Test func debugEntryReservesARowWithoutAnOffset() throws {
        let image = MachOImage.current()
        var realOffsetByName: [String: Int] = [:]
        var debugEntryNames: Set<String> = []
        for symbol in image.symbols where !symbol.nlist.isExternal {
            if symbol.nlist.isDebuggingEntry {
                debugEntryNames.insert(symbol.name)
            } else {
                realOffsetByName[symbol.name] = symbol.offset
            }
        }
        let describedNames = debugEntryNames.filter { realOffsetByName[$0] != nil }
        try #require(!describedNames.isEmpty, "this test bundle carries no debug map; run a debug build")

        let symbolTable = SymbolSweep(sweeping: image, routing: EverythingRouting())[.all].symbolTable
        var movedCount = 0
        for name in describedNames {
            let row = try #require(symbolTable.row(forName: name))
            if symbolTable.canonicalOffset(atRow: row) != realOffsetByName[name] {
                movedCount += 1
            }
        }
        #expect(movedCount == 0)
    }

    /// The table the in-place leg builds is the one the `String` surface
    /// gives: last-wins offset per routed name, then export-trie names with
    /// an offset the symbol table did not list.
    @Test func mappedAndDecodedLegsYieldTheSameTable() throws {
        let image = try Self.loadedImage(named: "Foundation")
        let symbolTable = SymbolSweep(sweeping: image, routing: LanguageRouting(mayReferenceStringTablesOfLoadedImages: true), languageRegistry: languageRegistry)[.other].symbolTable

        var expectedOffsetByName: [String: Int] = [:]
        for symbol in image.symbols where !symbol.nlist.isExternal && !symbol.nlist.isDebuggingEntry && SymbolLanguage(ofSymbolNamed: symbol.name, registry: languageRegistry) == .c {
            expectedOffsetByName[symbol.name] = symbol.offset
        }
        for exportedSymbol in image.exportedSymbols where SymbolLanguage(ofSymbolNamed: exportedSymbol.name, registry: languageRegistry) == .c {
            if let offset = exportedSymbol.offset, expectedOffsetByName[exportedSymbol.name] == nil {
                expectedOffsetByName[exportedSymbol.name] = offset
            }
        }

        #expect(symbolTable.rowCount == expectedOffsetByName.count)
        var mismatchCount = 0
        for row in 0 ..< symbolTable.rowCount {
            let name = symbolTable.materializedName(atRow: UInt32(row))
            if expectedOffsetByName[name] != symbolTable.canonicalOffset(atRow: UInt32(row)) {
                mismatchCount += 1
            }
        }
        #expect(mismatchCount == 0)
    }

    @Test func nameLookupFindsEveryRowByBinarySearch() throws {
        for routing in [LanguageRouting(mayReferenceStringTablesOfLoadedImages: true), LanguageRouting(mayReferenceStringTablesOfLoadedImages: false)] {
            let symbolTable = SymbolSweep(sweeping: try Self.loadedImage(named: "Foundation"), routing: routing, languageRegistry: languageRegistry)[.other].symbolTable
            try #require(symbolTable.rowCount > 0)
            var mismatchCount = 0
            for row in 0 ..< symbolTable.rowCount where symbolTable.row(forName: symbolTable.materializedName(atRow: UInt32(row))) != UInt32(row) {
                mismatchCount += 1
            }
            #expect(mismatchCount == 0)
            #expect(symbolTable.row(forName: "_NotARealSymbolName999AtAll") == nil)
            #expect(symbolTable.row(forName: "") == nil)
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: objectFilePath)))
    func exportFactsAreNilForAnImageWithoutAnExportTrie() throws {
        let objectFile: MachOFile
        switch try MachOKit.loadFromFile(url: URL(fileURLWithPath: objectFilePath)) {
        case .machO(let machOFile):
            objectFile = machOFile
        case .fat(let fatFile):
            objectFile = try #require(try fatFile.machOFiles().first)
        }
        let swept = SymbolSweep(sweeping: objectFile, routing: EverythingRouting())[.all]
        try #require(swept.symbolTable.rowCount > 0)
        #expect(!swept.exportFacts.hasExportInformation)
        #expect(swept.exportFacts.isExported(name: swept.symbolTable.materializedName(atRow: 0), in: swept.symbolTable) == nil)
    }

    @Test func everyRoutedExportTrieNameWithAnOffsetHasAnExportedRow() throws {
        let curl = try Self.curl()
        let swept = SymbolSweep(sweeping: curl, routing: EverythingRouting())[.all]
        #expect(swept.exportFacts.hasExportInformation)
        var missingCount = 0
        var exportedNamesChecked = 0
        for exportedSymbol in curl.exportedSymbols where exportedSymbol.offset != nil {
            exportedNamesChecked += 1
            if swept.exportFacts.isExported(name: exportedSymbol.name, in: swept.symbolTable) != true || swept.symbolTable.row(forName: exportedSymbol.name) == nil {
                missingCount += 1
            }
        }
        #expect(exportedNamesChecked > 0)
        #expect(missingCount == 0)
    }

    /// A name the image defines but does not export answers `false`. `curl`
    /// keeps no local symbol, so this reads the test bundle itself.
    @Test func localSymbolIsNotExported() throws {
        let image = MachOImage.current()
        let swept = SymbolSweep(sweeping: image, routing: EverythingRouting())[.all]
        try #require(swept.exportFacts.hasExportInformation)
        let localName = try #require(image.symbols.first { $0.nlist.isLocal && !$0.nlist.isDebuggingEntry }?.name)
        #expect(swept.exportFacts.isExported(name: localName, in: swept.symbolTable) == false)
    }

    /// A main executable files a symbol under the file offset its segment
    /// maps the value to, and lists the row under the raw value too. `curl`
    /// keeps one defined symbol, its mach header, valued 0x100000000.
    @Test func fileRowsAreFiledUnderTheirFileOffset() throws {
        let curl = try Self.curl()
        let main = try #require(curl.symbols.first { $0.name == "__mh_execute_header" && !$0.nlist.isExternal })
        let swept = SymbolSweep(sweeping: curl, routing: EverythingRouting())[.all]
        let row = try #require(swept.symbolTable.row(forName: "__mh_execute_header"))
        let fileOffset = swept.symbolTable.canonicalOffset(atRow: row)
        #expect(fileOffset != main.offset)
        #expect(fileOffset == SymbolValueOffsetConverter(for: curl).offset(forSymbolValue: main.offset))
        #expect(swept.rowsByOffset[fileOffset]?.contains(row) == true)
        #expect(swept.rowsByOffset[main.offset]?.contains(row) == true)
    }

    @Test func cacheImageRowsPointIntoTheMappedStringTable() throws {
        let image = try Self.loadedImage(named: "Foundation")
        try #require(image.header.isInDyldCache)
        let sweep = SymbolSweep(sweeping: image, routing: LanguageRouting(mayReferenceStringTablesOfLoadedImages: false), languageRegistry: languageRegistry)
        #expect(sweep[.other].symbolTable.mappedStringTableBase != nil)
    }

    @Test func imageOutsideTheCacheCopiesNamesUnlessTheRoutingAllowsMapping() throws {
        let image = MachOImage.current()
        try #require(!image.header.isInDyldCache)
        let copying = SymbolSweep(sweeping: image, routing: LanguageRouting(mayReferenceStringTablesOfLoadedImages: false), languageRegistry: languageRegistry)[.other].symbolTable
        let mapping = SymbolSweep(sweeping: image, routing: LanguageRouting(mayReferenceStringTablesOfLoadedImages: true), languageRegistry: languageRegistry)[.other].symbolTable
        try #require(copying.rowCount > 0)
        #expect(copying.mappedStringTableBase == nil)
        #expect(mapping.mappedStringTableBase != nil)
        #expect(copying.rowCount == mapping.rowCount)
        for row in 0 ..< copying.rowCount {
            #expect(copying.materializedName(atRow: UInt32(row)) == mapping.materializedName(atRow: UInt32(row)))
        }
    }
}

extension SymbolSweepTests {
    /// Sorted offsets cost an integer per offset, so a table keeps them only
    /// when its routing asks; and they are canonical offsets only — a file's
    /// raw symbol values, virtual addresses, are not among them.
    @Test func sortedCanonicalOffsetsAreKeptOnlyWhenAsked() throws {
        let curl = try Self.curl()
        let withoutOrder = SymbolSweep(sweeping: curl, routing: EverythingRouting())[.all]
        #expect(withoutOrder.sortedCanonicalOffsets.isEmpty)
        #expect(!withoutOrder.rowsByOffset.isEmpty)

        let withOrder = SymbolSweep(sweeping: curl, routing: EverythingRouting(indexing: .byOffsetWithSortedOffsets))[.all]
        #expect(withOrder.sortedCanonicalOffsets == [0])
        #expect(withOrder.rowsByOffset[0x1_0000_0000] != nil)

        let foundation = SymbolSweep(sweeping: try Self.loadedImage(named: "Foundation"), routing: EverythingRouting(indexing: .byOffsetWithSortedOffsets))[.all]
        let offsets = foundation.sortedCanonicalOffsets
        #expect(offsets.count > 1)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
        #expect(Set(offsets) == Set(foundation.rowsByOffset.keys))
    }
}

extension SymbolSweepTests {
    /// The canonical offsets a table that keeps no rows should hold for
    /// `image`: those of every defined, non-debug symbol-table entry
    /// `recognizes` accepts. The export trie adds none.
    private static func expectedOffsets(of image: MachOImage, where recognizes: (UnsafePointer<CChar>) -> Bool) -> Set<Int> {
        var offsets: Set<Int> = []
        for symbol in image.symbols where !symbol.nlist.isExternal && !symbol.nlist.isDebuggingEntry && symbol.name.withCString(recognizes) {
            offsets.insert(symbol.offset)
        }
        return offsets
    }

    @Test func sortedOffsetsOnlyTableKeepsOffsetsButNoRows() throws {
        let foundation = try Self.loadedImage(named: "Foundation")
        let sweep = SymbolSweep(sweeping: foundation, routing: BoundaryRouting(), languageRegistry: languageRegistry)
        let boundaries = sweep[.boundaries]
        #expect(boundaries.symbolTable.rowCount == 0)
        #expect(boundaries.rowsByOffset.isEmpty)
        #expect(!boundaries.hasLocalSymbols)
        let offsets = boundaries.sortedCanonicalOffsets
        try #require(!offsets.isEmpty)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
        #expect(Set(offsets) == Self.expectedOffsets(of: foundation, where: StandInRecognition.isObjectiveCRuntimeSymbol))
        // The names went nowhere else either.
        #expect(sweep[.symbols].symbolTable.row(forName: "_OBJC_CLASS_$_NSObject") == nil)
    }

    /// A debug-map entry names no offset, and a file's raw symbol value — a
    /// virtual address — is not an offset.
    @Test func sortedOffsetsOnlyTableSkipsDebugEntriesAndRawAddresses() throws {
        let curl = try Self.curl()
        let curlOffsets = SymbolSweep(sweeping: curl, routing: EverythingRouting(indexing: .sortedOffsetsOnly))[.all]
        #expect(curlOffsets.sortedCanonicalOffsets == [0])
        #expect(curlOffsets.symbolTable.rowCount == 0)

        let image = MachOImage.current()
        try #require(image.symbols.contains { $0.nlist.isDebuggingEntry }, "this test bundle carries no debug map; run a debug build")
        let imageOffsets = SymbolSweep(sweeping: image, routing: EverythingRouting(indexing: .sortedOffsetsOnly))[.all].sortedCanonicalOffsets
        #expect(Set(imageOffsets) == Self.expectedOffsets(of: image, where: { _ in true }))
    }
}
