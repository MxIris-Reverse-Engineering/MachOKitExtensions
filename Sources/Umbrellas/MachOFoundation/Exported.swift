// `MachOBase` plus the symbol index and dependency resolution: the Mach-O
// layer as one import, for code above MachOSwiftSection's ABI model. The
// Swift symbol index is not part of it; MachOSwiftSection's `SwiftSymbols`
// carries that.
@_exported import MachOBase
@_exported import MachOSymbols
@_exported import MachODependencies
