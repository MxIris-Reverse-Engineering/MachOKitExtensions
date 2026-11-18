import Foundation
import Testing
import MachOKit
@_spi(Internals) import MachOSymbols

@Suite
struct SymbolLanguageTests {
    @Test(arguments: [
        "$s7SwiftUI4TextVMn",
        "_$s7SwiftUI4TextVMn",
        "$S7SwiftUI4TextVMn",
        "_$S7SwiftUI4TextVMn",
        "$e4Main3FooV",
        "_$e4Main3FooV",
        "_T0So8NSObjectC",
        "@__swiftmacro_4Main3FooV10ObservablefMm_",
    ])
    func symbolLanguageClassifiesSwiftManglingPrefixes(name: String) {
        #expect(SymbolLanguage(ofSymbolNamed: name) == .swift)
    }

    @Test(arguments: [
        "_symbolic _____ 7SwiftUI4TextV",
        "_default assoc type _____y_____",
    ])
    func symbolLanguageClassifiesSymbolicManglingNamesAsSwift(name: String) {
        #expect(SymbolLanguage(ofSymbolNamed: name) == .swift)
    }

    @Test(arguments: [
        "__ZN4llvm5Value4dumpEv",
        "__ZNSt3__16vectorIiNS_9allocatorIiEEE9push_backEOi",
        "___ZN2CA6Render7Context6commitEv_block_invoke",
    ])
    func symbolLanguageClassifiesItaniumNamesAsCPlusPlus(name: String) {
        #expect(SymbolLanguage(ofSymbolNamed: name) == .cPlusPlus)
    }

    @Test(arguments: [
        "-[NSView setNeedsDisplay:]",
        "+[NSColor redColor]",
        "_OBJC_CLASS_$_NSView",
        "_OBJC_METACLASS_$_NSView",
        "_OBJC_IVAR_$_NSView._frame",
        "__OBJC_$_INSTANCE_METHODS_NSView",
        "l_OBJC_PROTOCOL_$_NSCopying",
        "L_OBJC_SELECTOR_REFERENCES_",
        "_objc_msgSend$setNeedsDisplay:",
    ])
    func symbolLanguageClassifiesMethodImplementationsAndRuntimeSymbolsAsObjectiveC(name: String) {
        #expect(SymbolLanguage(ofSymbolNamed: name) == .objectiveC)
    }

    @Test(arguments: [
        "_malloc",
        "_main",
        "",
        "_",
        "$",
        "-",
        "+x",
        "_Z",
        "__swift_FORCE_LOAD_$_swiftCompatibility56",
        "ltmp0",
        "_OBJ",
    ])
    func symbolLanguageFallsBackToC(name: String) {
        #expect(SymbolLanguage(ofSymbolNamed: name) == .c)
    }

    @Test func descriptionsNameTheLanguages() {
        #expect([SymbolLanguage.c, .cPlusPlus, .objectiveC, .swift].map(\.description) == ["C", "C++", "Objective-C", "Swift"])
    }

    /// The `String` form and the in-place byte form give one answer for
    /// every name of a real image, and the images this process has loaded
    /// carry names of every language.
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
        #expect(languagesSeen == [.c, .cPlusPlus, .objectiveC, .swift])
    }
}
