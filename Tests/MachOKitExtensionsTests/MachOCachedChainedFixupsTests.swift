import Foundation
import Testing
import MachOKit
import MachOKitExtensions

/// The cached view must answer every chained-fixup lookup exactly like
/// MachOKit's uncached method of the same name.
struct MachOCachedChainedFixupsTests {
    @Test("fixupPointers holds every chained fixup MachOKit walks", arguments: ChainedFixupsFixture.paths)
    func fixupPointersCoverEveryFixup(fixturePath: String) throws {
        for machOFile in try ChainedFixupsFixture.machOFiles(atPath: fixturePath) {
            let expectedOffsets = Set(ChainedFixupsFixture.fixupPointers(of: machOFile).map(\.offset))
            try #require(!expectedOffsets.isEmpty, "\(machOFile.header.cpu) has no chained fixups")
            #expect(Set(machOFile.cached.fixupPointers.keys) == expectedOffsets, "\(machOFile.header.cpu)")
        }
    }

    @Test("resolveRebase(at:) matches MachOKit", arguments: ChainedFixupsFixture.paths)
    func resolveRebaseMatchesMachOKit(fixturePath: String) throws {
        for machOFile in try ChainedFixupsFixture.machOFiles(atPath: fixturePath) {
            let rebaseOffsets = ChainedFixupsFixture.rebaseOffsets(of: machOFile)
            try #require(!rebaseOffsets.isEmpty, "\(machOFile.header.cpu) has no rebases")
            let cached = machOFile.cached
            let mismatchedOffsets = ChainedFixupsFixture.probeOffsets(forSlotOffsets: rebaseOffsets).filter { offset in
                cached.resolveRebase(at: offset) != machOFile.resolveRebase(at: offset)
            }
            #expect(mismatchedOffsets.isEmpty, "\(machOFile.header.cpu): \(mismatchedOffsets.prefix(10))")
        }
    }

    @Test("resolveOptionalRebase(at:) matches MachOKit", arguments: ChainedFixupsFixture.paths)
    func resolveOptionalRebaseMatchesMachOKit(fixturePath: String) throws {
        for machOFile in try ChainedFixupsFixture.machOFiles(atPath: fixturePath) {
            let rebaseOffsets = ChainedFixupsFixture.rebaseOffsets(of: machOFile)
            try #require(!rebaseOffsets.isEmpty, "\(machOFile.header.cpu) has no rebases")
            let cached = machOFile.cached
            let mismatchedOffsets = ChainedFixupsFixture.probeOffsets(forSlotOffsets: rebaseOffsets).filter { offset in
                cached.resolveOptionalRebase(at: offset) != machOFile.resolveOptionalRebase(at: offset)
            }
            #expect(mismatchedOffsets.isEmpty, "\(machOFile.header.cpu): \(mismatchedOffsets.prefix(10))")
        }
    }

    @Test("resolveBind(at:) matches MachOKit", arguments: ChainedFixupsFixture.paths)
    func resolveBindMatchesMachOKit(fixturePath: String) throws {
        for machOFile in try ChainedFixupsFixture.machOFiles(atPath: fixturePath) {
            let bindOffsets = ChainedFixupsFixture.bindOffsets(of: machOFile)
            try #require(!bindOffsets.isEmpty, "\(machOFile.header.cpu) has no binds")
            let cached = machOFile.cached
            let mismatchedOffsets = ChainedFixupsFixture.probeOffsets(forSlotOffsets: bindOffsets).filter { offset in
                ResolvedBind(cached.resolveBind(at: offset)) != ResolvedBind(machOFile.resolveBind(at: offset))
            }
            #expect(mismatchedOffsets.isEmpty, "\(machOFile.header.cpu): \(mismatchedOffsets.prefix(10))")
        }
    }

    @Test("resolveBind(fileOffset:) names the symbol MachOKit binds", arguments: ChainedFixupsFixture.paths)
    func resolveBindFileOffsetNamesTheBoundSymbol(fixturePath: String) throws {
        for machOFile in try ChainedFixupsFixture.machOFiles(atPath: fixturePath) {
            let dyldChainedFixups = try #require(machOFile.dyldChainedFixups)
            let bindOffsets = ChainedFixupsFixture.bindOffsets(of: machOFile)
            try #require(!bindOffsets.isEmpty, "\(machOFile.header.cpu) has no binds")
            let mismatchedOffsets = bindOffsets.filter { offset in
                let expectedName = machOFile.resolveBind(at: UInt64(offset)).flatMap { chainedImport, _ in
                    dyldChainedFixups.symbolName(for: chainedImport.info.nameOffset)
                }
                return machOFile.resolveBind(fileOffset: offset) != expectedName
            }
            #expect(mismatchedOffsets.isEmpty, "\(machOFile.header.cpu): \(mismatchedOffsets.prefix(10))")
        }
    }

    @Test("threads racing on a fresh file share one consistent cache")
    func concurrentFirstUseMatchesSequentialResults() throws {
        let fixturePath = try #require(ChainedFixupsFixture.paths.last)
        let referenceFile = try #require(try ChainedFixupsFixture.machOFiles(atPath: fixturePath).first)
        let probeOffsets = ChainedFixupsFixture.probeOffsets(
            forSlotOffsets: ChainedFixupsFixture.rebaseOffsets(of: referenceFile)
        )
        try #require(!probeOffsets.isEmpty)
        let expectedResults = probeOffsets.map { referenceFile.cached.resolveOptionalRebase(at: $0) }

        // A new instance, so the first uses below race to build its cache.
        let racingFile = try #require(try ChainedFixupsFixture.machOFiles(atPath: fixturePath).first)
        var racingResults = [UInt64?](repeating: nil, count: probeOffsets.count)
        racingResults.withUnsafeMutableBufferPointer { resultBuffer in
            DispatchQueue.concurrentPerform(iterations: probeOffsets.count) { index in
                resultBuffer[index] = racingFile.cached.resolveOptionalRebase(at: probeOffsets[index])
            }
        }
        #expect(racingResults == expectedResults)
    }
}
