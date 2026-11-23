import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import MachOFixtureSupport

/// How the fixture's linker writes its fixups.
enum SelfBindFixupFormat: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// `LC_DYLD_CHAINED_FIXUPS`.
    case chainedFixups
    /// The `LC_DYLD_INFO_ONLY` opcode streams of deployment targets before macOS 12.
    case dyldInfo

    var testDescription: String { rawValue }

    var linkerArguments: [String] {
        switch self {
        case .chainedFixups: []
        case .dyldInfo: ["-Wl,-no_fixup_chains", "-mmacosx-version-min=11.0"]
        }
    }
}

/// `resolveSelfBind(fileOffset:)` over a C dylib linked `-interposable`, which
/// binds the pointer to its own exported array to the image itself
/// (`<this-image>/_selfBindTarget + 0x4` in `dyld_info -fixups`) in both
/// fixup formats.
@Suite("Binds an image satisfies from itself")
struct SelfBindResolutionTests {
    @Test("A bind to the image's own export resolves to the export plus the addend", arguments: SelfBindFixupFormat.allCases)
    func selfBindResolvesToTheExportPlusTheAddend(format: SelfBindFixupFormat) throws {
        let machO = try SelfBindLibrary.machOFile(format: format)
        let targetOffset = try SelfBindLibrary.symbolValue(of: "_selfBindTarget", in: machO)
        let slotOffset = try SelfBindLibrary.slotFileOffset(of: "_selfBindPointer", in: machO)
        // `&selfBindTarget[1]`: one `int` past the export.
        #expect(machO.resolveSelfBind(fileOffset: slotOffset) == targetOffset + 4)
    }

    @Test("A bind into another image is not resolved here", arguments: SelfBindFixupFormat.allCases)
    func bindIntoAnotherImageIsNotResolved(format: SelfBindFixupFormat) throws {
        let machO = try SelfBindLibrary.machOFile(format: format)
        let slotOffset = try SelfBindLibrary.slotFileOffset(of: "_externalPointer", in: machO)
        try #require(machO.resolveBind(fileOffset: slotOffset) == "_malloc")
        #expect(machO.resolveSelfBind(fileOffset: slotOffset) == nil)
    }

    @Test("A rebase is not a self-bind", arguments: SelfBindFixupFormat.allCases)
    func rebaseIsNotASelfBind(format: SelfBindFixupFormat) throws {
        let machO = try SelfBindLibrary.machOFile(format: format)
        let slotOffset = try SelfBindLibrary.slotFileOffset(of: "_hiddenPointer", in: machO)
        try #require(!machO.isBind(fileOffset: slotOffset))
        #expect(machO.resolveSelfBind(fileOffset: slotOffset) == nil)
    }

    @Test("Every bind slot is still named", arguments: SelfBindFixupFormat.allCases)
    func everyBindSlotIsNamed(format: SelfBindFixupFormat) throws {
        let machO = try SelfBindLibrary.machOFile(format: format)
        let selfBindSlotOffset = try SelfBindLibrary.slotFileOffset(of: "_selfBindPointer", in: machO)
        #expect(machO.resolveBind(fileOffset: selfBindSlotOffset) == "_selfBindTarget")
    }
}

enum SelfBindLibrary {
    static let source = """
    #include <stdlib.h>

    // Exported, so `-interposable` binds every pointer to it to the image itself.
    __attribute__((visibility("default"))) int selfBindTarget[4] = {1, 2, 3, 4};
    __attribute__((visibility("default"))) int *selfBindPointer = &selfBindTarget[1];
    __attribute__((visibility("default"))) void *externalPointer = (void *)malloc;
    // Not exported: nothing can interpose it, so the pointer stays a rebase.
    static int hiddenTarget = 5;
    __attribute__((visibility("default"))) int *hiddenPointer = &hiddenTarget;
    """

    /// A fresh `MachOFile` per call, so no test sees another's caches. The
    /// library is compiled once per process for each format.
    static func machOFile(format: SelfBindFixupFormat) throws -> MachOFile {
        let libraryURL = try FixtureCompiler.shared.dynamicLibrary(
            named: "SelfBind",
            language: .c,
            source: source,
            arguments: ["-Wl,-interposable"] + format.linkerArguments
        )
        return try HostSlice.machOFile(at: libraryURL)
    }

    /// The symbol's `n_value` — its offset from the load address, in a dylib
    /// whose `__TEXT` starts at zero — read from the symbol table, not from the
    /// export trie `resolveSelfBind(fileOffset:)` consults.
    static func symbolValue(of symbolName: String, in machO: MachOFile) throws -> UInt64 {
        let symbol = try #require(machO.symbols.first { $0.name == symbolName }, "no \(symbolName) in the symbol table")
        return UInt64(symbol.offset)
    }

    /// Where the pointer variable `symbolName` sits in the file.
    static func slotFileOffset(of symbolName: String, in machO: MachOFile) throws -> Int {
        let address = try symbolValue(of: symbolName, in: machO)
        return try #require(machO.fileOffset(of: address).map { Int($0) }, "\(symbolName) is not in the file")
    }
}
