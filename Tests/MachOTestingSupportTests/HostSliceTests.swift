import Foundation
import Testing
import MachOKit
import MachOFixtureSupport

/// `HostSlice` reads the slice this process runs: the same CPU type and, when
/// the file has it, the same subtype.
@Suite
struct HostSliceTests {
    @Test("A fat file gives the slice of this process's subtype over another of the same CPU type")
    func hostSliceMatchesTheProcessSubtype() throws {
        let fat = try FixtureCompiler.shared.dynamicLibrary(
            named: "HostSliceFat",
            language: .c,
            source: "int hostSliceFat(void) { return 1; }",
            arguments: ["-arch", "arm64", "-arch", "arm64e", "-arch", "x86_64"]
        )
        guard case .fat(let fatFile) = try loadFromFile(url: fat) else {
            Issue.record("\(fat.path) is not a fat file")
            return
        }
        #expect(try fatFile.machOFiles().count == 3)

        let processCPU = HostSlice.processCPU
        let slice = try HostSlice.machOFile(at: fat)
        #expect(slice.header.cpu.typeRawValue == processCPU.typeRawValue)
        let capabilityMask: UInt32 = 0xFF00_0000
        #expect(UInt32(bitPattern: slice.header.cpu.subtypeRawValue) & ~capabilityMask == UInt32(bitPattern: processCPU.subtypeRawValue) & ~capabilityMask)
    }

    @Test("A thin file is its own slice")
    func thinFileIsItsOwnSlice() throws {
        let thin = try FixtureCompiler.shared.dynamicLibrary(
            named: "HostSliceThin",
            language: .c,
            source: "int hostSliceThin(void) { return 1; }"
        )
        let slice = try HostSlice.machOFile(at: thin)
        #expect(slice.exportedSymbols.contains { $0.name == "_hostSliceThin" })
    }

    @Test("A bundle is read through its executable")
    func bundleIsReadThroughItsExecutable() throws {
        let finder = try HostSlice.machOFile(at: MachOFileName.Finder.url)
        #expect(finder.header.fileType == .execute)
    }
}
