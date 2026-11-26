import Foundation
import Testing
@_spi(Internals) import MachOCodeReferences

/// The image set of the running process, built once: the whole dyld shared
/// cache is mapped into every process, so its images are read whether or not
/// anything loaded them. `nil` off arm64 Darwin.
enum InProcessImageSet {
    /// No language layer is present, so no library counts as a runtime
    /// library and no name as a runtime helper.
    static let imageSet: CodeImageSet? = CodeImageSet.inProcess(
        rules: RuntimeLibraryRules(isRuntimeLibrary: { _ in false }, isRuntimeHelperName: { _ in false }),
        visitingRuntimeLibrarySymbols: { _, _ in }
    )
}

/// The core scans with any recognizer and knows no language: here no
/// language layer is loaded at all, only a session the test defines
/// (MachOSwiftSection proposal `move-cross-reference-layers`).
@Suite(.enabled(if: InProcessImageSet.imageSet != nil, "needs an arm64 process with a dyld shared cache"))
struct CoreOnlyScanTests {
    /// A session no library knows: it stands in for every call into one
    /// image.
    private final class CallsIntoImageSession: CodeReferenceRecognitionSession {
        let recognizedImageIndex: Int
        let recording: Recording

        init(recognizedImageIndex: Int, recording: Recording) {
            self.recognizedImageIndex = recognizedImageIndex
            self.recording = recording
        }

        var referenceSlotRanges: [Range<UInt64>] { [] }
        var watchedSlotRanges: [Range<UInt64>] { [] }
        var looksForAddressReferences: Bool { false }
        func enterFunction(at functionIndex: Int, registers: RegisterFile) {}
        func claimCallTarget(at target: UInt64) -> CallTargetClaim? { nil }

        func role(of target: ResolvedCallTarget) -> CalleeRole? {
            guard case .function(let location) = target, location.imageIndex == recognizedImageIndex else { return nil }
            return CalleeRole(code: 1, mayStandIn: true, notesCallMade: false)
        }

        func recordCallStandIn(_ call: ScannedCall, registers: RegisterFile) -> Bool {
            recording.stoodInCallCount += 1
            return true
        }

        func noteCallMade(_ call: ScannedCall, registers: RegisterFile) -> UInt32 { 0 }
        func recordAddressReference(toRuntimeAddress address: UInt, isCode: Bool, at site: ScanSite) -> Bool { false }
        func recordSlotReference(holding value: UInt, at site: ScanSite) -> Bool { false }
        func noteWatchedSlotLoad(from slot: UInt64, at site: ScanSite) {}
    }

    private final class Recording: CodeReferenceRecording {
        let recognizedImageIndex: Int
        var stoodInCallCount = 0
        var plainCallsIntoTheImage = 0
        var plainCallCount = 0

        init(recognizedImageIndex: Int) {
            self.recognizedImageIndex = recognizedImageIndex
        }

        func recordCall(to target: ResolvedCallTarget, targetAddress: UInt64, at site: ScanSite, isRuntimeHelperCall: Bool) {
            plainCallCount += 1
            if case .function(let location) = target, location.imageIndex == recognizedImageIndex { plainCallsIntoTheImage += 1 }
        }

        func recordIndirectCall(_ evidence: IndirectCallEvidence, at site: ScanSite) {}
        func recordString(_ string: StringLiteralReference, at site: ScanSite) {}
        func recordImportedSymbolReference(named name: String, at site: ScanSite) {}
        func recordFunctionAddressReference(to function: CodeLocation, at site: ScanSite) {}
    }

    @Test func theCoreScansWithOnlyARecognizerFromTests() throws {
        let images = try #require(InProcessImageSet.imageSet)
        let foundation = try #require(images.imagePaths.firstIndex { $0.hasSuffix("/Foundation.framework/Versions/C/Foundation") })
        let libobjc = try #require(images.imagePaths.firstIndex { $0.hasSuffix("/libobjc.A.dylib") })
        let recording = Recording(recognizedImageIndex: libobjc)
        let table = images.transientFunctionTable(ofImageAt: foundation)
        var scanner = ReferenceScanner(
            images: images,
            table: table,
            sessions: [CallsIntoImageSession(recognizedImageIndex: libobjc, recording: recording)],
            recording: recording
        )
        for index in table.starts.indices {
            scanner.scanFunction(at: index)
        }
        // Foundation calls libobjc all the time — `objc_msgSend` among it —
        // and every such call went to the session instead of the core.
        #expect(recording.stoodInCallCount > 10000)
        #expect(recording.plainCallsIntoTheImage == 0)
        #expect(recording.plainCallCount > 10000)
    }

    /// Indirect-call evidence carries only what the call site shows; which
    /// kind of table a load came from is a language's knowledge.
    @Test func indirectCallEvidenceCarriesNoTable() {
        let evidence = IndirectCallEvidence(tableOffset: 0x18, pointerAuthenticationConstant: 0x1A2B, isAddressBlended: true)
        let labels = Mirror(reflecting: evidence).children.compactMap(\.label)
        #expect(labels == ["tableOffset", "pointerAuthenticationConstant", "isAddressBlended"])
    }
}
