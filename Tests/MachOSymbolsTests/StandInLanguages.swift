import Foundation
@_spi(Internals) import MachOSymbols

/// Languages this package's tests register on registries of their own, in
/// place of the ones MachOSwiftSection and MachOObjCSection register on the
/// shared registry in a real process. Nothing in this test process registers
/// on ``SymbolLanguageRegistry/shared``.
extension SymbolLanguage {
    /// Objective-C runtime symbols (`_OBJC_CLASS_$_…`, `_OBJC_IVAR_$_…`), which
    /// every Objective-C framework exports.
    static let objectiveCRuntimeStandIn = SymbolLanguage(rawValue: "Objective-C runtime (stand-in)")

    /// Swift-mangled names, recognized by their common prefixes.
    static let swiftStandIn = SymbolLanguage(rawValue: "Swift (stand-in)")
}

enum StandInRecognition {
    static func isObjectiveCRuntimeSymbol(_ name: UnsafePointer<CChar>) -> Bool {
        strncmp(name, "_OBJC_", 6) == 0
    }

    static func isSwiftSymbol(_ name: UnsafePointer<CChar>) -> Bool {
        strncmp(name, "$s", 2) == 0 || strncmp(name, "_$s", 3) == 0
            || strncmp(name, "$S", 2) == 0 || strncmp(name, "_$S", 3) == 0
            || strncmp(name, "$e", 2) == 0 || strncmp(name, "_$e", 3) == 0
    }

    /// A registry that knows the Objective-C runtime stand-in.
    static let objectiveCRuntimeRegistry: SymbolLanguageRegistry = {
        let registry = SymbolLanguageRegistry()
        registry.register(.objectiveCRuntimeStandIn, where: isObjectiveCRuntimeSymbol)
        return registry
    }()

    /// A registry that knows both stand-ins: what a process linking
    /// MachOSwiftSection and MachOObjCSection classifies like.
    static let swiftAndObjectiveCRuntimeRegistry: SymbolLanguageRegistry = {
        let registry = SymbolLanguageRegistry()
        registry.register(.swiftStandIn, where: isSwiftSymbol)
        registry.register(.objectiveCRuntimeStandIn, where: isObjectiveCRuntimeSymbol)
        return registry
    }()

    /// A registry that knows the Swift stand-in.
    static let swiftRegistry: SymbolLanguageRegistry = {
        let registry = SymbolLanguageRegistry()
        registry.register(.swiftStandIn, where: isSwiftSymbol)
        return registry
    }()
}
