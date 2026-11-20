/// The language a symbol name was mangled for, told from the name's leading
/// bytes alone.
///
/// ```swift
/// SymbolLanguage(ofSymbolNamed: "__ZN4llvm5Value4dumpEv")   // .cPlusPlus
/// SymbolLanguage(ofSymbolNamed: "_malloc")                  // .c
/// SymbolLanguage(ofSymbolNamed: "$s7SwiftUI4TextVMn")       // .swift once SwiftSymbols is linked, .c before
/// ```
///
/// This package tells C++ (Itanium) names apart and calls every name nobody
/// claims C. Every other language is the package's that owns it, to define
/// as a static member and to register with ``SymbolLanguageRegistry`` when
/// its image loads: MachOSwiftSection's `SwiftSymbols` adds `.swift`,
/// MachOObjCSection adds `.objectiveC`.
///
/// A struct with static members rather than an enum, so that a language can
/// be added from outside this package and a caller never switches over all of
/// them.
public struct SymbolLanguage: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// The language's name as a person reads it — `"C"`, `"C++"`, `"Swift"`.
    /// Two values with the same name are the same language, so a name, once
    /// published, is part of the language's identity.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A name no registered language and no C++ mangling claims: plain C,
    /// assembler labels, and anything unrecognized — including the names of
    /// a language whose package is not in the process.
    public static let c = SymbolLanguage(rawValue: "C")

    /// An Itanium-mangled name: `__Z…`, or `____Z…_block_invoke` for a block
    /// inside a C++ function (`___Z…` without the Darwin underscore). Decided
    /// before any registered language is asked.
    public static let cPlusPlus = SymbolLanguage(rawValue: "C++")

    public var description: String {
        rawValue
    }

    /// The language of `name`, a symbol name as the symbol table spells it
    /// (with the leading underscore C names carry on Darwin), as `registry`
    /// tells languages apart.
    public init(ofSymbolNamed name: String, registry: SymbolLanguageRegistry = .shared) {
        self = name.withCString { registry.language(ofSymbolNameBytes: $0) }
    }

    /// The language of the NUL-terminated name at `name`, read in place —
    /// the form a sweep over an image's string table uses, so that no
    /// `String` is made for a name nobody keeps.
    @_spi(Internals)
    public init(ofSymbolNameBytes name: UnsafePointer<CChar>, registry: SymbolLanguageRegistry = .shared) {
        self = registry.language(ofSymbolNameBytes: name)
    }

    /// Whether `name` is Itanium-mangled: the one language this package
    /// recognizes itself.
    static func isItaniumMangled(_ name: UnsafePointer<CChar>) -> Bool {
        hasPrefix(name, "__Z") || hasPrefix(name, "___Z") || hasPrefix(name, "____Z")
    }

    /// Whether the NUL-terminated `name` starts with `prefix`. Never reads
    /// past the terminator: the prefixes hold no NUL byte, so a shorter name
    /// mismatches at its terminator first.
    private static func hasPrefix(_ name: UnsafePointer<CChar>, _ prefix: StaticString) -> Bool {
        prefix.withUTF8Buffer { prefixBytes in
            for (index, prefixByte) in prefixBytes.enumerated() where UInt8(bitPattern: name[index]) != prefixByte {
                return false
            }
            return true
        }
    }
}
