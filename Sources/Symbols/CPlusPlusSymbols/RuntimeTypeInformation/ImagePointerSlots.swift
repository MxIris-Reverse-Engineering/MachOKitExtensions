import Foundation
import MachOKit
import MachOKitExtensions
import MachOReading
@_spi(Internals) import MachOSymbols

/// What the 8-byte slots of an image hold, read the way the image is stored:
/// a standalone file through its fixups, a file out of a dyld shared cache
/// through the cache's pointer format, an image of this process from memory.
///
/// Offsets are the ones the symbol indexes use: an offset from the header
/// for an image of this process, an unslid address minus the shared
/// region's start for a file out of a cache, a file offset for a standalone
/// file.
final class ImagePointerSlots: @unchecked Sendable {
    /// What a slot holds.
    enum Content: Hashable, Sendable {
        /// A pointer into this image. `topByte` is the top byte the pointer
        /// carries: Apple arm64 sets bit 63 of a typeinfo's name pointer
        /// when the typeinfo is not unique.
        case internalPointer(offset: Int, topByte: UInt8)
        /// A standalone file's bind: the symbol, the addend, and the library
        /// it is bound from (`nil` for a flat or weak lookup).
        case boundSymbol(name: String, addend: Int, installName: String?)
        /// A pointer into another image: an unslid address of the same dyld
        /// shared cache, or an address of this process.
        case externalAddress(UInt64)
    }

    /// The pointer bits of an address: everything below the top byte.
    static let addressBits: UInt64 = 0x00FF_FFFF_FFFF_FFFF

    let image: IndexedImage

    /// The sections a typeinfo or a vtable can sit in, as offset ranges in
    /// ascending order.
    let dataSectionRanges: [Range<Int>]

    /// The sections of the image's code, as offset ranges.
    let executableRanges: [Range<Int>]

    private let source: Source

    private enum Source {
        /// Every fixup of a standalone file, by slot offset.
        case standaloneFile(contentsByOffset: [Int: Content])
        /// A file out of a dyld shared cache: slots are decoded one at a
        /// time. `imageAddressRanges` are the image's segments as unslid
        /// addresses.
        case cacheFile(sharedRegionStart: UInt64, imageAddressRanges: [Range<UInt64>])
        /// An image of this process.
        case processImage(headerAddress: UInt64, imageAddressRanges: [Range<UInt64>])
    }

    init(image: IndexedImage) {
        self.image = image
        let sections: [any SectionProtocol]
        let offsetForAddress: (Int) -> Int
        switch image {
        case .file(let file):
            sections = file.sections
            let converter = SymbolValueOffsetConverter(for: file)
            offsetForAddress = { converter.offset(forSymbolValue: $0) }
            if let cache = file.cache {
                let sharedRegionStart = UInt64(cache.mainCacheHeader.sharedRegionStart)
                source = .cacheFile(sharedRegionStart: sharedRegionStart, imageAddressRanges: Self.imageAddressRanges(of: file.segments, slide: 0))
            } else {
                source = .standaloneFile(contentsByOffset: Self.fixupContents(of: file, image: image, offsetForAddress: offsetForAddress))
            }
        case .process(let processImage):
            sections = processImage.sections
            let textAddress = processImage.segments.first { $0.segmentName == "__TEXT" }.map { $0.virtualMemoryAddress } ?? 0
            offsetForAddress = { $0 - textAddress }
            let headerAddress = UInt64(UInt(bitPattern: processImage.ptr))
            source = .processImage(headerAddress: headerAddress, imageAddressRanges: Self.imageAddressRanges(of: processImage.segments, slide: Int64(bitPattern: headerAddress) - Int64(textAddress)))
        }
        var dataSectionRanges: [Range<Int>] = []
        var executableRanges: [Range<Int>] = []
        for section in sections where section.size > 0 {
            let start = offsetForAddress(section.address)
            let range = start ..< start + section.size
            if section.flags.attributes.contains(.pure_instructions) || section.flags.attributes.contains(.some_instructions) {
                executableRanges.append(range)
            } else if Self.mayHoldTypeInfoOrVirtualTable(section) {
                dataSectionRanges.append(range)
            }
        }
        self.dataSectionRanges = dataSectionRanges.sorted { $0.lowerBound < $1.lowerBound }
        self.executableRanges = executableRanges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The slot's content; `nil` for a word that holds no pointer, and for a
    /// null pointer.
    func content(atOffset offset: Int) -> Content? {
        switch source {
        case .standaloneFile(let contentsByOffset):
            return contentsByOffset[offset]
        case .cacheFile(let sharedRegionStart, let imageAddressRanges):
            if let decodedCacheDataSlots, dataSectionRanges.contains(where: { $0.contains(offset) }) {
                return decodedCacheDataSlots[offset]
            }
            // An offset-to-top or a vcall offset is no pointer, though the
            // cache's format would decode it into an address.
            guard case .file(let file) = image,
                  let stored = word(atOffset: offset), !Self.isNonPositiveSmallInteger(stored),
                  let (cache, cacheOffset) = file.resolveCacheStartOffsetIfNeeded(offset: UInt64(offset)),
                  let resolved = cache.resolveOptionalRebase(at: cacheOffset) else {
                return nil
            }
            return Self.cacheContent(ofResolvedAddress: resolved, sharedRegionStart: sharedRegionStart, imageAddressRanges: imageAddressRanges)
        case .processImage(let headerAddress, let imageAddressRanges):
            #if canImport(Darwin)
            guard case .process(let processImage) = image else { return nil }
            let raw = processImage.ptr.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            guard !Self.isSmallInteger(Int64(bitPattern: raw)) else { return nil }
            let address = raw & UInt64(InProcessContext.addressMask)
            guard address != 0 else { return nil }
            if imageAddressRanges.contains(where: { $0.contains(address) }) {
                return .internalPointer(offset: Int(address - headerAddress), topByte: UInt8(truncatingIfNeeded: raw >> 56))
            }
            return .externalAddress(address)
            #else
            return nil
            #endif
        }
    }

    /// The 8 bytes at `offset` as a signed integer, as stored.
    func word(atOffset offset: Int) -> Int64? {
        switch image {
        case .file(let file):
            return try? file.readElement(offset: offset) as Int64
        case .process(let processImage):
            return processImage.ptr.loadUnaligned(fromByteOffset: offset, as: Int64.self)
        }
    }

    /// The 4 bytes at `offset` as an unsigned integer, as stored.
    func unsignedWord32(atOffset offset: Int) -> UInt32? {
        switch image {
        case .file(let file):
            return try? file.readElement(offset: offset) as UInt32
        case .process(let processImage):
            return processImage.ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
    }

    /// The C string at `offset`.
    func string(atOffset offset: Int) -> String? {
        switch image {
        case .file(let file):
            return try? file.readString(offset: offset)
        case .process(let processImage):
            return String(cString: processImage.ptr.advanced(by: offset).assumingMemoryBound(to: CChar.self))
        }
    }

    /// Whether a word holds an integer rather than a pointer: an
    /// offset-to-top, a vcall or a virtual base offset. A standalone file
    /// says so through its fixups; a cache file or an image of this process
    /// stores pointers that are never this small.
    func holdsSmallInteger(atOffset offset: Int) -> Bool {
        if case .standaloneFile(let contentsByOffset) = source, contentsByOffset[offset] != nil {
            return false
        }
        guard let value = word(atOffset: offset) else { return false }
        return Self.isSmallInteger(value)
    }

    /// Whether a stored word is an integer no pointer of this process can
    /// be.
    static func isSmallInteger(_ value: Int64) -> Bool {
        value >= -(1 << 31) && value < (1 << 31)
    }

    /// Whether a stored word is an integer no pointer of a cache file can be.
    /// A small positive word can: a pointer that ends its page's chain and
    /// targets the first two gigabytes of the cache is stored as its offset.
    /// Such an integer decodes into the cache's header, which no image holds.
    static func isNonPositiveSmallInteger(_ value: Int64) -> Bool {
        value >= -(1 << 31) && value <= 0
    }

    /// Whether `offset` lies in the image's code.
    func isExecutable(offset: Int) -> Bool {
        executableRanges.contains { $0.contains(offset) }
    }

    /// Calls `body` with every pointer-sized slot of the data sections that
    /// holds a pointer, in ascending order.
    func forEachDataSlot(_ body: (Int, Content) -> Void) {
        switch source {
        case .standaloneFile(let contentsByOffset):
            for offset in contentsByOffset.keys.sorted() where dataSectionRanges.contains(where: { $0.contains(offset) }) {
                body(offset, contentsByOffset[offset]!)
            }
        case .cacheFile:
            let decoded = decodedCacheDataSlots ?? decodeCacheDataSlots()
            decodedCacheDataSlots = decoded
            for offset in decoded.keys.sorted() {
                body(offset, decoded[offset]!)
            }
        case .processImage:
            for range in dataSectionRanges {
                var offset = (range.lowerBound + 7) & ~7
                while offset + 8 <= range.upperBound {
                    if let content = content(atOffset: offset) {
                        body(offset, content)
                    }
                    offset += 8
                }
            }
        }
    }

    // MARK: - Building

    /// A cache file's data slots that hold pointers, decoded the first time
    /// the data is walked; later lookups in the data read them from here.
    private var decodedCacheDataSlots: [Int: Content]?

    /// Decodes every pointer of a cache file's data sections: each section's
    /// words are read at once and its place in the cache is looked up once.
    private func decodeCacheDataSlots() -> [Int: Content] {
        guard case .file(let file) = image, case .cacheFile(let sharedRegionStart, let imageAddressRanges) = source else { return [:] }
        var contentsByOffset: [Int: Content] = [:]
        for range in dataSectionRanges {
            let start = (range.lowerBound + 7) & ~7
            let wordCount = (range.upperBound - start) / 8
            guard wordCount > 0,
                  let words = try? file.readElements(offset: start, numberOfElements: wordCount) as [Int64],
                  let (cache, startCacheOffset) = file.resolveCacheStartOffsetIfNeeded(offset: UInt64(start)) else {
                continue
            }
            for (wordIndex, stored) in words.enumerated() where !Self.isNonPositiveSmallInteger(stored) {
                guard let resolved = cache.resolveOptionalRebase(at: startCacheOffset + UInt64(8 * wordIndex)),
                      let content = Self.cacheContent(ofResolvedAddress: resolved, sharedRegionStart: sharedRegionStart, imageAddressRanges: imageAddressRanges) else {
                    continue
                }
                contentsByOffset[start + 8 * wordIndex] = content
            }
        }
        return contentsByOffset
    }

    private static func cacheContent(ofResolvedAddress resolved: UInt64, sharedRegionStart: UInt64, imageAddressRanges: [Range<UInt64>]) -> Content? {
        let address = resolved & addressBits
        guard address != 0 else { return nil }
        if imageAddressRanges.contains(where: { $0.contains(address) }), address >= sharedRegionStart {
            return .internalPointer(offset: Int(address - sharedRegionStart), topByte: UInt8(truncatingIfNeeded: resolved >> 56))
        }
        return .externalAddress(address)
    }

    private static let excludedSectionNames: Set<String> = [
        "__got", "__auth_got", "__la_symbol_ptr", "__nl_symbol_ptr", "__cfstring", "__mod_init_func", "__mod_term_func", "__init_offsets",
    ]

    private static func mayHoldTypeInfoOrVirtualTable(_ section: any SectionProtocol) -> Bool {
        let segmentName = section.segmentName
        guard segmentName.hasPrefix("__DATA") || segmentName.hasPrefix("__AUTH") else { return false }
        switch section.flags.type {
        case .zerofill, .gb_zerofill, .thread_local_zerofill:
            return false
        default:
            break
        }
        let sectionName = section.sectionName
        return !excludedSectionNames.contains(sectionName) && !sectionName.hasPrefix("__objc_") && !sectionName.hasPrefix("__thread_")
    }

    /// The image's segments other than `__PAGEZERO` and `__LINKEDIT`, as
    /// address ranges moved by `slide`.
    private static func imageAddressRanges(of segments: [any SegmentCommandProtocol], slide: Int64) -> [Range<UInt64>] {
        segments.compactMap { segment in
            guard segment.segmentName != "__PAGEZERO", segment.segmentName != "__LINKEDIT", segment.virtualMemorySize > 0 else { return nil }
            let start = UInt64(bitPattern: Int64(segment.virtualMemoryAddress) &+ slide)
            return start ..< start &+ UInt64(segment.virtualMemorySize)
        }
    }

    /// Every pointer of a standalone file by slot offset: walks the chained
    /// fixups once, or reads the rebase and bind opcodes of a file that has
    /// none.
    private static func fixupContents(of file: MachOFile, image: IndexedImage, offsetForAddress: (Int) -> Int) -> [Int: Content] {
        var contentsByOffset: [Int: Content] = [:]
        let textAddress = file.segments.first { $0.segmentName == "__TEXT" }.map { $0.virtualMemoryAddress } ?? 0
        let cached = file.cached
        if let chainedFixups = cached.dyldChainedFixups {
            let fixupPointers = cached.fixupPointers
            contentsByOffset.reserveCapacity(fixupPointers.count)
            for (headerOffset, pointer) in fixupPointers {
                let slotOffset = offsetForAddress(textAddress + headerOffset)
                if pointer.fixupInfo.bind != nil {
                    guard let (chainedImport, pointerAddend) = cached.resolveBind(at: UInt64(headerOffset)),
                          let name = chainedFixups.symbolName(for: chainedImport.info.nameOffset) else {
                        continue
                    }
                    contentsByOffset[slotOffset] = .boundSymbol(
                        name: name,
                        addend: Int(truncatingIfNeeded: pointerAddend) &+ chainedImport.info.addend,
                        installName: image.installName(forLibraryOrdinal: chainedImport.info.libraryOrdinal)
                    )
                } else if pointer.fixupInfo.rebase != nil, let runtimeOffset = pointer.rebaseTargetRuntimeOffset(for: file) {
                    let targetHeaderOffset = Int(truncatingIfNeeded: runtimeOffset & addressBits)
                    contentsByOffset[slotOffset] = .internalPointer(
                        offset: offsetForAddress(textAddress + targetHeaderOffset),
                        topByte: UInt8(truncatingIfNeeded: runtimeOffset >> 56)
                    )
                }
            }
            return contentsByOffset
        }
        let segments = file.segments
        for rebase in file.rebases where rebase.type == .pointer {
            guard segments.indices.contains(rebase.segmentIndex) else { continue }
            let slotOffset = offsetForAddress(segments[rebase.segmentIndex].virtualMemoryAddress + Int(rebase.segmentOffset))
            guard let stored = try? file.readElement(offset: slotOffset) as UInt64 else { continue }
            let address = stored & addressBits
            guard address != 0 else { continue }
            contentsByOffset[slotOffset] = .internalPointer(offset: offsetForAddress(Int(address)), topByte: UInt8(truncatingIfNeeded: stored >> 56))
        }
        for binding in file.bindingSymbols + file.weakBindingSymbols where binding.type == .pointer {
            let segmentIndex = Int(binding.segmentIndex)
            guard segments.indices.contains(segmentIndex) else { continue }
            let slotOffset = offsetForAddress(segments[segmentIndex].virtualMemoryAddress + Int(binding.segmentOffset))
            contentsByOffset[slotOffset] = .boundSymbol(
                name: binding.symbolName,
                addend: binding.addend,
                installName: image.installName(forLibraryOrdinal: binding.libraryOrdinal)
            )
        }
        return contentsByOffset
    }
}
