import Foundation
import Testing
import MachOKit
import MachOResolving
@_spi(Internals) import MachOSymbols
@testable import CPlusPlusSymbols
import CPlusPlusSymbolsFixture

/// The scope tree, read from the image the C++ fixture is linked into.
@Suite
struct CPlusPlusSymbolIndexStoreTests {
    private static let store = CPlusPlusSymbolIndexStore.shared

    private static func fixtureImage() throws -> MachOImage {
        #expect(CPlusPlusSymbolsFixtureTouchEverything() != 0)
        var information = Dl_info()
        try #require(dladdr(CPlusPlusSymbolsFixtureAnchor(), &information) != 0)
        let header = try #require(information.dli_fbase)
        return MachOImage(ptr: header.assumingMemoryBound(to: mach_header.self))
    }

    private static func scope(named qualifiedName: String) throws -> CPlusPlusScope {
        try #require(store.scope(named: qualifiedName, in: try fixtureImage()), "no scope \(qualifiedName)")
    }

    /// Every scope of the image, depth first.
    private static func allScopes(in image: MachOImage) -> [CPlusPlusScope] {
        var scopes: [CPlusPlusScope] = []
        var pending: [CPlusPlusScope] = [.global]
        while let scope = pending.popLast() {
            scopes.append(scope)
            pending.append(contentsOf: store.childScopes(of: scope, in: image))
        }
        return scopes
    }

    @Test func storeHoldsOnlyCPlusPlusNames() throws {
        let image = try Self.fixtureImage()
        let members = Self.allScopes(in: image).flatMap { Self.store.members(of: $0, in: image) }
        try #require(!members.isEmpty)
        #expect(members.allSatisfy { $0.symbol.name.hasPrefix("__Z") || $0.symbol.name.hasPrefix("____Z") })
        #expect(Self.store.symbol(named: "_CPlusPlusSymbolsFixtureAnchor", in: image) == nil)
    }

    @Test func childScopesOfGlobalAreTheTopLevelScopes() throws {
        let image = try Self.fixtureImage()
        let topLevel = Self.store.childScopes(of: .global, in: image)
        #expect(topLevel.map(\.name).contains("fixture"))
        #expect(topLevel.map(\.name).contains("std"))
        #expect(topLevel.allSatisfy { $0.path.count == 1 })
        #expect(topLevel.map(\.name) == topLevel.map(\.name).sorted())
    }

    @Test func scopeWithAConstructorIsAType() throws {
        let scope = try Self.scope(named: "fixture::WithConstructor")
        #expect(scope.kind == .type)
        #expect(scope.evidence.contains(.constructorOrDestructor))
    }

    @Test func scopeWithAVirtualTableHasVirtualTableAndTypeInfoAmongItsMembers() throws {
        let image = try Self.fixtureImage()
        let scope = try Self.scope(named: "fixture::Polymorphic")
        #expect(scope.kind == .type)
        #expect(scope.evidence.isSuperset(of: [.virtualTable, .typeInfo]))
        let kinds = Set(Self.store.members(of: scope, in: image).map(\.name.kind))
        #expect(kinds.isSuperset(of: [.virtualTable, .typeInfo, .typeInfoName, .function, .destructor]))
    }

    @Test func virtualInheritanceShowsVirtualTableTablesAndThunks() throws {
        let image = try Self.fixtureImage()
        let complete = try Self.scope(named: "fixture::Complete")
        let kinds = Set(Self.store.members(of: complete, in: image).map(\.name.kind))
        #expect(kinds.isSuperset(of: [.virtualTableTable, .constructionVirtualTable]))
        let intermediate = try Self.scope(named: "fixture::Intermediate")
        #expect(intermediate.evidence.contains(.thunk))
    }

    @Test func scopeWithOnlyConstMemberFunctionsIsAType() throws {
        let scope = try Self.scope(named: "fixture::ConstOnly")
        #expect(scope.kind == .type)
        #expect(scope.evidence == [.qualifiedMemberFunction])
    }

    @Test func scopeOnlyUsedAsAParameterTypeIsAType() throws {
        let scope = try Self.scope(named: "fixture::Token")
        #expect(scope.kind == .type)
        #expect(scope.evidence == [.usedAsType])
    }

    @Test func scopeWithOnlyStaticMemberFunctionsIsUndetermined() throws {
        let scope = try Self.scope(named: "fixture::StaticOnly")
        #expect(scope.kind == .undetermined)
        #expect(scope.evidence == [])
    }

    @Test func standardAndAnonymousNamespacesAreNamespaces() throws {
        #expect(try Self.scope(named: "std").kind == .namespace)
        #expect(try Self.scope(named: "fixture::(anonymous namespace)").kind == .namespace)
        #expect(CPlusPlusScope.global.kind == .namespace)
    }

    @Test func functionWithALocalClassIsAFunctionScope() throws {
        let image = try Self.fixtureImage()
        let function = try Self.scope(named: "fixture::localThing(int)")
        #expect(function.kind == .function)
        #expect(function.baseName == "localThing")
        #expect(Self.store.childScopes(of: function, in: image).map(\.name).contains("Local"))
    }

    /// clang mangles the Objective-C method a static local sits in as a bare
    /// name, `Z 30-[FixtureObject fixtureMethod] E`, with no parameters; it
    /// is still the function the local entity sits in.
    @Test func objectiveCMethodWithALocalIsAFunctionScope() throws {
        let image = try Self.fixtureImage()
        let method = try Self.scope(named: "-[FixtureObject fixtureMethod]")
        #expect(method.kind == .function)
        #expect(Self.store.members(of: method, in: image).map(\.name.baseName) == ["onceToken"])
    }

    /// A closure type with the Itanium name `'lambda'(int)` is a type by its
    /// mangling; one clang names `$_0` is a type by its `const` call
    /// operator.
    @Test func lambdaScopeIsAType() throws {
        let image = try Self.fixtureImage()
        let inlineFunction = try Self.scope(named: "fixture::withLambda(int)")
        let lambda = try #require(Self.store.childScopes(of: inlineFunction, in: image).first { $0.name.hasPrefix("'lambda'") })
        #expect(lambda.kind == .type)
        #expect(lambda.evidence.contains(.mangledAsType))

        let function = try Self.scope(named: "fixture::localThing(int)")
        let clangClosure = try #require(Self.store.childScopes(of: function, in: image).first { $0.name == "$_0" })
        #expect(clangClosure.kind == .type)
        #expect(clangClosure.evidence == [.qualifiedMemberFunction])
    }

    @Test func eachTemplateSpecializationIsItsOwnScopeSharingABaseName() throws {
        let image = try Self.fixtureImage()
        let namespace = try Self.scope(named: "fixture")
        let boxes = Self.store.childScopes(of: namespace, in: image).filter { $0.baseName == "Box" }
        #expect(boxes.map(\.name) == ["Box<char>", "Box<int>"])
        #expect(boxes.allSatisfy { $0.kind == .type })
    }

    @Test func typesUsedOnlyInSignaturesAddNoScope() throws {
        let image = try Self.fixtureImage()
        #expect(Self.store.scope(named: "fixture::Opaque", in: image) == nil)
    }

    @Test func scopeNamedFindsAScopeByItsQualifiedName() throws {
        let image = try Self.fixtureImage()
        let scope = try Self.scope(named: "fixture::WithConstructor")
        #expect(scope.path == ["fixture", "WithConstructor"])
        #expect(scope.qualifiedName == "fixture::WithConstructor")
        #expect(Self.store.scope(named: "fixture::NoSuchThing", in: image) == nil)
        #expect(Self.store.scope(named: "", in: image) == .global)
    }

    @Test func membersAreInOffsetOrder() throws {
        let image = try Self.fixtureImage()
        let members = Self.store.members(of: try Self.scope(named: "fixture::Polymorphic"), in: image)
        try #require(members.count > 2)
        #expect(members.map(\.offset) == members.map(\.offset).sorted())
    }

    @Test func symbolsForOffsetGivesTheParsedNamesAtThatOffset() throws {
        let image = try Self.fixtureImage()
        let answer = try #require(Self.store.members(of: try Self.scope(named: "fixture::Polymorphic"), in: image).first { $0.name.baseName == "answer" })
        let symbols = Self.store.symbols(for: answer.offset, in: image)
        #expect(symbols.map(\.name.demangledName).contains("fixture::Polymorphic::answer()"))
        #expect(symbols.allSatisfy { $0.offset == answer.offset })
    }

    @Test func symbolNamedFindsASymbolByItsMangledName() throws {
        let image = try Self.fixtureImage()
        let symbol = try #require(Self.store.symbol(named: "__ZN7fixture11Polymorphic6answerEv", in: image))
        #expect(symbol.name.scopePath == ["fixture", "Polymorphic"])
        #expect(symbol.name.baseName == "answer")
        #expect(Self.store.symbols(for: symbol.offset, in: image).contains(symbol))
    }

    @Test func unparsedSymbolsListNamesTheDemanglerRejects() throws {
        let image = try Self.fixtureImage()
        #expect(Self.store.unparsedSymbols(in: image).map(\.name).contains("__Z_fixture_unparsable"))
        #expect(Self.store.symbol(named: "__Z_fixture_unparsable", in: image) == nil)
    }

    /// libc++abi is an image no other test of this store reads, so this test
    /// owns its entry.
    @Test func indexIsBuiltOnFirstQueryAndDroppedByRemove() throws {
        let libCPlusPlusABI = try #require(MachOImage(name: "libc++abi"), "libc++abi is not loaded")
        Self.store.remove(for: libCPlusPlusABI)
        #expect(!Self.store.contains(in: libCPlusPlusABI))
        _ = Self.store.childScopes(of: .global, in: libCPlusPlusABI)
        #expect(Self.store.contains(in: libCPlusPlusABI))
        Self.store.remove(for: libCPlusPlusABI)
        #expect(!Self.store.contains(in: libCPlusPlusABI))
    }

    @Test func registeringALanguageDoesNotRebuildTheIndex() throws {
        let registry = SymbolLanguageRegistry()
        let store = CPlusPlusSymbolIndexStore(languageRegistry: registry)
        let image = try Self.fixtureImage()
        let built = try #require(store.storage(in: image))
        registry.register(SymbolLanguage(rawValue: "CPlusPlusSymbolsTests stand-in"), where: { _ in false })
        let afterRegistration = try #require(store.storage(in: image))
        #expect(afterRegistration === built)
    }
}
