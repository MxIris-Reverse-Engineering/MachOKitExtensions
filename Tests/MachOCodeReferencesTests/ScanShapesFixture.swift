import Foundation
import MachOKit
import MachOFixtureSupport
@_spi(Internals) import MachOCodeReferences

/// A library written in assembly, so that each function is exactly the
/// instruction sequence a test pins: the scanner reads machine code, and a
/// compiler would choose its own. Assembled and linked once per process for
/// the host — arm64 only.
///
/// - `takesSlotAddress` builds the address of `malloc`'s GOT slot and hands
///   it on in `x2`, as Swift code hands a class's GOT slot to the helper that
///   makes its metadata (ControlCenter 26.7 `0x1006455c8`).
/// - `loadsThroughSlotAddress` builds the slot's address and loads through
///   it; `loadsThroughCopiedSlotAddress` copies the address to another
///   register first. `loadsSlot` is the usual `adrp` / `ldr` pair.
/// - `offsetAtMergePoint` reads an offset variable through an `adrp` / `add`
///   address at an instruction two paths reach, the shape of Finder 26.5.2's
///   `-[TTaskErrorOrConflictViewController setResolutionsForKind:]`;
///   `offsetStraight` reads it with no branch before.
/// - `takesFunctionAddress` builds `offsetStraight`'s address with `adrp` /
///   `add`, `takesFunctionAddressWithAdr` with `adr`, and
///   `takesInteriorAddress` builds an address inside `offsetStraight`.
enum ScanShapesFixture {
    static let isSupported: Bool = {
        #if os(macOS) && arch(arm64)
        true
        #else
        false
        #endif
    }()

    static let assembly = """
        .section __TEXT,__text,regular,pure_instructions

        .globl _takesSlotAddress
        .p2align 2
    _takesSlotAddress:
        adrp x2, L_malloc$non_lazy_ptr@PAGE
        add x2, x2, L_malloc$non_lazy_ptr@PAGEOFF
        mov x0, #0
        ret

        .globl _loadsThroughSlotAddress
        .p2align 2
    _loadsThroughSlotAddress:
        adrp x8, L_malloc$non_lazy_ptr@PAGE
        add x8, x8, L_malloc$non_lazy_ptr@PAGEOFF
        ldr x0, [x8]
        ret

        .globl _loadsThroughCopiedSlotAddress
        .p2align 2
    _loadsThroughCopiedSlotAddress:
        adrp x8, L_malloc$non_lazy_ptr@PAGE
        add x8, x8, L_malloc$non_lazy_ptr@PAGEOFF
        mov x9, x8
        ldr x0, [x9]
        ret

        .globl _loadsSlot
        .p2align 2
    _loadsSlot:
        adrp x8, L_malloc$non_lazy_ptr@PAGE
        ldr x0, [x8, L_malloc$non_lazy_ptr@PAGEOFF]
        ret

        .globl _offsetAtMergePoint
        .p2align 2
    _offsetAtMergePoint:
        cmp w1, #1
        b.ne 1f
        mov w8, #4
        b 2f
    1:
        mov w8, #7
    2:
        adrp x9, _offsetVariable@PAGE
        add x9, x9, _offsetVariable@PAGEOFF
        ldrsw x9, [x9]
        str w8, [x0, x9]
        ret

        .globl _offsetStraight
        .p2align 2
    _offsetStraight:
    Lstraight:
        mov w8, #7
    Linterior:
        adrp x9, _offsetVariable@PAGE
        add x9, x9, _offsetVariable@PAGEOFF
        ldrsw x9, [x9]
        str w8, [x0, x9]
        ret

        .globl _takesFunctionAddress
        .p2align 2
    _takesFunctionAddress:
        adrp x0, _offsetStraight@PAGE
        add x0, x0, _offsetStraight@PAGEOFF
        ret

        .globl _takesFunctionAddressWithAdr
        .p2align 2
    _takesFunctionAddressWithAdr:
        adr x0, Lstraight
        ret

        .globl _takesInteriorAddress
        .p2align 2
    _takesInteriorAddress:
        adr x0, Linterior
        ret

        .section __DATA,__objc_ivar
        .p2align 2
        .globl _offsetVariable
    _offsetVariable:
        .long 40

        .section __DATA_CONST,__got,non_lazy_symbol_pointers
        .p2align 3
    L_malloc$non_lazy_ptr:
        .indirect_symbol _malloc
        .quad 0

    """

    /// A fresh `MachOFile` of the library per call, so that no test sees
    /// another's caches.
    static func machOFile() throws -> MachOFile {
        let libraryURL = try FixtureCompiler.shared.dynamicLibrary(
            named: "ScanShapes",
            language: .c,
            sourceFiles: [FixtureSourceFile(name: "ScanShapes.s", contents: assembly)]
        )
        return try HostSlice.machOFile(at: libraryURL)
    }

    /// The unslid address of the symbol `name`: the library is linked at 0
    /// and is the only file of its image set, so it is not slid.
    static func address(ofSymbolNamed name: String, in machO: MachOFile) throws -> UInt64 {
        guard let symbol = machO.symbols.first(where: { $0.name == name }) else {
            throw FixtureLookupError(description: "no \(name) in the symbol table")
        }
        return UInt64(symbol.offset)
    }

    /// The unslid addresses of the function `name`: from its symbol to the
    /// next function's, or to the end of `__text`.
    static func range(ofFunctionNamed name: String, in machO: MachOFile) throws -> Range<UInt64> {
        let text = try range(ofSection: "__text", inSegment: "__TEXT", of: machO)
        let start = try address(ofSymbolNamed: name, in: machO)
        let laterStarts = machO.symbols.map { UInt64($0.offset) }.filter { $0 > start && text.contains($0) }
        return start ..< (laterStarts.min() ?? text.upperBound)
    }

    /// The unslid address range of the section `sectionName` of segment
    /// `segmentName`.
    static func range(ofSection sectionName: String, inSegment segmentName: String, of machO: MachOFile) throws -> Range<UInt64> {
        guard let section = machO.sections64.first(where: { $0.segmentName == segmentName && $0.sectionName == sectionName }) else {
            throw FixtureLookupError(description: "no \(segmentName),\(sectionName)")
        }
        return UInt64(section.address) ..< UInt64(section.address + section.size)
    }

    /// Scans every function of the library with `session` and records into
    /// `recording`.
    static func scan(
        _ machO: MachOFile,
        session: some CodeReferenceRecognitionSession,
        recording: some CodeReferenceRecording,
        recordsFunctionAddressReferences: Bool
    ) {
        let images = CodeImageSet.files(
            [machO],
            rules: RuntimeLibraryRules(isRuntimeLibrary: { _ in false }, isRuntimeHelperName: { _ in false }),
            visitingRuntimeLibrarySymbols: { _, _ in }
        )
        let table = images.transientFunctionTable(ofImageAt: 0)
        var scanner = ReferenceScanner(
            images: images,
            table: table,
            sessions: [session],
            recording: recording,
            recordsImportedSymbolReferences: true,
            recordsFunctionAddressReferences: recordsFunctionAddressReferences
        )
        for index in table.starts.indices {
            scanner.scanFunction(at: index)
        }
    }
}

struct FixtureLookupError: Error, CustomStringConvertible {
    let description: String
}

/// A session that recognizes nothing and watches the slots of the ranges it
/// is given — what the Objective-C layer does with `__objc_ivar` — counting
/// the functions the scan enters and leaves.
final class WatchingSession: CodeReferenceRecognitionSession {
    let watchedSlotRanges: [Range<UInt64>]
    private(set) var watchedLoads: [(slot: UInt64, instructionAddress: UInt64)] = []
    private(set) var enteredFunctionCount = 0
    private(set) var leftFunctionCount = 0

    init(watchedSlotRanges: [Range<UInt64>] = []) {
        self.watchedSlotRanges = watchedSlotRanges
    }

    var referenceSlotRanges: [Range<UInt64>] { [] }
    var looksForAddressReferences: Bool { false }
    func enterFunction(at functionIndex: Int, registers: RegisterFile) { enteredFunctionCount += 1 }
    func claimCallTarget(at target: UInt64) -> CallTargetClaim? { nil }
    func role(of target: ResolvedCallTarget) -> CalleeRole? { nil }
    func recordCallStandIn(_ call: ScannedCall, registers: RegisterFile) -> Bool { false }
    func noteCallMade(_ call: ScannedCall, registers: RegisterFile) -> UInt32 { 0 }
    func recordAddressReference(toRuntimeAddress address: UInt, isCode: Bool, at site: ScanSite) -> Bool { false }
    func recordSlotReference(holding value: UInt, at site: ScanSite) -> Bool { false }

    func noteWatchedSlotLoad(from slot: UInt64, at site: ScanSite) {
        watchedLoads.append((slot, site.instructionAddress))
    }

    func leaveFunction() {
        leftFunctionCount += 1
    }
}

/// Keeps the references the core records itself.
final class CoreRecording: CodeReferenceRecording {
    private(set) var importedSymbolReferences: [(name: String, instructionAddress: UInt64, route: CodeReferenceRoute)] = []
    private(set) var functionAddressReferences: [(function: CodeLocation, instructionAddress: UInt64, kind: CodeReferenceKind, route: CodeReferenceRoute)] = []

    func recordCall(to target: ResolvedCallTarget, targetAddress: UInt64, at site: ScanSite, isRuntimeHelperCall: Bool) {}
    func recordIndirectCall(_ evidence: IndirectCallEvidence, at site: ScanSite) {}
    func recordString(_ string: StringLiteralReference, at site: ScanSite) {}

    func recordImportedSymbolReference(named name: String, at site: ScanSite) {
        importedSymbolReferences.append((name, site.instructionAddress, site.route))
    }

    func recordFunctionAddressReference(to function: CodeLocation, at site: ScanSite) {
        functionAddressReferences.append((function, site.instructionAddress, site.kind, site.route))
    }

    /// The imported symbol references made by instructions in `range`.
    func importedSymbolReferences(madeIn range: Range<UInt64>) -> [(name: String, instructionAddress: UInt64, route: CodeReferenceRoute)] {
        importedSymbolReferences.filter { range.contains($0.instructionAddress) }
    }
}
