import MachOKit

extension MachOCached where Base == MachOFile {
    /// Cached equivalent of `MachOFile.exportTrie`.
    ///
    /// MachOKit reads the trie's bytes from the file on every access, so a
    /// lookup per bound slot — `resolveSelfBind(fileOffset:)` makes one for
    /// each of the 1,586 self-bound class list entries of the iOS 18.5
    /// simulator's UIKitCore — would read the whole trie once per slot.
    public var exportTrie: MachOFile.ExportTrie? {
        storage.memoized(\.exportTrie) { base.exportTrie }
    }
}
