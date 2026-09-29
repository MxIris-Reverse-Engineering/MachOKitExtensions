import MachOKit

// Chained fixups exist only for `MachOFile`: in a `MachOImage` dyld has already
// applied every fixup and overwritten the chains in place.
extension MachOCached where Base == MachOFile {
    /// Cached equivalent of `MachOFile.dyldChainedFixups`.
    public var dyldChainedFixups: MachOFile.DyldChainedFixups? {
        storage.memoized(\.dyldChainedFixups) { base.dyldChainedFixups }
    }

    /// Every chained fixup pointer of the file, keyed by its offset from the
    /// Mach-O header.
    ///
    /// Built once by walking every chain of every segment. MachOKit walks the
    /// chains again on each `resolveRebase(at:)` / `resolveBind(at:)` call;
    /// this map turns each of those lookups into a dictionary access.
    public var fixupPointers: [Int: DyldChainedFixupPointer] {
        storage.memoized(\.fixupPointersByOffset) {
            guard let dyldChainedFixups,
                  let startsInImage = dyldChainedFixups.startsInImage else {
                return [:]
            }
            var fixupPointersByOffset: [Int: DyldChainedFixupPointer] = [:]
            for startsInSegment in dyldChainedFixups.startsInSegments(of: startsInImage) {
                for pointer in dyldChainedFixups.pointers(of: startsInSegment, in: base) {
                    fixupPointersByOffset[pointer.offset] = pointer
                }
            }
            return fixupPointersByOffset
        }
    }

    /// The chained fixup pointer at `offset` from the Mach-O header, if any.
    public func fixupPointer(at offset: Int) -> DyldChainedFixupPointer? {
        fixupPointers[offset]
    }

    /// Cached equivalent of `MachOFile.resolveRebase(at:)`.
    public func resolveRebase(at offset: UInt64) -> UInt64? {
        if base.isLoadedFromDyldCache, let cache = base.cache {
            return cache.resolveRebase(at: offset)
        }
        guard let pointer = fixupPointer(at: Int(offset)),
              pointer.fixupInfo.rebase != nil else {
            return nil
        }
        return pointer.rebaseTargetRuntimeOffset(for: base)
    }

    /// Cached equivalent of `MachOFile.resolveOptionalRebase(at:)`: like
    /// ``resolveRebase(at:)``, but a slot whose raw value is zero resolves to
    /// `nil`.
    public func resolveOptionalRebase(at offset: UInt64) -> UInt64? {
        if base.isLoadedFromDyldCache, let cache = base.cache {
            return cache.resolveOptionalRebase(at: offset)
        }
        guard let pointer = fixupPointer(at: Int(offset)),
              let rebase = pointer.fixupInfo.rebase,
              let rebaseTargetOffset = pointer.rebaseTargetRuntimeOffset(for: base),
              !isZeroSlot(rebase) else {
            return nil
        }
        return rebaseTargetOffset
    }

    /// Cached equivalent of `MachOFile.resolveBind(at:)`.
    public func resolveBind(at offset: UInt64) -> (DyldChainedImport, addend: UInt64)? {
        guard let pointer = fixupPointer(at: Int(offset)),
              pointer.fixupInfo.bind != nil,
              let (ordinal, addend) = pointer.bindOrdinalAndAddend(for: base) else {
            return nil
        }
        let imports = chainedImports
        guard imports.indices.contains(ordinal) else {
            return nil
        }
        return (imports[ordinal], addend)
    }

    var chainedImports: [DyldChainedImport] {
        storage.memoized(\.chainedImports) { dyldChainedFixups?.imports ?? [] }
    }

    /// Whether the fixup slot holds a raw value of zero.
    ///
    /// MachOKit reads the slot back from the file for this check, but the file
    /// handle it uses is not public. The decoded rebase carries the slot's raw
    /// bits in its C layout, so checking those bytes is equivalent.
    private func isZeroSlot(_ rebase: some DyldChainedPointerContentRebase) -> Bool {
        withUnsafeBytes(of: rebase.layout) { slotBytes in
            slotBytes.allSatisfy { $0 == 0 }
        }
    }
}
