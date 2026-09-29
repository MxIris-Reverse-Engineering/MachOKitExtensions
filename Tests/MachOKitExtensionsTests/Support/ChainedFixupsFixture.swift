import Foundation
import MachOKit

/// On-disk system binaries that use chained fixups, and the offsets to probe
/// in them.
enum ChainedFixupsFixture {
    /// `curl` ships x86_64 and arm64e slices that both use chained fixups,
    /// covering the x86_64 and the arm64e pointer formats; Freeform is a large
    /// app with many binds.
    static let paths = [
        "/usr/bin/curl",
        "/System/Applications/Freeform.app/Contents/MacOS/Freeform",
    ]

    /// Probes per fixup kind and slice. MachOKit's uncached `resolveBind(at:)`
    /// walks every chain on each call, so comparing against it at every slot of
    /// a large binary would take minutes.
    static let maximumProbesPerKind = 200

    /// A fresh `MachOFile` for every slice of the binary at `path`.
    static func machOFiles(atPath path: String) throws -> [MachOFile] {
        switch try MachOKit.loadFromFile(url: URL(fileURLWithPath: path)) {
        case .machO(let machOFile):
            [machOFile]
        case .fat(let fatFile):
            try fatFile.machOFiles()
        }
    }

    /// Every chained fixup pointer of `machOFile`, walked with MachOKit's own
    /// API so the probe set does not depend on the cache under test.
    static func fixupPointers(of machOFile: MachOFile) -> [DyldChainedFixupPointer] {
        guard let dyldChainedFixups = machOFile.dyldChainedFixups,
              let startsInImage = dyldChainedFixups.startsInImage else {
            return []
        }
        return dyldChainedFixups.startsInSegments(of: startsInImage).flatMap { startsInSegment in
            dyldChainedFixups.pointers(of: startsInSegment, in: machOFile)
        }
    }

    /// An even spread of rebase slots.
    static func rebaseOffsets(of machOFile: MachOFile) -> [Int] {
        evenlySpaced(fixupPointers(of: machOFile).filter { $0.fixupInfo.rebase != nil }.map(\.offset).sorted())
    }

    /// An even spread of bind slots.
    static func bindOffsets(of machOFile: MachOFile) -> [Int] {
        evenlySpaced(fixupPointers(of: machOFile).filter { $0.fixupInfo.bind != nil }.map(\.offset).sorted())
    }

    /// Each slot offset followed by the byte after it, which is never the start
    /// of a slot and so must resolve to `nil`.
    static func probeOffsets(forSlotOffsets slotOffsets: [Int]) -> [UInt64] {
        slotOffsets.flatMap { [UInt64($0), UInt64($0 + 1)] }
    }

    private static func evenlySpaced(_ offsets: [Int]) -> [Int] {
        guard offsets.count > maximumProbesPerKind else {
            return offsets
        }
        let step = offsets.count / maximumProbesPerKind
        return stride(from: 0, to: offsets.count, by: step).map { offsets[$0] }
    }
}

/// The comparable parts of a resolved bind.
struct ResolvedBind: Equatable {
    let libraryOrdinal: Int
    let nameOffset: Int
    let addend: UInt64

    init?(_ resolvedBind: (DyldChainedImport, addend: UInt64)?) {
        guard let (chainedImport, addend) = resolvedBind else {
            return nil
        }
        self.libraryOrdinal = chainedImport.info.libraryOrdinal
        self.nameOffset = chainedImport.info.nameOffset
        self.addend = addend
    }
}
