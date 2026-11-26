import Foundation
import Testing
import MachOKit
@_spi(Internals) import MachOCodeReferences

/// Code that builds a function's address references the function: a block's
/// invoke function, a callback handed to another function, a closure
/// returned (evolution proposal `cross-reference-recall-gaps`).
@Suite(.enabled(if: ScanShapesFixture.isSupported, "the fixture is arm64 assembly"))
struct FunctionAddressScanTests {
    private static func functionAddressReferences(recordingThem: Bool) throws -> (machO: MachOFile, recording: CoreRecording, session: WatchingSession) {
        let machO = try ScanShapesFixture.machOFile()
        let recording = CoreRecording()
        let session = WatchingSession()
        ScanShapesFixture.scan(machO, session: session, recording: recording, recordsFunctionAddressReferences: recordingThem)
        return (machO, recording, session)
    }

    @Test func takingAFunctionsAddressIsAReferenceToIt() throws {
        let (machO, recording, _) = try Self.functionAddressReferences(recordingThem: true)
        let target = try ScanShapesFixture.address(ofSymbolNamed: "_offsetStraight", in: machO)
        let addingStart = try ScanShapesFixture.address(ofSymbolNamed: "_takesFunctionAddress", in: machO)
        let adrStart = try ScanShapesFixture.address(ofSymbolNamed: "_takesFunctionAddressWithAdr", in: machO)
        let references = recording.functionAddressReferences.filter { $0.function.address == target }
        // The `add` of the `adrp` / `add` pair, and the `adr`.
        #expect(references.map(\.instructionAddress).sorted() == [addingStart + 4, adrStart].sorted())
        #expect(references.allSatisfy { $0.function.imageIndex == 0 && $0.kind == .reference && $0.route == .addressMaterialization })
    }

    @Test func anAddressInsideAFunctionIsNoReferenceToIt() throws {
        let (machO, recording, _) = try Self.functionAddressReferences(recordingThem: true)
        let interiorStart = try ScanShapesFixture.address(ofSymbolNamed: "_takesInteriorAddress", in: machO)
        #expect(!recording.functionAddressReferences.contains { $0.instructionAddress == interiorStart })
    }

    @Test func functionAddressReferencesAreRecordedOnlyWhenAskedFor() throws {
        let (_, recording, _) = try Self.functionAddressReferences(recordingThem: false)
        #expect(recording.functionAddressReferences.isEmpty)
    }

    /// The scan tells every session when it is done with a function, once
    /// for each function it entered.
    @Test func everyFunctionEnteredIsLeft() throws {
        let (_, _, session) = try Self.functionAddressReferences(recordingThem: false)
        #expect(session.enteredFunctionCount > 0)
        #expect(session.leftFunctionCount == session.enteredFunctionCount)
    }
}
