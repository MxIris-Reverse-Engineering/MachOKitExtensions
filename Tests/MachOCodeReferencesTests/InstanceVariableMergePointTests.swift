import Foundation
import Testing
import MachOKit
@_spi(Internals) import MachOCodeReferences

/// An address `adrp` / `add` builds on a slot a session watches — an
/// instance variable's offset variable — reaches the session where it is
/// built, and the load through it records nothing more. At a load two paths
/// reach with different offset variables in the register, the register is
/// unknown, so where each path builds its address is the only place its
/// instance variable shows: Finder 26.5.2's
/// `-[TTaskErrorOrConflictViewController setResolutionsForKind:]` reads
/// `_middleResolution` or `_rightResolution` this way, and the 2026-11-26
/// recall benchmark found the second missing (evolution proposal
/// `cross-reference-recall-gaps`).
@Suite(.enabled(if: ScanShapesFixture.isSupported, "the fixture is arm64 assembly"))
struct InstanceVariableMergePointTests {
    private static func watchedLoads(inFunctionNamed name: String) throws -> (loads: [(slot: UInt64, instructionAddress: UInt64)], start: UInt64, machO: MachOFile) {
        let machO = try ScanShapesFixture.machOFile()
        let offsetVariables = try ScanShapesFixture.range(ofSection: "__objc_ivar", inSegment: "__DATA", of: machO)
        let session = WatchingSession(watchedSlotRanges: [offsetVariables])
        ScanShapesFixture.scan(machO, session: session, recording: CoreRecording(), recordsFunctionAddressReferences: false)
        let function = try ScanShapesFixture.range(ofFunctionNamed: name, in: machO)
        let loads = session.watchedLoads.filter { function.contains($0.instructionAddress) }
        return (loads, function.lowerBound, machO)
    }

    @Test func instanceVariableAddressesBuiltOnPathsThatMeetAtTheLoad() throws {
        let (loads, start, machO) = try Self.watchedLoads(inFunctionNamed: "_offsetAtMergePoint")
        let offsetVariable = try ScanShapesFixture.address(ofSymbolNamed: "_offsetVariable", in: machO)
        let secondOffsetVariable = try ScanShapesFixture.address(ofSymbolNamed: "_secondOffsetVariable", in: machO)
        // cmp, b.ne, mov, adrp, add (the second variable), b, mov, adrp, add
        // (the first), then the ldrsw both paths reach.
        #expect(loads.map(\.instructionAddress) == [start + 4 * 4, start + 8 * 4])
        #expect(loads.map(\.slot) == [secondOffsetVariable, offsetVariable])
    }

    @Test func anInstanceVariableAddressIsRecordedWhereItIsBuiltNotAgainWhereItIsLoaded() throws {
        let (loads, start, machO) = try Self.watchedLoads(inFunctionNamed: "_offsetStraight")
        let offsetVariable = try ScanShapesFixture.address(ofSymbolNamed: "_offsetVariable", in: machO)
        // mov, adrp, then the add; not the ldrsw after it.
        #expect(loads.map(\.instructionAddress) == [start + 2 * 4])
        #expect(loads.map(\.slot) == [offsetVariable])
    }
}
