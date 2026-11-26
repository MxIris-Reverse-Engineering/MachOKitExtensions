import Foundation
import Testing
import MachOKit
@_spi(Internals) import MachOCodeReferences

/// An address code builds that lies on a reference slot reads as the slot,
/// at the instruction that built it; a load through that address records
/// nothing more (evolution proposal `cross-reference-recall-gaps`).
@Suite(.enabled(if: ScanShapesFixture.isSupported, "the fixture is arm64 assembly"))
struct SlotAddressScanTests {
    private static func scannedFixture() throws -> (machO: MachOFile, recording: CoreRecording) {
        let machO = try ScanShapesFixture.machOFile()
        let recording = CoreRecording()
        ScanShapesFixture.scan(machO, session: WatchingSession(), recording: recording, recordsFunctionAddressReferences: false)
        return (machO, recording)
    }

    private static func functionRange(_ name: String, in machO: MachOFile) throws -> Range<UInt64> {
        try ScanShapesFixture.range(ofFunctionNamed: name, in: machO)
    }

    @Test func slotAddressInAStandaloneFileIsAnImportedSymbolReference() throws {
        let (machO, recording) = try Self.scannedFixture()
        let range = try Self.functionRange("_takesSlotAddress", in: machO)
        let references = recording.importedSymbolReferences(madeIn: range)
        #expect(references.count == 1)
        #expect(references.first?.name == "_malloc")
        // The `add` that finishes the slot's address.
        #expect(references.first?.instructionAddress == range.lowerBound + 4)
        #expect(references.first?.route == .pointerSlot)
    }

    @Test func aLoadThroughARecordedSlotAddressIsNotRecordedAgain() throws {
        let (machO, recording) = try Self.scannedFixture()
        let range = try Self.functionRange("_loadsThroughSlotAddress", in: machO)
        let references = recording.importedSymbolReferences(madeIn: range)
        #expect(references.map(\.instructionAddress) == [range.lowerBound + 4])
    }

    @Test func aLoadThroughACopiedSlotAddressIsNotRecordedAgain() throws {
        let (machO, recording) = try Self.scannedFixture()
        let range = try Self.functionRange("_loadsThroughCopiedSlotAddress", in: machO)
        let references = recording.importedSymbolReferences(madeIn: range)
        #expect(references.map(\.instructionAddress) == [range.lowerBound + 4])
    }

    /// The usual pair is recorded where it loads, as before.
    @Test func aSlotLoadIsRecordedWhereItLoads() throws {
        let (machO, recording) = try Self.scannedFixture()
        let range = try Self.functionRange("_loadsSlot", in: machO)
        let references = recording.importedSymbolReferences(madeIn: range)
        #expect(references.map(\.instructionAddress) == [range.lowerBound + 4])
        #expect(references.first?.route == .pointerSlot)
    }
}
