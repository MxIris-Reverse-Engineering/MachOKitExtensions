/// The language a symbol name was mangled for, told from the name's leading
/// bytes alone.
///
/// ```swift
/// SymbolLanguage(ofSymbolNamed: "__ZN4llvm5Value4dumpEv")   // .cPlusPlus
/// SymbolLanguage(ofSymbolNamed: "-[NSView setNeedsDisplay:]") // .objectiveC
/// SymbolLanguage(ofSymbolNamed: "$s7SwiftUI4TextVMn")        // .swift
/// SymbolLanguage(ofSymbolNamed: "_malloc")                    // .c
/// ```
///
/// A struct with static members rather than an enum: more languages may be
/// told apart later (Rust's `__R…`, say), and a caller should not have to
/// switch over every one of them.
public struct SymbolLanguage: Hashable, Sendable, CustomStringConvertible {
    private enum Kind: Hashable, Sendable {
        case c
        case cPlusPlus
        case objectiveC
        case swift
    }

    private let kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    /// A name no other language claims: plain C, assembler labels, and
    /// anything unrecognized.
    public static let c = SymbolLanguage(kind: .c)

    /// An Itanium-mangled name: `__Z…`, or `___Z…` for a block inside a C++
    /// function.
    public static let cPlusPlus = SymbolLanguage(kind: .cPlusPlus)

    /// An Objective-C method implementation (`-[…]`, `+[…]`) or a symbol of
    /// the Objective-C runtime (`_OBJC_…`, `__OBJC_…`, `l_OBJC_…`,
    /// `L_OBJC_…`, `_objc_msgSend$…`).
    public static let objectiveC = SymbolLanguage(kind: .objectiveC)

    /// A Swift-mangled name (`$s`, `_$s`, `$S`, `_$S`, `$e`, `_$e`, `_T0`,
    /// `@__swiftmacro_`) or a name the Swift compiler emits for the linker to
    /// de-duplicate (`_symbolic `, `_default assoc type `).
    ///
    /// The mangling prefixes are exactly the ones swift-demangling's
    /// `isSwiftSymbol` accepts; MachOSwiftSection pins the two equal over a
    /// real symbol table, since this package does not depend on the
    /// demangler.
    public static let swift = SymbolLanguage(kind: .swift)

    /// The language of `name`, a symbol name as the symbol table spells it
    /// (with the leading underscore C names carry on Darwin).
    public init(ofSymbolNamed name: String) {
        self = name.withCString { SymbolLanguage(ofSymbolNameBytes: $0) }
    }

    /// The language of the NUL-terminated name at `name`, read in place —
    /// the form a sweep over an image's string table uses, so that no
    /// `String` is made for a name nobody keeps.
    @_spi(Internals)
    public init(ofSymbolNameBytes name: UnsafePointer<CChar>) {
        self.init(kind: Self.kind(ofSymbolNameBytes: name))
    }

    public var description: String {
        switch kind {
        case .c:
            "C"
        case .cPlusPlus:
            "C++"
        case .objectiveC:
            "Objective-C"
        case .swift:
            "Swift"
        }
    }

    private static func kind(ofSymbolNameBytes name: UnsafePointer<CChar>) -> Kind {
        switch UInt8(bitPattern: name.pointee) {
        case UInt8(ascii: "$"):
            if hasPrefix(name, "$s") || hasPrefix(name, "$S") || hasPrefix(name, "$e") {
                return .swift
            }
        case UInt8(ascii: "@"):
            if hasPrefix(name, "@__swiftmacro_") {
                return .swift
            }
        case UInt8(ascii: "-"), UInt8(ascii: "+"):
            if UInt8(bitPattern: name[1]) == UInt8(ascii: "[") {
                return .objectiveC
            }
        case UInt8(ascii: "_"):
            if hasPrefix(name, "_$s") || hasPrefix(name, "_$S") || hasPrefix(name, "_$e") || hasPrefix(name, "_T0")
                || hasPrefix(name, "_symbolic ") || hasPrefix(name, "_default assoc type ") {
                return .swift
            }
            if hasPrefix(name, "__Z") || hasPrefix(name, "___Z") {
                return .cPlusPlus
            }
            if hasPrefix(name, "_OBJC_") || hasPrefix(name, "__OBJC_") || hasPrefix(name, "_objc_msgSend$") {
                return .objectiveC
            }
        case UInt8(ascii: "l"):
            if hasPrefix(name, "l_OBJC_") {
                return .objectiveC
            }
        case UInt8(ascii: "L"):
            if hasPrefix(name, "L_OBJC_") {
                return .objectiveC
            }
        default:
            break
        }
        return .c
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
