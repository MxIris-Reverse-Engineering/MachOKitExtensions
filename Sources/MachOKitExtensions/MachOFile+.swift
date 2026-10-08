import Foundation
import MachOKit
import AssociatedObject

extension MachOFile {
    public func cache(for address: UInt64) -> DyldCache? {
        cacheAndFileOffset(for: address)?.0
    }

    /// Convert an address that is not slided into the actual cache it contains and the file offset in it.
    ///
    /// A sub-cache comes back as the same `DyldCache` instance on every call
    /// on this file, so whatever a caller keeps per cache instance survives
    /// from one lookup to the next. From a cache opened from its main file
    /// alone, a sub-cache file a lookup has landed in stays open for as long
    /// as this file does.
    /// - Parameter address: address (unslid)
    /// - Returns: cache and file offset
    public func cacheAndFileOffset(for address: UInt64) -> (DyldCache, UInt64)? {
        guard let cache else { return nil }
        if let offset = cache.fileOffset(of: address) {
            return (cache, offset)
        }
        guard let mainCache = cache.mainCache else {
            return nil
        }

        if let offset = mainCache.fileOffset(of: address) {
            return (mainCache, offset)
        }

        return cached.subCacheTable?.cacheAndFileOffset(for: address)
    }

    /// Converts the offset from the start of the main cache to the actual cache
    /// it contains and the file offset within that cache.
    /// - Parameter offset: Offset from the start of the main cache.
    /// - Returns: cache and file offset
    public func cacheAndFileOffset(fromStart offset: UInt64) -> (DyldCache, UInt64)? {
        guard let cache else { return nil }
        return cacheAndFileOffset(
            for: cache.mainCacheHeader.sharedRegionStart + offset
        )
    }

    // Resolves the rebase operation at the specified file offset within the given MachO file.
    //
    // This function determines if the rebase operation can be resolved from the provided file offset
    // in the MachO file. If the MachO file is loaded from a Dyld shared cache, the rebase is resolved
    // using the cache information. Otherwise, it directly resolves the rebase using the MachO file.
    //
    // - Parameters:
    //   - fileOffset: The offset in the file where the rebase operation occurs.
    //   - machO: The `MachOFile` object representing the MachO file to resolve rebases from.
    // - Returns: The resolved rebase value as a `UInt64`, or `nil` if the rebase cannot be resolved.

    @AssociatedObject(.retain(.nonatomic))
    private var _resolveRebaseCache: [Int: UInt64] = [:]

    public func resolveRebase(fileOffset: Int) -> UInt64? {
        let offset: UInt64 = numericCast(fileOffset)

        if let cached = _resolveRebaseCache[fileOffset] {
            return cached
        }

        if let (cache, _offset) = resolveCacheStartOffsetIfNeeded(offset: offset), let resolved = cache.resolveOptionalRebase(at: _offset) {
            let result = resolved - cache.mainCacheHeader.sharedRegionStart
            _resolveRebaseCache[fileOffset] = result
            return result
        }

        if cache != nil {
            return nil
        }

        if let resolved = cached.resolveOptionalRebase(at: offset) {
            _resolveRebaseCache[fileOffset] = resolved
            return resolved
        }
        return nil
    }

    // Resolves the bind operation at the specified file offset within the given MachO file.
    //
    // This function determines if the bind operation can be resolved from the provided file offset
    // in the MachO file. Bind operations are used to dynamically link symbols at runtime.
    //
    // The function checks the following conditions:
    // 1. The MachO file must not be loaded from the Dyld shared cache. If it is, the method returns `nil`.
    // 2. When the file carries `dyldChainedFixups` data, the bind is resolved from the chained fixups;
    //    otherwise it falls back to the LC_DYLD_INFO(_ONLY) bind opcode-stream index (legacy binaries
    //    with deployment targets predating chained fixups).
    //
    // If these conditions are satisfied, the method attempts to resolve the bind operation at the given offset
    // and retrieves the associated symbol name.
    //
    // - Parameters:
    //   - fileOffset: An `Int` value representing the offset in the file where the bind operation occurs.
    //   - machO: The `MachOFile` object representing the MachO file to analyze.
    // - Returns: The resolved symbol name as a `String`, or `nil` if the bind operation cannot be resolved.

    @AssociatedObject(.retain(.nonatomic))
    private var _resolveBindCache: [UInt64: String] = [:]

    public func resolveBind(fileOffset: Int) -> String? {
        guard !isLoadedFromDyldCache else { return nil }

        let offset: UInt64 = numericCast(fileOffset)

        if let cached = _resolveBindCache[offset] {
            return cached
        }

        let result: String?
        let cached = self.cached
        if let fixup = cached.dyldChainedFixups {
            guard let resolved = cached.resolveBind(at: offset) else { return nil }
            result = fixup.symbolName(for: resolved.0.info.nameOffset)
        } else {
            // Legacy binaries (deployment target < macOS 12 / iOS 16, e.g.
            // the iOS 15.5 simulator frameworks) carry no chained fixups;
            // their bind slots are described only by the LC_DYLD_INFO(_ONLY)
            // opcode streams.
            result = dyldInfoBindsByFileOffset[offset]?.symbolName
        }
        if let result {
            _resolveBindCache[offset] = result
        }
        return result
    }

    /// Resolves a bind that dyld satisfies from this image itself.
    ///
    /// A dylib linked `-interposable` reaches its own exported symbols the way
    /// it reaches another library's: through a bind to `BIND_SPECIAL_DYLIB_SELF`
    /// rather than a rebase. Apple builds the frameworks of a simulator runtime
    /// this way, so a pointer to an exported class, metaclass or ivar offset
    /// of such a file holds a bind even though its target is in the file. This
    /// resolves it to the export it names, as dyld does at load time.
    ///
    /// - Parameter fileOffset: The offset of the slot from the Mach-O header.
    /// - Returns: The bound symbol's offset from the image's load address plus
    ///   the bind's addend — the convention `cached.resolveRebase(at:)`
    ///   answers in — or `nil` when the slot holds no bind, binds into another
    ///   image, or names a symbol this image does not export.
    public func resolveSelfBind(fileOffset: Int) -> UInt64? {
        guard !isLoadedFromDyldCache else { return nil }

        let offset: UInt64 = numericCast(fileOffset)
        let symbolName: String
        let addend: Int
        let cached = self.cached
        if let fixup = cached.dyldChainedFixups {
            guard let (chainedImport, pointerAddend) = cached.resolveBind(at: offset),
                  chainedImport.info.libraryOrdinalType == .dylib_self,
                  let name = fixup.symbolName(for: chainedImport.info.nameOffset) else {
                return nil
            }
            symbolName = name
            addend = Int(truncatingIfNeeded: pointerAddend) &+ chainedImport.info.addend
        } else {
            guard let bind = dyldInfoBindsByFileOffset[offset],
                  bind.libraryOrdinal == Int(BindSpecial.dylib_self.rawValue) else {
                return nil
            }
            symbolName = bind.symbolName
            addend = bind.addend
        }

        // A re-export names a symbol of another image and carries no offset.
        guard let exportedSymbol = cached.exportTrie?.search(by: symbolName),
              !exportedSymbol.flags.contains(.reexport),
              let symbolOffset = exportedSymbol.offset else {
            return nil
        }
        return UInt64(bitPattern: Int64(symbolOffset &+ addend))
    }

    /// One slot an LC_DYLD_INFO(_ONLY) bind stream binds.
    private struct DyldInfoBind {
        let symbolName: String
        /// The library ordinal in force for the slot: a dependency's index
        /// from 1, or one of the `BIND_SPECIAL_DYLIB_*` values from 0 down.
        /// `nil` for a weak bind, which dyld satisfies by name from whichever
        /// image defines the symbol first.
        let libraryOrdinal: Int?
        let addend: Int
    }

    @AssociatedObject(.retain(.nonatomic))
    private var _dyldInfoBindsByFileOffset: [UInt64: DyldInfoBind]? = nil

    private var dyldInfoBindsByFileOffset: [UInt64: DyldInfoBind] {
        if let indexed = _dyldInfoBindsByFileOffset {
            return indexed
        }
        let indexed = makeDyldInfoBindsByFileOffset()
        _dyldInfoBindsByFileOffset = indexed
        return indexed
    }

    // Interprets the LC_DYLD_INFO(_ONLY) bind opcode streams (the dyld
    // state machine over segment index / segment offset / symbol name /
    // library ordinal / addend) into a file-offset → bind index, so
    // `resolveBind(fileOffset:)` and `resolveSelfBind(fileOffset:)` can answer
    // for pre-chained-fixups binaries exactly like they do for chained ones.
    private func makeDyldInfoBindsByFileOffset() -> [UInt64: DyldInfoBind] {
        guard is64Bit else { return [:] }
        let segmentFileOffsets = segments.map { UInt64($0.fileOffset) }
        let segmentFileSizes = segments.map { UInt64($0.fileSize) }
        let pointerSize: UInt = 8
        var bindsByFileOffset: [UInt64: DyldInfoBind] = [:]
        let streams: [(operations: BindOperations, isWeak: Bool)] = [
            bindOperations.map { ($0, false) },
            weakBindOperations.map { ($0, true) },
        ].compactMap { $0 }
        for (operations, isWeak) in streams {
            // The opcode stream is binary-supplied input (this library
            // analyzes arbitrary third-party files): the segment offset and
            // the repeat count arrive as raw unvalidated ulebs, so every
            // slot is bounds-checked against its segment's file size the
            // way dyld bounds slots against the segment — a slot outside
            // the segment is never recorded (a wrapped offset would claim
            // an unrelated file offset), and walking past the segment end
            // terminates a repeat run (a hostile 2^40 count would
            // otherwise spin to OOM). The segment index itself is a 4-bit
            // opcode immediate, so it only needs the range check.
            var segmentIndex = 0
            var segmentOffset: UInt = 0
            var symbolName: String?
            var libraryOrdinal = 0
            var addend = 0
            func currentSlotIsWithinSegment() -> Bool {
                guard segmentFileOffsets.indices.contains(segmentIndex) else { return false }
                let segmentFileSize = segmentFileSizes[segmentIndex]
                guard segmentFileSize >= UInt64(pointerSize) else { return false }
                return UInt64(segmentOffset) <= segmentFileSize - UInt64(pointerSize)
            }
            func recordCurrentSlot() {
                guard currentSlotIsWithinSegment(), let symbolName else { return }
                bindsByFileOffset[segmentFileOffsets[segmentIndex] &+ UInt64(segmentOffset)] = DyldInfoBind(
                    symbolName: symbolName,
                    libraryOrdinal: isWeak ? nil : libraryOrdinal,
                    addend: addend
                )
            }
            operationLoop: for operation in operations {
                switch operation {
                case .set_symbol_trailing_flags_imm(_, let symbol):
                    symbolName = symbol
                case .set_dylib_ordinal_imm(let ordinal), .set_dylib_ordinal_uleb(let ordinal):
                    libraryOrdinal = ordinal
                case .set_dylib_special_imm(let special):
                    libraryOrdinal = Int(special.rawValue)
                case .set_addend_sleb(let value):
                    addend = value
                case .set_segment_and_offset_uleb(let segment, let offset):
                    segmentIndex = Int(segment)
                    segmentOffset = offset
                case .add_addr_uleb(let offset):
                    // Negative deltas arrive as two's-complement ulebs; the
                    // wrapping addition reproduces dyld's pointer arithmetic.
                    segmentOffset &+= offset
                case .do_bind:
                    recordCurrentSlot()
                    segmentOffset &+= pointerSize
                case .do_bind_add_addr_uleb(let offset):
                    recordCurrentSlot()
                    segmentOffset &+= pointerSize &+ offset
                case .do_bind_add_addr_imm_scaled(let scale):
                    recordCurrentSlot()
                    segmentOffset &+= pointerSize &+ scale &* pointerSize
                case .do_bind_uleb_times_skipping_uleb(let count, let skip):
                    for _ in 0 ..< count {
                        guard currentSlotIsWithinSegment() else { break }
                        recordCurrentSlot()
                        segmentOffset &+= pointerSize &+ skip
                    }
                case .threaded:
                    // The arm64e pre-chained threaded format encodes slot
                    // targets differently; indexing it here would claim
                    // wrong offsets.
                    break operationLoop
                case .done, .set_type_imm:
                    break
                }
            }
        }
        return bindsByFileOffset
    }

    // Determines whether the specified file offset within the MachO file represents a bind operation.
    //
    // This function evaluates if the file offset corresponds to a bind operation. Bind operations
    // are used in MachO files to dynamically link symbols at runtime.
    //
    // The function operates as follows:
    // 1. Checks if the MachO file is loaded from the Dyld shared cache. If so, returns `false` as
    //    bind operations cannot be evaluated in this context.
    // 2. Converts the file offset to a `UInt64` value to ensure compatibility with MachOKit APIs.
    // 3. Invokes `machO.isBind(_:)` to determine if the specified offset corresponds to a bind operation.
    //
    // - Parameters:
    //   - fileOffset: The offset in the MachO file to check for a bind operation.
    //   - machO: The `MachOFile` instance representing the file being analyzed.
    // - Returns: A `Bool` indicating whether the specified offset represents a bind operation.

    public func isBind(fileOffset: Int) -> Bool {
        guard !isLoadedFromDyldCache else { return false }
        let offset: UInt64 = numericCast(fileOffset)
        return isBind(numericCast(offset))
    }

    public func isBind(_ offset: Int) -> Bool {
        // Same source split as `resolveBind(fileOffset:)`: chained fixups
        // when present, else the LC_DYLD_INFO(_ONLY) opcode-stream index —
        // the two public APIs must answer identically for the same slot.
        let cached = self.cached
        if cached.dyldChainedFixups != nil {
            return cached.resolveBind(at: numericCast(offset)) != nil
        }
        return dyldInfoBindsByFileOffset[numericCast(offset)] != nil
    }

    public func resolveCacheStartOffsetIfNeeded(
        offset: UInt64) -> (DyldCache, UInt64)? {
        if let (cache, _offset) = cacheAndFileOffset(
            fromStart: offset
        ) {
            return (cache, _offset)
        }
        return nil
    }
}
