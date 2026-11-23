import MachOKit

/// A reader that forwards every read to another reader, its ``base``.
///
/// A host often holds a `MachOFile` or a `MachOImage` inside a type of its own —
/// a UI-layer projection that adds what its views need — and makes that type a
/// reader by forwarding each requirement to the one it holds. What a reader is
/// underneath still matters: an image mapped into this process is read through
/// absolute pointers, a file through its own offset accounting, and per-image
/// facts are built differently for each. Declaring the wrapper lets every such
/// question be asked of the reader beneath it (``MachORepresentableWithCache/underlyingReader``,
/// ``MachORepresentable/asMachOImage``, ``MachORepresentable/asMachOFile``)
/// instead of coming back "neither".
///
/// `Base` is any reader, so a host's own reader type can be wrapped too, and a
/// wrapper can wrap another wrapper.
///
/// A conformer promises two things, which nothing checks:
///
/// - It reads, at every offset, exactly what `base` reads. Anything worked out
///   about `base` is used for the wrapper as it is.
/// - Its `identifier` is `base`'s. Per-image caches are keyed by the identifier,
///   so the wrapper and the reader it wraps share them.
public protocol MachOReaderWrapper: MachORepresentableWithCache {
    associatedtype Base: MachORepresentableWithCache

    /// The reader every read is forwarded to.
    var base: Base { get }
}

extension MachORepresentableWithCache {
    /// The reader beneath every layer of wrapping: `self` unless `self` is a
    /// ``MachOReaderWrapper``, in which case its `base`'s own underlying reader.
    ///
    /// Ask a capability of this rather than of `self` when a wrapper cannot be
    /// expected to forward it.
    public var underlyingReader: any MachORepresentableWithCache {
        guard let wrapper = self as? any MachOReaderWrapper else { return self }
        return wrapper.base.underlyingReader
    }
}

extension MachORepresentable {
    /// The `MachOImage` this reader reads through — itself, or the one beneath
    /// its wrappers — or `nil` when it reads through something else.
    public var asMachOImage: MachOImage? {
        if let machOImage = self as? MachOImage {
            return machOImage
        }
        return (self as? any MachOReaderWrapper)?.base.asMachOImage
    }

    /// The `MachOFile` this reader reads through — itself, or the one beneath
    /// its wrappers — or `nil` when it reads through something else.
    public var asMachOFile: MachOFile? {
        if let machOFile = self as? MachOFile {
            return machOFile
        }
        return (self as? any MachOReaderWrapper)?.base.asMachOFile
    }
}
