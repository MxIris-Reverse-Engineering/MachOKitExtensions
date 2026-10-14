#if canImport(Darwin)
import Foundation
import Testing
import MachOKit
import MachOKitExtensions

/// A host's type that holds a `MachOFile` or `MachOImage` and forwards every
/// read to it is asked what it reads through — `asMachOFile`, `asMachOImage`,
/// `underlyingReader` — and answers for the reader beneath it, once it declares
/// that it wraps one.
struct MachOReaderWrapperTests {
    @Test("a declared wrapper of a file reads through that file")
    func declaredFileWrapperReadsThroughTheFile() throws {
        let machOFile = try Self.foundationInSystemCache()
        let wrapper = ForwardingReader<MachOFile, DeclaredWrapper>(machOFile)
        #expect(wrapper.asMachOFile === machOFile)
        #expect(wrapper.asMachOImage == nil)
        #expect(wrapper.underlyingReader as? MachOFile === machOFile)
    }

    @Test("a wrapper of a wrapper reads through the image at the bottom")
    func nestedWrapperReadsThroughTheImageAtTheBottom() throws {
        let machOImage = try #require(MachOImage(name: "Foundation"))
        let wrapper = ForwardingReader<ForwardingReader<MachOImage, DeclaredWrapper>, DeclaredWrapper>(.init(machOImage))
        #expect(wrapper.asMachOImage?.ptr == machOImage.ptr)
        #expect(wrapper.asMachOFile == nil)
        #expect((wrapper.underlyingReader as? MachOImage)?.ptr == machOImage.ptr)
    }

    @Test("a wrapper that does not declare what it wraps reads through neither reader")
    func undeclaredWrapperReadsThroughNeitherReader() throws {
        let machOImage = try #require(MachOImage(name: "Foundation"))
        let wrapper = ForwardingReader<MachOImage, UndeclaredWrapper>(machOImage)
        #expect(wrapper.asMachOImage == nil)
        #expect(wrapper.asMachOFile == nil)
        #expect(wrapper.underlyingReader is ForwardingReader<MachOImage, UndeclaredWrapper>)
    }

    /// An in-process image counts its addresses from where it is loaded; a
    /// reader the package did not see through was counted from the start of
    /// the shared region instead.
    @Test("a declared wrapper of an in-process cache image prints the image's addresses")
    func declaredImageWrapperPrintsTheImageAddresses() throws {
        let machOImage = try #require(MachOImage(name: "Foundation"))
        try #require(machOImage.cache != nil, "Foundation is expected to be loaded from the shared cache")
        let wrapper = ForwardingReader<MachOImage, DeclaredWrapper>(machOImage)
        for offset in [0, 0x1000, 0x10_0000] {
            #expect(wrapper.address(forOffset: offset) == machOImage.address(forOffset: offset))
        }
    }

    private static func foundationInSystemCache() throws -> MachOFile {
        let cache = try #require(FullDyldCache.cachedHost, "no host dyld shared cache")
        return try #require(cache.machOFile(by: .name("Foundation")))
    }
}
#endif
