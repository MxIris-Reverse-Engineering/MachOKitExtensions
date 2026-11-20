// The reader / resolver / pointer layer as one import — everything
// MachOSwiftSection's ABI model is allowed to depend on, and nothing above it.
// `MachOFoundation` re-exports this plus the symbol index and dependency
// resolution; the ABI layer deliberately stops here (MachOSwiftSection
// evolution proposal `self-contained-abi-layer`). MachOSwiftSection's own
// `Utilities` is not part of it: the ABI model imports that itself.
@_exported import MachOKitExtensions
@_exported import MachOReading
@_exported import MachOResolving
@_exported import MachOPointers
