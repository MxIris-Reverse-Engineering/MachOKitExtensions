import Foundation
import Testing
import MachOKit
@_spi(Internals) @testable import MachOSymbols

@Suite
struct SymbolLanguageTests {
    /// A block inside a C++ function is named `___Z…_block_invoke`; a Mach-O
    /// symbol table adds the Darwin underscore, `____Z…`, as clang emits it.
    @Test(arguments: [
        "__ZN4llvm5Value4dumpEv",
        "__ZNSt3__16vectorIiNS_9allocatorIiEEE9push_backEOi",
        "___ZN2CA6Render7Context6commitEv_block_invoke",
        "____Z9withBlockv_block_invoke",
    ])
    func cPlusPlusNamesAreRecognizedWithoutRegistration(name: String) {
        #expect(SymbolLanguage(ofSymbolNamed: name, registry: SymbolLanguageRegistry()) == .cPlusPlus)
    }

    /// Without a registration, every name C++ mangling does not claim is C —
    /// Swift and Objective-C names included: their packages define and
    /// register those languages.
    @Test(arguments: [
        "_malloc",
        "_main",
        "",
        "_",
        "$",
        "-",
        "+x",
        "_Z",
        "ltmp0",
        "$s7SwiftUI4TextVMn",
        "_$s7SwiftUI4TextVMn",
        "_symbolic _____ 7SwiftUI4TextV",
        "-[NSView setNeedsDisplay:]",
        "_OBJC_CLASS_$_NSView",
    ])
    func unclaimedNamesAreC(name: String) {
        #expect(SymbolLanguage(ofSymbolNamed: name, registry: SymbolLanguageRegistry()) == .c)
    }

    @Test func registeredLanguageClaimsTheNamesItRecognizes() {
        let registry = SymbolLanguageRegistry()
        registry.register(.objectiveCRuntimeStandIn, where: StandInRecognition.isObjectiveCRuntimeSymbol)
        #expect(SymbolLanguage(ofSymbolNamed: "_OBJC_CLASS_$_NSView", registry: registry) == .objectiveCRuntimeStandIn)
        #expect(SymbolLanguage(ofSymbolNamed: "_OBJC_IVAR_$_NSView._frame", registry: registry) == .objectiveCRuntimeStandIn)
        #expect(SymbolLanguage(ofSymbolNamed: "_malloc", registry: registry) == .c)
        #expect(registry.registeredLanguages == [.objectiveCRuntimeStandIn])
    }

    @Test func cPlusPlusIsDecidedBeforeRegisteredRecognizers() {
        let registry = SymbolLanguageRegistry()
        registry.register(.swiftStandIn, where: { _ in true })
        #expect(SymbolLanguage(ofSymbolNamed: "__ZN4llvm5Value4dumpEv", registry: registry) == .cPlusPlus)
        #expect(SymbolLanguage(ofSymbolNamed: "_malloc", registry: registry) == .swiftStandIn)
    }

    @Test func earlierRegistrationWinsAnOverlap() {
        let registry = SymbolLanguageRegistry()
        registry.register(.objectiveCRuntimeStandIn, where: StandInRecognition.isObjectiveCRuntimeSymbol)
        registry.register(.swiftStandIn, where: { _ in true })
        #expect(SymbolLanguage(ofSymbolNamed: "_OBJC_CLASS_$_NSView", registry: registry) == .objectiveCRuntimeStandIn)
        #expect(SymbolLanguage(ofSymbolNamed: "_malloc", registry: registry) == .swiftStandIn)
        #expect(registry.registeredLanguages == [.objectiveCRuntimeStandIn, .swiftStandIn])
    }

    @Test func registeringALanguageTwiceKeepsTheFirstRecognizer() {
        let registry = SymbolLanguageRegistry()
        registry.register(.swiftStandIn, where: StandInRecognition.isSwiftSymbol)
        let generationAfterFirstRegistration = registry.generation
        registry.register(.swiftStandIn, where: { _ in true })
        #expect(SymbolLanguage(ofSymbolNamed: "_$s7SwiftUI4TextVMn", registry: registry) == .swiftStandIn)
        #expect(SymbolLanguage(ofSymbolNamed: "_malloc", registry: registry) == .c)
        #expect(registry.registeredLanguages == [.swiftStandIn])
        #expect(registry.generation == generationAfterFirstRegistration)
    }

    @Test func registeringABuiltInLanguageIsAProgrammerError() async {
        await #expect(processExitsWith: .failure) {
            SymbolLanguageRegistry().register(.c, where: { _ in true })
        }
        await #expect(processExitsWith: .failure) {
            SymbolLanguageRegistry().register(.cPlusPlus, where: { _ in true })
        }
    }

    @Test func descriptionIsTheRawValue() {
        #expect(SymbolLanguage.c.description == "C")
        #expect(SymbolLanguage.cPlusPlus.description == "C++")
        #expect(SymbolLanguage(rawValue: "Rust").description == "Rust")
        #expect(SymbolLanguage(rawValue: "C") == .c)
        #expect(SymbolLanguage(rawValue: "C++") == .cPlusPlus)
    }

    /// The `String` form and the in-place byte form give one answer for
    /// every name of a real image. Nothing registers on the shared registry
    /// in this test process, so only C and C++ are seen.
    @Test func stringAndByteClassificationAgreeOnEveryNameOfARealImage() throws {
        var languagesSeen: Set<SymbolLanguage> = []
        var mismatchCount = 0
        for imageName in ["Foundation", "libc++", "libswiftCore"] {
            let image = try #require(MachOImage(name: imageName), "\(imageName) is not loaded")
            let symbols = try #require(image.symbols64)
            for symbol in symbols {
                let byteLanguage = SymbolLanguage(ofSymbolNameBytes: symbol.nameC)
                languagesSeen.insert(byteLanguage)
                if SymbolLanguage(ofSymbolNamed: symbol.name) != byteLanguage {
                    mismatchCount += 1
                }
            }
        }
        #expect(mismatchCount == 0)
        #expect(languagesSeen == [.c, .cPlusPlus])
    }
}
