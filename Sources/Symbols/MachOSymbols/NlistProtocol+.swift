import MachOKit

extension NlistProtocol {
    /// An undefined import: the `N_EXT` bit set on an `N_UNDF` entry. Not
    /// every external symbol — an exported definition carries `N_EXT` too —
    /// which is why this stays behind the SPI instead of becoming public
    /// under a name that reads as "exported".
    @_spi(Internals)
    public var isExternal: Bool {
        guard let flags = flags, let type = flags.type else { return false }
        return flags.contains(.ext) && type == .undf
    }

    /// An indirect entry (`N_INDR`): another image's symbol, re-exported by
    /// name. Its value is the string-table index of the name it stands for,
    /// not an address, so the image defines nothing there. libc++ re-exports
    /// libc++abi's `std::exception` members one by one this way.
    @_spi(Internals)
    public var isIndirect: Bool {
        flags?.type == .indr
    }

    /// A symbol private to its image: the `N_EXT` bit clear, so neither an
    /// export nor an import. Not the negation of ``isExternal``, which names
    /// an undefined import only. A linker turns a private external
    /// (`N_PEXT`) into one of these, which is how a Swift declaration below
    /// `public` reaches a linked image's symbol table, and what a strip of
    /// the local symbols removes.
    @_spi(Internals)
    public var isLocal: Bool {
        guard let flags else { return false }
        return !flags.contains(.ext)
    }

    /// A debug-map (STABS) entry: it describes a symbol for the debugger and
    /// is not one. An `N_GSYM` entry carries the value 0 under the very name
    /// of the symbol it describes; indexed like a symbol, it was filed at the
    /// mach header and, listed after a local symbol, overwrote that symbol's
    /// offset with 0. The index lets one only reserve a row
    /// (`SymbolTableBuilder.reserveRow`).
    @_spi(Internals)
    public var isDebuggingEntry: Bool {
        flags?.stab != nil
    }
}
