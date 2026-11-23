@_spi(Internals) import MachOCaches

extension SharedCacheEvictionGroup {
    /// ``SymbolIndexStore``'s indexes: the C and C++ symbols of
    /// an image. MachOSwiftSection's Swift symbol store has a group of its
    /// own.
    @_spi(Internals)
    public static let symbolStore = SharedCacheEvictionGroup("symbolStore")
}
