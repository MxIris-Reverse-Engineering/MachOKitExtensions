import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import MachODependencies
@testable import CPlusPlusSymbols

/// How many classes, tables and names the class index finds in large
/// images, and how long it takes. Prints the census; asserts what must hold
/// whatever the image's version.
@Suite
struct CPlusPlusClassIndexCensusTests {
    /// A C++ framework built with run-time type information (WebKit's
    /// JavaScriptCore is built without).
    private static let espressoPath = "/System/Library/PrivateFrameworks/Espresso.framework/Versions/A/Espresso"

    /// The iWork frameworks the proposal took its numbers from; set
    /// `CPLUSPLUS_CLASS_CENSUS_FRAMEWORKS` to read them from elsewhere.
    private static let iWorkFrameworksDirectory = ProcessInfo.processInfo.environment["CPLUSPLUS_CLASS_CENSUS_FRAMEWORKS"] ?? "/Volumes/RE/iWork/macOS/14.5/Frameworks"

    private static var tablesPath: String {
        iWorkFrameworksDirectory + "/TSTables.framework/Versions/A/TSTables"
    }

    private static var persistencePath: String {
        iWorkFrameworksDirectory + "/TSPersistence.framework/Versions/A/TSPersistence"
    }

    private struct Census: CustomStringConvertible {
        var label = ""
        var classCount = 0
        var classesWithoutTypeInfoSymbol = 0
        var classesWithVirtualTable = 0
        var tableCount = 0
        var slotCount = 0
        var slotsWithOwnName = 0
        var slotsNamedThroughBase = 0
        var unnamedSlots = 0
        var buildDuration = Duration.zero
        var namingDuration = Duration.zero

        var description: String {
            "\(label): \(classCount) classes (\(classesWithoutTypeInfoSymbol) without a typeinfo symbol, \(classesWithVirtualTable) with a vtable), \(tableCount) tables, \(slotCount) slots — \(slotsWithOwnName) named by their own symbol, \(slotsNamedThroughBase) through a base, \(unnamedSlots) unnamed; index built in \(buildDuration), every slot named in \(namingDuration)"
        }
    }

    /// The slots named through a base, by class and slot.
    nonisolated(unsafe) private static var baseNamedSlotsByLabel: [String: Set<String>] = [:]

    private static func census(of machO: some MachORepresentableWithCache, label: String, tables: (CPlusPlusClassIndexStore, CPlusPlusClass) -> [CPlusPlusVirtualTable]) -> (Census, [String: [Int]]) {
        let store = CPlusPlusClassIndexStore(symbolStore: .shared)
        var census = Census(label: label)
        let clock = ContinuousClock()
        census.buildDuration = clock.measure { store.prepare(in: machO) }
        let classes = store.classes(in: machO)
        census.classCount = classes.count
        census.classesWithoutTypeInfoSymbol = classes.count(where: { !$0.hasTypeInfoSymbol })
        census.classesWithVirtualTable = classes.count(where: \.hasVirtualTable)
        var slotCountsByClass: [String: [Int]] = [:]
        var baseNamedSlots: Set<String> = []
        defer { baseNamedSlotsByLabel[label] = baseNamedSlots }
        census.namingDuration = clock.measure {
            for polymorphicClass in classes {
                let classTables = tables(store, polymorphicClass)
                slotCountsByClass[polymorphicClass.qualifiedName + "@\(polymorphicClass.mangledTypeName)"] = classTables.map(\.functions.count)
                census.tableCount += classTables.count
                for function in classTables.flatMap(\.functions) {
                    census.slotCount += 1
                    if function.symbolName != nil {
                        census.slotsWithOwnName += 1
                    } else if let baseName = function.baseFunction?.name {
                        census.slotsNamedThroughBase += 1
                        baseNamedSlots.insert("\(polymorphicClass.qualifiedName)[\(function.slotIndex)] \(baseName.demangledName)")
                    } else {
                        census.unnamedSlots += 1
                    }
                }
            }
        }
        return (census, slotCountsByClass)
    }

    @Test func classIndexCensusOfEspresso() throws {
        let hostCache = try #require(FullDyldCache.cachedHost)
        let file = try #require(hostCache.machOFile(by: .path(Self.espressoPath)))
        try #require(dlopen(Self.espressoPath, RTLD_NOW) != nil)
        let image = try #require(MachOImage(name: "Espresso"))
        let (fileCensus, fileSlotCounts) = Self.census(of: file, label: "Espresso, MachOFile from the host cache") { $0.virtualTables(of: $1, in: file) }
        let (imageCensus, imageSlotCounts) = Self.census(of: image, label: "Espresso, MachOImage in this process") { $0.virtualTables(of: $1, in: image) }
        print("C++ class index census —\n\(fileCensus)\n\(imageCensus)")
        #expect(fileCensus.classCount > 100)
        #expect(fileCensus.slotCount > 1000)
        #expect(fileCensus.slotsWithOwnName + fileCensus.slotsNamedThroughBase > fileCensus.slotCount / 2)
        // Both readers see the same classes and the same tables.
        let onlyInFile = fileSlotCounts.filter { imageSlotCounts[$0.key] != $0.value }
        let onlyInImage = imageSlotCounts.filter { fileSlotCounts[$0.key] != $0.value }
        #expect(onlyInFile.isEmpty && onlyInImage.isEmpty, "only from the file: \(onlyInFile.prefix(8)); only from the process: \(onlyInImage.prefix(8))")
        #expect(fileCensus.slotsWithOwnName == imageCensus.slotsWithOwnName)
        let fileBaseNamed = Self.baseNamedSlotsByLabel[fileCensus.label] ?? []
        let imageBaseNamed = Self.baseNamedSlotsByLabel[imageCensus.label] ?? []
        // For the first class the readers name differently, what each sees.
        var comparison = ""
        if let firstDifference = imageBaseNamed.subtracting(fileBaseNamed).sorted().first,
           let className = firstDifference.split(separator: "[").first.map(String.init) {
            let store = CPlusPlusClassIndexStore(symbolStore: .shared)
            func describe(_ machO: some MachORepresentableWithCache) -> String {
                guard let polymorphicClass = store.class(named: className, in: machO) else { return "no class" }
                let functions = store.virtualTables(of: polymorphicClass, in: machO).first?.functions.prefix(3) ?? []
                return "bases \(polymorphicClass.bases.map { "\($0.qualifiedName) \($0.location)" }), slots \(functions.map { "\($0.implementation) own \($0.symbolName?.demangledName ?? "-") base \(String(describing: $0.baseFunction))" })"
            }
            comparison = "\(className) — file: \(describe(file)); process: \(describe(image))"
        }
        #expect(fileCensus.slotsNamedThroughBase == imageCensus.slotsNamedThroughBase, "named through a base only in the process: \(imageBaseNamed.subtracting(fileBaseNamed).sorted().prefix(8)); only from the file: \(fileBaseNamed.subtracting(imageBaseNamed).sorted().prefix(8)); \(comparison)")
    }

    /// No group of tables the scan finds runs past the next symbol after
    /// its `__ZTV` symbol: the scan stops at the next object.
    @Test func scannedTableLengthsMatchSymbolBoundsInEspresso() throws {
        try #require(dlopen(Self.espressoPath, RTLD_NOW) != nil)
        let image = try #require(MachOImage(name: "Espresso"))
        let store = CPlusPlusClassIndexStore(symbolStore: .shared)
        let symbolOffsets = Set(image.symbols.map(\.offset)).sorted()
        func nextSymbolOffset(after offset: Int) -> Int? {
            var low = 0
            var high = symbolOffsets.count
            while low < high {
                let middle = (low + high) / 2
                if symbolOffsets[middle] <= offset { low = middle + 1 } else { high = middle }
            }
            return low < symbolOffsets.count ? symbolOffsets[low] : nil
        }
        var checkedCount = 0
        var exactCount = 0
        var overruns: [String] = []
        for polymorphicClass in store.classes(in: image) where polymorphicClass.hasVirtualTable {
            guard let virtualTableSymbol = CPlusPlusSymbolIndexStore.shared.symbol(named: "__ZTV" + polymorphicClass.mangledTypeName, in: image),
                  let next = nextSymbolOffset(after: virtualTableSymbol.offset),
                  let lastTable = store.virtualTables(of: polymorphicClass, in: image).last else {
                continue
            }
            checkedCount += 1
            let groupEnd = lastTable.addressPointOffset + 8 * lastTable.functions.count
            if groupEnd > next {
                overruns.append("\(polymorphicClass.qualifiedName): ends at \(groupEnd), next symbol at \(next)")
            } else if groupEnd == next {
                exactCount += 1
            }
        }
        print("vtable bounds — \(checkedCount) groups checked against the next symbol, \(exactCount) end exactly there, \(overruns.count) run past it")
        #expect(checkedCount > 100)
        #expect(overruns.isEmpty, "\(overruns.prefix(5))")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: tablesPath)))
    func classIndexCensusOfTSTables() throws {
        let tables = try ClassIndexTestImages.hostSlice(of: URL(fileURLWithPath: Self.tablesPath))
        let searchPaths: [DependencySearchPath] = [.machOFile(path: Self.persistencePath), .systemDyldSharedCache]
        let (census, _) = Self.census(of: tables, label: "TSTables (iWork 14.5)") { $0.virtualTables(of: $1, in: tables, dependencySearchPaths: searchPaths) }
        print("C++ class index census —\n\(census)")
        // A protobuf message class: its slots follow `google::protobuf::Message`
        // of TSPersistence.
        let store = CPlusPlusClassIndexStore(symbolStore: .shared)
        if let cellID = store.class(named: "TST::CellID", in: tables) {
            let primary = store.virtualTables(of: cellID, in: tables, dependencySearchPaths: searchPaths).first
            print("TST::CellID bases \(cellID.bases.map { "\($0.qualifiedName) \($0.location)" }) —\n" + (primary?.functions.map { "\($0.slotIndex) \($0.implementation) own \($0.symbolName?.demangledName ?? "-") base \($0.baseFunction.map { "\($0.className) \($0.name?.demangledName ?? "-") inherited \($0.isInherited)" } ?? "-")" }.joined(separator: "\n") ?? "no table"))
        }
        #if arch(arm64)
        // The arm64 slice the proposal counted.
        #expect(census.classCount == 611)
        #expect(census.classesWithoutTypeInfoSymbol == 167)
        #expect(census.classesWithVirtualTable == 606)
        #expect(census.slotsNamedThroughBase >= 2163)
        #endif
    }
}
