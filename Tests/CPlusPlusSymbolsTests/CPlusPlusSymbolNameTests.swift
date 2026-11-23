import Testing
import CPlusPlusSymbols

/// Names taken apart. The mangled names are what clang 21 (Xcode 27.2)
/// emits into a Mach-O symbol table for small C++ samples; the expected
/// demangled names are `c++filt`'s.
@Suite
struct CPlusPlusSymbolNameTests {
    private static func name(_ mangledName: String) throws -> CPlusPlusSymbolName {
        try #require(CPlusPlusSymbolName(mangledName: mangledName), "\(mangledName) does not parse")
    }

    @Test func functionNameSplitsIntoScopePathBaseNameAndParameters() throws {
        let name = try Self.name("__ZNK4llvm5Value4dumpEv")
        #expect(name.demangledName == "llvm::Value::dump() const")
        #expect(name.kind == .function)
        #expect(name.scopePath == ["llvm", "Value"])
        #expect(name.baseName == "dump")
        #expect(name.parameters == "()")
        #expect(name.templateArguments == nil)
        #expect(name.returnType == nil)
        #expect(name.suffix == nil)
    }

    @Test func templateArgumentsStayInsideTheirScopeComponent() throws {
        let name = try Self.name("__ZNSt3__16vectorIiNS_9allocatorIiEEE9push_backB9nqe220106EOi")
        #expect(name.demangledName == "std::__1::vector<int, std::__1::allocator<int>>::push_back[abi:nqe220106](int&&)")
        #expect(name.scopePath == ["std", "__1", "vector<int, std::__1::allocator<int>>"])
        #expect(name.baseName == "push_back")
        #expect(name.parameters == "(int&&)")
    }

    /// The text each reference's range covers, in order.
    private static func spelledTypes(_ references: [CPlusPlusSymbolName.TypeReference], in text: String?) throws -> [String] {
        let text = try #require(text)
        return references.map { String(text[$0.range]) }
    }

    @Test func parameterTypeReferencesLocateEachNamedTypeTheParametersSpell() throws {
        let name = try Self.name("__ZN2CA14CAHDRProcessor29should_invalidate_tonemappingERKNS_6Render17DisplayAttributesES4_ff")
        #expect(name.parameters == "(CA::Render::DisplayAttributes const&, CA::Render::DisplayAttributes const&, float, float)")
        #expect(try Self.spelledTypes(name.parameterTypeReferences, in: name.parameters) == ["CA::Render::DisplayAttributes", "CA::Render::DisplayAttributes"])
        #expect(name.parameterTypeReferences.map(\.path) == [["CA", "Render", "DisplayAttributes"], ["CA", "Render", "DisplayAttributes"]])
        #expect(name.returnTypeReferences.isEmpty)
    }

    /// `S0_` reuses the node of `CA::Foo` as the qualifier of `CA::Foo::Bar`:
    /// the qualifier is part of a name there, not a type of its own.
    @Test func aQualifierIsNoTypeReferenceOfItsOwn() throws {
        let name = try Self.name("__Z4bothN2CA3FooENS0_3BarE")
        #expect(name.parameters == "(CA::Foo, CA::Foo::Bar)")
        #expect(try Self.spelledTypes(name.parameterTypeReferences, in: name.parameters) == ["CA::Foo", "CA::Foo::Bar"])
        #expect(name.parameterTypeReferences.map(\.path) == [["CA", "Foo"], ["CA", "Foo", "Bar"]])
    }

    /// A template's reference comes first and spans its arguments, whose
    /// named types follow it.
    @Test func typesInATemplateArgumentListFollowTheirTemplate() throws {
        let name = try Self.name("__Z4takeRKNSt3__16vectorIN2CA3FooENS_9allocatorIS2_EEEE")
        #expect(name.parameters == "(std::__1::vector<CA::Foo, std::__1::allocator<CA::Foo>> const&)")
        #expect(try Self.spelledTypes(name.parameterTypeReferences, in: name.parameters) == [
            "std::__1::vector<CA::Foo, std::__1::allocator<CA::Foo>>",
            "CA::Foo",
            "std::__1::allocator<CA::Foo>",
            "CA::Foo",
        ])
        #expect(name.parameterTypeReferences.first?.path == ["std", "__1", "vector<CA::Foo, std::__1::allocator<CA::Foo>>"])
    }

    @Test func typesInsideAFunctionPointerParameterAreFound() throws {
        let name = try Self.name("__Z8callbackPFvN2CA3FooEE")
        #expect(name.parameters == "(void (*)(CA::Foo))")
        #expect(try Self.spelledTypes(name.parameterTypeReferences, in: name.parameters) == ["CA::Foo"])
    }

    @Test func returnTypeReferencesLocateTheReturnTypesNamedTypes() throws {
        let name = try Self.name("__Z4makeIN2CA3FooEET_PKS1_")
        #expect(name.returnType == "CA::Foo")
        #expect(try Self.spelledTypes(name.returnTypeReferences, in: name.returnType) == ["CA::Foo"])
        #expect(name.parameters == "(CA::Foo const*)")
        #expect(try Self.spelledTypes(name.parameterTypeReferences, in: name.parameters) == ["CA::Foo"])
    }

    @Test func builtInTypesAndNamesWithoutASignatureHaveNoTypeReferences() throws {
        #expect(try Self.name("__ZN2CA14CAHDRProcessor19can_display_tonemapEif").parameterTypeReferences.isEmpty)
        let variable = try Self.name("__ZN7fixture5Token5countE")
        #expect(variable.parameterTypeReferences.isEmpty)
        #expect(variable.returnTypeReferences.isEmpty)
    }

    @Test func constQualifiedMemberFunctionReportsItsQualifiers() throws {
        #expect(try Self.name("__ZNK4llvm5Value4dumpEv").functionQualifiers == [.const])
        #expect(try Self.name("__ZN4Base1fEv").functionQualifiers == [])
    }

    @Test func constructorAndDestructorKeepTheirVariant() throws {
        let constructor = try Self.name("__ZN7DerivedC1Ev")
        #expect(constructor.kind == .constructor)
        #expect(constructor.constructorOrDestructorVariant == 1)
        #expect(constructor.scopePath == ["Derived"])
        #expect(constructor.baseName == "Derived")

        let deletingDestructor = try Self.name("__ZN4BaseD0Ev")
        #expect(deletingDestructor.kind == .destructor)
        #expect(deletingDestructor.constructorOrDestructorVariant == 0)
        #expect(deletingDestructor.baseName == "~Base")
    }

    @Test(arguments: [
        ("__ZTVN4llvm5ValueE", CPlusPlusSymbolName.Kind.virtualTable, ["llvm", "Value"], "Value"),
        ("__ZTIN4llvm5ValueE", .typeInfo, ["llvm", "Value"], "Value"),
        ("__ZTS4Base", .typeInfoName, ["Base"], "Base"),
        ("__ZTT7Derived", .virtualTableTable, ["Derived"], "Derived"),
        ("__ZTISt12length_error", .typeInfo, ["std", "length_error"], "length_error"),
    ])
    func namesAboutATypeEndTheirScopePathWithThatType(mangledName: String, kind: CPlusPlusSymbolName.Kind, scopePath: [String], baseName: String) throws {
        let name = try Self.name(mangledName)
        #expect(name.kind == kind)
        #expect(name.scopePath == scopePath)
        #expect(name.baseName == baseName)
        #expect(name.parameters == nil)
    }

    @Test func typeInfoOfATypeWithoutANameSitsAtGlobalScope() throws {
        let pointer = try Self.name("__ZTIPKc")
        #expect(pointer.demangledName == "typeinfo for char const*")
        #expect(pointer.scopePath == [])
        #expect(pointer.baseName == "char const*")

        let builtIn = try Self.name("__ZTIi")
        #expect(builtIn.scopePath == [])
        #expect(builtIn.baseName == "int")
    }

    /// `Derived` comes first in the mangling; the demangler prints it last.
    @Test func constructionVirtualTableBelongsToTheCompleteClass() throws {
        let name = try Self.name("__ZTC7Derived0_6Middle")
        #expect(name.demangledName == "construction vtable for Middle-in-Derived")
        #expect(name.kind == .constructionVirtualTable)
        #expect(name.scopePath == ["Derived"])
        #expect(name.baseName == "Derived")
    }

    @Test(arguments: [
        ("__ZThn8_N7Derived1gEv", CPlusPlusSymbolName.Kind.nonVirtualThunk, "g"),
        ("__ZTv0_n24_N7Derived1fEv", .virtualThunk, "f"),
        ("__ZTcv0_n32_v0_n48_N7Derived5cloneEv", .covariantReturnThunk, "clone"),
        ("__ZTv0_n40_N7DerivedD1Ev", .virtualThunk, "~Derived"),
    ])
    func thunksTakeTheScopeAndBaseNameOfTheFunctionTheyReach(mangledName: String, kind: CPlusPlusSymbolName.Kind, baseName: String) throws {
        let name = try Self.name(mangledName)
        #expect(name.kind == kind)
        #expect(name.scopePath == ["Derived"])
        #expect(name.baseName == baseName)
        #expect(name.parameters == "()")
    }

    @Test func guardVariableTakesTheScopeOfItsVariable() throws {
        let name = try Self.name("__ZGVZ7guardedvE1y")
        #expect(name.demangledName == "guard variable for guarded()::y")
        #expect(name.kind == .guardVariable)
        #expect(name.scopePath == ["guarded()"])
        #expect(name.baseName == "y")
        #expect(name.parameters == nil)
    }

    @Test func threadLocalWrapperTakesTheScopeOfItsVariable() throws {
        let name = try Self.name("__ZTW11threadValue")
        #expect(name.kind == .threadLocalWrapper)
        #expect(name.scopePath == [])
        #expect(name.baseName == "threadValue")
    }

    @Test func localEntityScopePathRunsThroughItsFunction() throws {
        let method = try Self.name("__ZZ10localThingvEN3Bar3bazEv")
        #expect(method.demangledName == "localThing()::Bar::baz()")
        #expect(method.kind == .function)
        #expect(method.scopePath == ["localThing()", "Bar"])
        #expect(method.baseName == "baz")

        let staticVariable = try Self.name("__ZZ7guardedvE1y")
        #expect(staticVariable.kind == .variable)
        #expect(staticVariable.scopePath == ["guarded()"])
        #expect(staticVariable.baseName == "y")
    }

    /// A lambda's call operator inside a member function template of a
    /// class template specialization.
    @Test func lambdaInsideAMemberFunctionRunsThroughThatFunction() throws {
        let name = try Self.name("__ZZNSt3__16vectorIiNS_9allocatorIiEEE12emplace_backIJiEEERiDpOT_ENKUlvE_clEv")
        #expect(name.scopePath == ["std", "__1", "vector<int, std::__1::allocator<int>>", "emplace_back<int>(int&&)", "'lambda'()"])
        #expect(name.baseName == "operator()")
        #expect(name.functionQualifiers == [.const])
    }

    @Test func blockInvocationTakesTheScopeOfItsFunction() throws {
        let name = try Self.name("____Z9withBlockv_block_invoke")
        #expect(name.demangledName == "invocation function for block in withBlock()")
        #expect(name.kind == .blockInvocation)
        #expect(name.scopePath == [])
        #expect(name.baseName == "withBlock")
        #expect(name.parameters == nil)
    }

    @Test func functionTemplateSpecializationReportsItsReturnType() throws {
        let name = try Self.name("__Z7maximumIiET_S0_S0_")
        #expect(name.demangledName == "int maximum<int>(int, int)")
        #expect(name.baseName == "maximum")
        #expect(name.templateArguments == "<int>")
        #expect(name.returnType == "int")
        #expect(name.parameters == "(int, int)")
    }

    @Test func dotSuffixIsKeptApartFromTheName() throws {
        let name = try Self.name("__ZN4Base1fEv.cold.1")
        #expect(name.demangledName == "Base::f() (.cold.1)")
        #expect(name.suffix == ".cold.1")
        #expect(name.scopePath == ["Base"])
        #expect(name.baseName == "f")
    }

    @Test func variableHasNoParametersOrQualifiers() throws {
        let name = try Self.name("__ZN3Foo7counterE")
        #expect(name.kind == .variable)
        #expect(name.scopePath == ["Foo"])
        #expect(name.baseName == "counter")
        #expect(name.parameters == nil)
        #expect(name.functionQualifiers == [])
        #expect(name.constructorOrDestructorVariant == nil)
    }

    @Test(arguments: ["__Zgarbage", "_malloc", "$s7SwiftUI4TextVMn", ""])
    func unparsableNameGivesNil(mangledName: String) {
        #expect(CPlusPlusSymbolName(mangledName: mangledName) == nil)
    }
}
