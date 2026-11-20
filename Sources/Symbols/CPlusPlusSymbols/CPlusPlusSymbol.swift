import MachOResolving

/// A C++ symbol of an image, with its name taken apart.
public struct CPlusPlusSymbol: Hashable, Sendable {
    /// The symbol as the symbol table has it: its offset and its mangled
    /// name.
    public let symbol: Symbol

    public let name: CPlusPlusSymbolName

    init(symbol: Symbol, name: CPlusPlusSymbolName) {
        self.symbol = symbol
        self.name = name
    }

    public var offset: Int {
        symbol.offset
    }
}
