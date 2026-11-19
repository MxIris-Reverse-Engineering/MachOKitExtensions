import Foundation
import Testing
import MachOKit
import MachOKitExtensions
@_spi(Internals) @testable import MachOSymbols

private let objectFilePath = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/lazydylib1.o"

@Suite
struct SymbolIndexStoreTests {
    private static let store = SymbolIndexStore.shared

    private static func loadedImage(named name: String) throws -> MachOImage {
        try #require(MachOImage(name: name), "\(name) is not loaded")
    }

    /// The arm64e slice of a system binary.
    private static func machOFile(atPath path: String) throws -> MachOFile {
        switch try MachOKit.loadFromFile(url: URL(fileURLWithPath: path)) {
        case .machO(let machOFile):
            return machOFile
        case .fat(let fatFile):
            let machOFiles = try fatFile.machOFiles()
            return try #require(machOFiles.first { $0.header.cpuType == .arm64 } ?? machOFiles.first)
        }
    }

    /// Defined, non-debug C symbols of `image`, with the offsets the store
    /// files them under.
    private static func definedCSymbols(of image: MachOImage) -> [(name: String, offset: Int)] {
        image.symbols.compactMap { symbol in
            guard !symbol.nlist.isExternal, !symbol.nlist.isDebuggingEntry,
                  SymbolLanguage(ofSymbolNamed: symbol.name) == .c else { return nil }
            return (symbol.name, symbol.offset)
        }
    }

    /// `curl` is a main executable: its `__TEXT` sits at 0x100000000, and
    /// the one symbol its table keeps defined, the mach header, is filed at
    /// file offset 0, not at its value.
    @Test func storeFindsTheMachHeaderByNameInAnExecutable() throws {
        let curl = try Self.machOFile(atPath: "/usr/bin/curl")
        #expect(Self.store.offset(ofSymbolNamed: "__mh_execute_header", in: curl) == 0)
        #expect(Self.store.containsSymbol(named: "__mh_execute_header", in: curl))
        #expect(!Self.store.containsSymbol(named: "_not_a_symbol_of_curl", in: curl))
    }

    @Test func storeFindsSymbolsAtAnExactOffset() throws {
        let foundation = try Self.loadedImage(named: "Foundation")
        let functions = Self.definedCSymbols(of: foundation)
        try #require(!functions.isEmpty)
        var missingCount = 0
        for function in functions.prefix(500) {
            let symbols = Self.store.symbols(for: function.offset, in: foundation)
            if symbols?.offset != function.offset || symbols?.contains(where: { $0.name == function.name }) != true {
                missingCount += 1
            }
        }
        #expect(missingCount == 0)
    }

    @Test func closestSymbolsReturnsTheEnclosingFunction() throws {
        let foundation = try Self.loadedImage(named: "Foundation")
        let functions = Self.definedCSymbols(of: foundation)
        try #require(!functions.isEmpty)
        let functionOffsets = Set(functions.map(\.offset))
        var wrongCount = 0
        // An arm64 instruction one byte in never starts another function.
        for function in functions.prefix(500) where !functionOffsets.contains(function.offset + 1) {
            let closest = Self.store.closestSymbols(at: function.offset + 1, in: foundation)
            if closest?.offset != function.offset || closest?.contains(where: { $0.name == function.name }) != true {
                wrongCount += 1
            }
        }
        #expect(wrongCount == 0)
        #expect(Self.store.closestSymbols(at: Int.min, in: foundation) == nil)
    }

    /// A file's offset index also lists each row under its raw symbol value;
    /// the nearest-offset search must not take that virtual address for an
    /// offset.
    @Test func closestSymbolsIgnoresRawVirtualAddressKeys() throws {
        let curl = try Self.machOFile(atPath: "/usr/bin/curl")
        let closest = try #require(Self.store.closestSymbols(at: 0x1_0000_0010, in: curl))
        #expect(closest.offset == 0)
        #expect(closest.contains { $0.name == "__mh_execute_header" })
    }

    /// Nothing registers Swift on the shared registry in this test process,
    /// so the shared store files libswiftCore's Swift names as C.
    @Test func storeFilesUnregisteredLanguagesAsC() throws {
        let swiftCore = try Self.loadedImage(named: "libswiftCore")
        var swiftNameCount = 0
        var filedSwiftNameCount = 0
        for symbol in swiftCore.symbols where !symbol.nlist.isExternal && !symbol.nlist.isDebuggingEntry
            && symbol.name.withCString(StandInRecognition.isSwiftSymbol) {
            swiftNameCount += 1
            if Self.store.containsSymbol(named: symbol.name, in: swiftCore) {
                filedSwiftNameCount += 1
            }
        }
        #expect(swiftNameCount > 0)
        #expect(filedSwiftNameCount == swiftNameCount)
    }

    @Test func storeAnswersIsExportedTriState() throws {
        let curl = try Self.machOFile(atPath: "/usr/bin/curl")
        #expect(Self.store.hasExportInformation(in: curl))
        #expect(Self.store.isExported(name: "__mh_execute_header", in: curl) == true)
        #expect(Self.store.isExported(name: "_not_a_symbol_of_curl", in: curl) == false)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: objectFilePath)))
    func storeAnswersNilWithoutExportInformation() throws {
        let objectFile = try Self.machOFile(atPath: objectFilePath)
        #expect(!Self.store.hasExportInformation(in: objectFile))
        #expect(Self.store.containsSymbol(named: "_dyld_lazy_dylib_proxy", in: objectFile))
        #expect(Self.store.isExported(name: "_dyld_lazy_dylib_proxy", in: objectFile) == nil)
    }

    /// `zip` is a binary no other test reads, so this test owns its entry.
    @Test func storeIsBuiltOnceAndSharedAcrossCallers() throws {
        let zip = try Self.machOFile(atPath: "/usr/bin/zip")
        Self.store.remove(for: zip)
        #expect(!Self.store.contains(in: zip))
        let first = try #require(Self.store.storage(in: zip))
        #expect(Self.store.contains(in: zip))
        let second = try #require(Self.store.storage(in: try Self.machOFile(atPath: "/usr/bin/zip")))
        #expect(first === second)

        Self.store.remove(for: zip)
        #expect(!Self.store.contains(in: zip))
        let rebuilt = try #require(Self.store.storage(in: zip))
        #expect(rebuilt !== first)
    }
}

extension SymbolIndexStoreTests {
    /// How large the index of a framework-scale image is, read out of the
    /// host's dyld shared cache as a file and loaded in this process. Prints
    /// the census; asserts only that each reader indexed something, and that
    /// the loaded image's names stayed in its string table.
    ///
    /// Measured with Swift and Objective-C runtime names registered, as in a
    /// process that links MachOSwiftSection and MachOObjCSection: without
    /// them, Swift names an image only exports count as C, and their names
    /// are copied.
    @Test func symbolIndexCensusOfALargeImage() throws {
        let store = SymbolIndexStore(languageRegistry: StandInRecognition.swiftAndObjectiveCRuntimeRegistry)
        let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
        let hostCache = try #require(FullDyldCache.cachedHost)
        let appKitFile = try #require(hostCache.machOFile(by: .path(appKitPath)))
        try #require(dlopen(appKitPath, RTLD_NOW) != nil)
        let appKitImage = try #require(MachOImage(name: "AppKit"))

        var censusLines: [String] = []
        func census(of storage: SymbolIndexStore.Storage, label: String) {
            let swept = storage.sweptSymbols
            let symbolTable = swept.symbolTable
            let offsetIndexByteCount = swept.rowsByOffset.count * (MemoryLayout<Int>.stride + MemoryLayout<SymbolRowBucket>.stride)
            let sortedOffsetsByteCount = swept.sortedCanonicalOffsets.count * MemoryLayout<Int>.stride
            censusLines.append("\(label): \(symbolTable.rowCount) rows, table \(symbolTable.retainedByteCount) bytes (copied names \(symbolTable.privateNameByteCount)), \(swept.rowsByOffset.count) offsets (≥ \(offsetIndexByteCount) bytes), sorted offsets \(sortedOffsetsByteCount) bytes")
        }
        let fileStorage = try #require(store.storage(in: appKitFile))
        let imageStorage = try #require(store.storage(in: appKitImage))
        census(of: fileStorage, label: "AppKit, MachOFile from the host cache")
        census(of: imageStorage, label: "AppKit, MachOImage in this process")
        print("C and C++ symbol index census —\n" + censusLines.joined(separator: "\n"))

        #expect(fileStorage.sweptSymbols.symbolTable.rowCount > 0)
        #expect(imageStorage.sweptSymbols.symbolTable.rowCount > 0)
        #expect(imageStorage.sweptSymbols.symbolTable.privateNameByteCount == 0)
    }
}
