@_spi(Internals) import MachOCaches

extension SharedCacheEvictionGroup {
    /// ``CPlusPlusSymbolIndexStore``'s indexes: an image's C++ symbols
    /// arranged by scope.
    @_spi(Internals)
    public static let cPlusPlusSymbolStore = SharedCacheEvictionGroup("cPlusPlusSymbolStore")

    /// ``CPlusPlusClassIndexStore``'s indexes: an image's C++ classes read
    /// from its run-time type information and vtables.
    @_spi(Internals)
    public static let cPlusPlusClassStore = SharedCacheEvictionGroup("cPlusPlusClassStore")
}
