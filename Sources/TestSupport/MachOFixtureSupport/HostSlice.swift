import Foundation
import MachOKit
import MachOKitExtensions

/// Picks the slice of a file that this process would run.
///
/// A fat file holds one slice per architecture; tests that compare a file
/// with the same image loaded here, or that read a system binary, want the
/// slice of this process's CPU. The match is on the CPU type and on the
/// subtype without its capability bits, so an `arm64e` process gets the
/// `arm64e` slice; without an exact match any slice of the same CPU type will
/// do — an `arm64` process reads the `arm64e` slice of a system binary.
public enum HostSlice {
    /// The CPU of this process.
    public static var processCPU: CPU {
        MachOImage(ptr: _dyld_get_image_header(0)).header.cpu
    }

    /// The slice of the file at `url` for this process's CPU. A bundle
    /// (`.app`, `.framework`) is read through its executable.
    public static func machOFile(at url: URL) throws -> MachOFile {
        try machOFile(in: File.loadFromFile(url: url), path: url.path)
    }

    /// The slice of `file` for this process's CPU. A thin file is its own
    /// slice, whatever its CPU.
    public static func machOFile(in file: File, path: String = "") throws -> MachOFile {
        switch file {
        case .machO(let machOFile):
            return machOFile
        case .fat(let fatFile):
            let slices = try fatFile.machOFiles()
            guard let slice = slice(among: slices) else {
                throw HostSliceError(path: path, availableCPUs: slices.map(\.header.cpu))
            }
            return slice
        }
    }

    /// The slice among `slices` for this process's CPU, or `nil` when none
    /// has its CPU type.
    public static func slice(among slices: [MachOFile]) -> MachOFile? {
        let cpu = processCPU
        return slices.first { isExactMatch($0.header.cpu, for: cpu) }
            ?? slices.first { $0.header.cpu.typeRawValue == cpu.typeRawValue }
    }

    private static func isExactMatch(_ sliceCPU: CPU, for processCPU: CPU) -> Bool {
        let capabilityMask: UInt32 = 0xFF00_0000
        return sliceCPU.typeRawValue == processCPU.typeRawValue
            && UInt32(bitPattern: sliceCPU.subtypeRawValue) & ~capabilityMask == UInt32(bitPattern: processCPU.subtypeRawValue) & ~capabilityMask
    }
}

/// A fat file has no slice this process could run.
public struct HostSliceError: Error, CustomStringConvertible {
    public let path: String
    public let availableCPUs: [CPU]

    public var description: String {
        "no slice of \(path) for this process's CPU \(HostSlice.processCPU); the file has \(availableCPUs)"
    }
}
