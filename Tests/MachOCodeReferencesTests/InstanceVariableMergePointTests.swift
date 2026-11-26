import Foundation
import Testing
import MachOKit
@_spi(Internals) import MachOCodeReferences

/// A 32-bit load through an address `adrp` / `add` built reaches the session
/// watching the slot, wherever it lies: Finder 26.5.2's
/// `-[TTaskErrorOrConflictViewController setResolutionsForKind:]` reads
/// `_rightResolution`'s offset this way at an instruction several branches
/// reach, and that one load was the instance variable reference the 2026-11-26
/// recall benchmark found missing (evolution proposal
/// `cross-reference-recall-gaps`).
@Suite(.enabled(if: ScanShapesFixture.isSupported, "the fixture is arm64 assembly"))
struct InstanceVariableMergePointTests {
    private static func watchedLoads(inFunctionNamed name: String) throws -> (loads: [(slot: UInt64, instructionAddress: UInt64)], start: UInt64, offsetVariable: UInt64) {
        let machO = try ScanShapesFixture.machOFile()
        let offsetVariables = try ScanShapesFixture.range(ofSection: "__objc_ivar", inSegment: "__DATA", of: machO)
        let session = WatchingSession(watchedSlotRanges: [offsetVariables])
        ScanShapesFixture.scan(machO, session: session, recording: CoreRecording(), recordsFunctionAddressReferences: false)
        let function = try ScanShapesFixture.range(ofFunctionNamed: name, in: machO)
        let loads = session.watchedLoads.filter { function.contains($0.instructionAddress) }
        return (loads, function.lowerBound, try ScanShapesFixture.address(ofSymbolNamed: "_offsetVariable", in: machO))
    }

    @Test func instanceVariableLoadThroughAnAddedAddressAtAMergePoint() throws {
        let (loads, start, offsetVariable) = try Self.watchedLoads(inFunctionNamed: "_offsetAtMergePoint")
        // cmp, b.ne, mov, b, mov, adrp, add, then the ldrsw.
        #expect(loads.map(\.instructionAddress) == [start + 7 * 4])
        #expect(loads.map(\.slot) == [offsetVariable])
    }

    @Test func instanceVariableLoadThroughAnAddedAddressOutsideAMergePoint() throws {
        let (loads, start, offsetVariable) = try Self.watchedLoads(inFunctionNamed: "_offsetStraight")
        // mov, adrp, add, then the ldrsw.
        #expect(loads.map(\.instructionAddress) == [start + 3 * 4])
        #expect(loads.map(\.slot) == [offsetVariable])
    }
}
