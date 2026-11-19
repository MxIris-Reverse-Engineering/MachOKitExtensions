import Foundation
import Testing
import MachOKit
import MachOKitExtensions
@_spi(Internals) import MachOSymbols
@testable import CPlusPlusSymbols

@Suite
struct CPlusPlusSymbolIndexCensusTests {
    /// How large and how slow the index of a C++-heavy framework is, read
    /// out of the host's dyld shared cache as a file and loaded in this
    /// process. Prints the census; asserts only that each reader indexed C++
    /// symbols into scopes of every kind.
    @Test func cPlusPlusSymbolIndexCensusOfALargeImage() throws {
        let javaScriptCorePath = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore"
        let hostCache = try #require(FullDyldCache.cachedHost)
        let javaScriptCoreFile = try #require(hostCache.machOFile(by: .path(javaScriptCorePath)))
        try #require(dlopen(javaScriptCorePath, RTLD_NOW) != nil)
        let javaScriptCoreImage = try #require(MachOImage(name: "JavaScriptCore"))

        var censusLines: [String] = []
        func census(of machO: some MachORepresentableWithCache, label: String) throws -> CPlusPlusSymbolIndexStore.Storage {
            // A store of its own, so that the build is measured from scratch.
            let store = CPlusPlusSymbolIndexStore(languageRegistry: .shared)
            let clock = ContinuousClock()
            var storage: CPlusPlusSymbolIndexStore.Storage?
            let buildDuration = clock.measure { storage = store.storage(in: machO) }
            let builtStorage = try #require(storage)
            let symbolTable = builtStorage.sweptSymbols.symbolTable
            var scopeCountByKind: [String: Int] = [:]
            var treeByteCount = 0
            for record in builtStorage.scopes {
                scopeCountByKind[record.scope.kind.description, default: 0] += 1
                treeByteCount += MemoryLayout<CPlusPlusSymbolIndexStore.Storage.ScopeRecord>.stride
                treeByteCount += record.scope.path.count * MemoryLayout<String>.stride
                treeByteCount += record.scope.name.utf8.count + record.scope.baseName.utf8.count + record.scope.qualifiedName.utf8.count
                treeByteCount += record.childIndices.count * MemoryLayout<Int>.stride + record.memberRows.count * MemoryLayout<UInt32>.stride
            }
            let offsetIndexByteCount = builtStorage.sweptSymbols.rowsByOffset.count * (MemoryLayout<Int>.stride + MemoryLayout<SymbolRowBucket>.stride)
            let kinds = scopeCountByKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let unparsedExamples = builtStorage.unparsedRows.prefix(3).map { symbolTable.materializedName(atRow: $0) }
            censusLines.append("\(label): \(symbolTable.rowCount) C++ rows, \(builtStorage.unparsedRows.count) unparsed (such as \(unparsedExamples)),\(builtStorage.scopes.count) scopes (\(kinds)); built in \(buildDuration); table \(symbolTable.retainedByteCount) bytes (copied names \(symbolTable.privateNameByteCount)), offset index ≥ \(offsetIndexByteCount) bytes, scope tree ≈ \(treeByteCount) bytes")
            return builtStorage
        }
        let fileStorage = try census(of: javaScriptCoreFile, label: "JavaScriptCore, MachOFile from the host cache")
        let imageStorage = try census(of: javaScriptCoreImage, label: "JavaScriptCore, MachOImage in this process")
        print("C++ symbol index census —\n" + censusLines.joined(separator: "\n"))

        for storage in [fileStorage, imageStorage] {
            #expect(storage.sweptSymbols.symbolTable.rowCount > 1000)
            let kinds = Set(storage.scopes.map(\.scope.kind))
            #expect(kinds.isSuperset(of: [.namespace, .type, .undetermined]))
        }

        // A name is left unparsed only when the demangler itself rejects it,
        // never because the classification gave up on a name it parsed.
        let unparsedNames = imageStorage.unparsedRows.map(imageStorage.plainSymbol(atRow:)).map(\.name)
        let namesTheSystemDemangles = try unparsedNames.filter { try Self.systemDemangles($0) }
        #expect(namesTheSystemDemangles.isEmpty, "the system demangler parses \(namesTheSystemDemangles.count) of them: \(namesTheSystemDemangles.prefix(5))")
    }

    private typealias SystemDemangle = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>?

    /// Whether libc++abi's `__cxa_demangle` parses `mangledName`.
    private static func systemDemangles(_ mangledName: String) throws -> Bool {
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__cxa_demangle"), "__cxa_demangle is not loaded")
        let systemDemangle = unsafeBitCast(symbol, to: SystemDemangle.self)
        var status: Int32 = 0
        guard let demangled = mangledName.withCString({ systemDemangle($0, nil, nil, &status) }) else { return false }
        free(demangled)
        return true
    }
}
