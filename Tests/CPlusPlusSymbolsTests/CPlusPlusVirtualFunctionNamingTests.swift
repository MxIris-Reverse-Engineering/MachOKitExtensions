import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import MachODependencies
@testable import CPlusPlusSymbols

/// Naming a vtable slot after the base class function it overrides or
/// inherits: the rule on made-up classes, then across two compiled
/// libraries whose derived class is stripped of its names.
@Suite
struct CPlusPlusVirtualFunctionNamingTests {
    // MARK: The rule

    /// Classes `Root` ← `Middle` ← `Leaf`, each a list of slots.
    private struct MadeUpHierarchy {
        var slotsByClass: [String: [VirtualFunctionNaming<String>.Slot]] = [:]
        var primaryBaseByClass: [String: String] = [:]

        var naming: VirtualFunctionNaming<String> {
            VirtualFunctionNaming(
                primaryBase: { primaryBaseByClass[$0] },
                className: { $0 },
                primarySlots: { slotsByClass[$0] }
            )
        }

        static func slot(_ mangledName: String?, at offset: Int) -> VirtualFunctionNaming<String>.Slot {
            .init(
                name: mangledName.flatMap(CPlusPlusSymbolName.init(mangledName:)),
                identity: ImplementationIdentity(location: .local(imagePath: "made-up", offset: offset), mangledName: mangledName)
            )
        }
    }

    private static func madeUpHierarchy() -> MadeUpHierarchy {
        var hierarchy = MadeUpHierarchy()
        hierarchy.slotsByClass["Root"] = [MadeUpHierarchy.slot("__ZN4Root3runEv", at: 0x100)]
        // `Middle` overrides `run`, and its override has no name.
        hierarchy.slotsByClass["Middle"] = [MadeUpHierarchy.slot(nil, at: 0x200), MadeUpHierarchy.slot(nil, at: 0x210)]
        hierarchy.primaryBaseByClass["Middle"] = "Root"
        return hierarchy
    }

    @Test func anUnnamedSlotTakesItsNameFromTheBase() throws {
        let naming = Self.madeUpHierarchy().naming
        // `Leaf`'s own slot 0, another unnamed override.
        let identity = ImplementationIdentity(location: .local(imagePath: "made-up", offset: 0x300), mangledName: nil)
        let baseFunction = try #require(naming.baseFunction(forSlotAt: 0, implementedBy: identity, startingAt: "Middle"))
        #expect(baseFunction.className == "Root")
        #expect(baseFunction.name?.demangledName == "Root::run()")
        #expect(!baseFunction.isInherited)
    }

    @Test func aSlotKeepingTheBaseImplementationIsInherited() throws {
        let naming = Self.madeUpHierarchy().naming
        let identity = ImplementationIdentity(location: .local(imagePath: "made-up", offset: 0x200), mangledName: nil)
        #expect(naming.baseFunction(forSlotAt: 0, implementedBy: identity, startingAt: "Middle")?.isInherited == true)
    }

    @Test func aSlotNoBaseNamesKeepsTheNearestBaseWithoutAName() throws {
        let naming = Self.madeUpHierarchy().naming
        let identity = ImplementationIdentity(location: nil, mangledName: nil)
        let baseFunction = try #require(naming.baseFunction(forSlotAt: 1, implementedBy: identity, startingAt: "Middle"))
        #expect(baseFunction.className == "Middle")
        #expect(baseFunction.name == nil)
    }

    @Test func aSlotPastTheBaseTableHasNoBaseFunction() {
        let naming = Self.madeUpHierarchy().naming
        let identity = ImplementationIdentity(location: nil, mangledName: nil)
        #expect(naming.baseFunction(forSlotAt: 2, implementedBy: identity, startingAt: "Middle") == nil)
        #expect(naming.baseFunction(forSlotAt: 0, implementedBy: identity, startingAt: "Unknown") == nil)
    }

    @Test func anImportAndTheBaseFunctionWithTheSameNameAreTheSameImplementation() {
        let imported = ImplementationIdentity(location: nil, mangledName: "__ZN4Root3runEv")
        let defined = ImplementationIdentity(location: .local(imagePath: "root", offset: 0x100), mangledName: "__ZN4Root3runEv")
        #expect(imported.isSame(as: defined))
        #expect(!imported.isSame(as: ImplementationIdentity(location: nil, mangledName: nil)))
    }

    // MARK: Two compiled libraries

    private static func derivedTables(in derived: MachOFile, dependencySearchPaths: [DependencySearchPath]) throws -> [CPlusPlusVirtualTable] {
        let store = CPlusPlusClassIndexStore(symbolStore: .shared)
        let derivedClass = try #require(store.class(named: "application::Derived", in: derived))
        #expect(!derivedClass.hasTypeInfoSymbol)
        return store.virtualTables(of: derivedClass, in: derived, dependencySearchPaths: dependencySearchPaths)
    }

    @Test func aClassWithoutSymbolsIsFoundThroughItsTypeInfo() throws {
        let built = try ClassHierarchyLibraries.built()
        let derived = try ClassIndexTestImages.hostSlice(of: built.derivedURL)
        let derivedClass = try #require(CPlusPlusClassIndexStore.shared.class(named: "application::Derived", in: derived))
        #expect(!derivedClass.hasTypeInfoSymbol)
        #expect(derivedClass.hasVirtualTable)
        #expect(derivedClass.bases.map(\.qualifiedName) == ["library::Base"])
        #expect(derivedClass.bases.first?.location == .otherImage(installName: "@rpath/libClassHierarchyBase.dylib"))
    }

    @Test func strippedOverridesAreNamedFromTheBaseInTheRPathSibling() throws {
        let built = try ClassHierarchyLibraries.built()
        let derived = try ClassIndexTestImages.hostSlice(of: built.derivedURL)
        let tables = try Self.derivedTables(in: derived, dependencySearchPaths: [.machOFile(path: built.baseURL.path)])
        let primary = try #require(tables.first)
        #expect(tables.count == 1)
        // ~Derived (two slots), first, second, third — then fourth, which
        // `Derived` introduces.
        #expect(primary.functions.count == 6)
        #expect(primary.functions.map { $0.symbolName == nil } == [true, true, true, false, true, true])
        #expect(primary.functions.map { $0.name?.baseName } == ["~Base", "~Base", "first", "second", "third", nil])
        #expect(primary.functions.prefix(5).allSatisfy { $0.baseFunction?.className == "library::Base" })
        // `second` is the base's own implementation, bound from the base library.
        #expect(primary.functions[3].implementation == .imported(symbolName: "__ZNK7library4Base6secondEv", installName: "@rpath/libClassHierarchyBase.dylib"))
        #expect(primary.functions[3].baseFunction?.isInherited == true)
        #expect(primary.functions[2].baseFunction?.isInherited == false)
        #expect(primary.functions[5].baseFunction == nil)
    }

    @Test func withoutTheSiblingTheBaseFunctionIsUnknown() throws {
        let built = try ClassHierarchyLibraries.built()
        let derived = try ClassIndexTestImages.hostSlice(of: built.derivedURL)
        let primary = try #require(try Self.derivedTables(in: derived, dependencySearchPaths: []).first)
        #expect(primary.functions[2].name == nil)
        #expect(primary.functions[2].baseFunction == nil)
        // The bound slot still names itself.
        #expect(primary.functions[3].name?.baseName == "second")
    }

    @Test func chainedAndLegacyFixupFilesGiveTheSameTables() throws {
        let built = try ClassHierarchyLibraries.built()
        let chained = try ClassIndexTestImages.hostSlice(of: built.derivedURL)
        let legacy = try ClassIndexTestImages.hostSlice(of: built.legacyDerivedURL)
        #expect(chained.cached.dyldChainedFixups != nil)
        #expect(legacy.cached.dyldChainedFixups == nil)
        let searchPaths: [DependencySearchPath] = [.machOFile(path: built.baseURL.path)]
        func shape(_ tables: [CPlusPlusVirtualTable]) -> [String] {
            tables.flatMap { table in table.functions.map { "\(table.offsetToTop) \($0.slotIndex) \($0.name?.demangledName ?? "-") \($0.baseFunction?.isInherited.description ?? "-")" } }
        }
        #expect(shape(try Self.derivedTables(in: chained, dependencySearchPaths: searchPaths)) == shape(try Self.derivedTables(in: legacy, dependencySearchPaths: searchPaths)))
    }
}
