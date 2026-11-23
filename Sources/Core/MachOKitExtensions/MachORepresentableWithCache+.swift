import Foundation
import MachOKit

extension MachORepresentableWithCache {
    /// Bitmask to get a valid range of vmaddr from raw vmaddr
    ///
    /// | Arch | `MACH_VM_MAX_ADDRESS` | mask |
    /// |---------|------------------|----------|
    /// | **arm** | `0x80000000` | `0x7FFFFFFF` |
    /// | **arm64 (mac or driver)** | `0x00007FFFFE000000` | `0x00007FFFFFFFFFFF` |
    /// | **arm64 (other)** | `0x0000000FC0000000` | `0x0000000FFFFFFFFF` |
    /// | **i386** | `0x00007FFFFFE00000` | `0x00007FFFFFFFFFFF` |
    ///
    /// [xnu implementation](https://github.com/apple-oss-distributions/xnu/blob/8d741a5de7ff4191bf97d57b9f54c2f6d4a15585/osfmk/mach/arm/vm_param.h#L126)
    public var vmaddrMask: UInt64? {
        // CPU_TYPE_I386 and CPU_TYPE_X86 share raw value 7. MachOKit decodes it
        // as `.x86` before 0.53 and as `.i386` from 0.53 on, where `.x86` no
        // longer exists, so match the raw value to work with both.
        if header.cpu.typeRawValue == CPUType.i386.rawValue {
            return 0xFFFF_FFFF
        }
        switch header.cpuType {
        case .x86_64:
            return 0x0000_7FFF_FFFF_FFFF
        case .arm:
            return 0x7FFF_FFFF
        case .arm64:
            if let platform = loadCommands.info(of: LoadCommand.buildVersion)?.platform {
                if [
                    .macOS,
                    .driverKit,
                ].contains(platform) || isMacOS == true {
                    return 0x0000_7FFF_FFFF_FFFF
                } else {
                    return 0x0000_000F_FFFF_FFFF
                }
            }
            return 0x0000_000F_FFFF_FFFF // FIXME: fallback
        case .arm64_32:
            return 0x7FFF_FFFF
        default:
            return nil
        }
    }

    /// Strips pointer authentication codes (PAC) and Objective-C tagged pointer bits from a raw virtual memory address.
    ///
    /// This method applies the appropriate architecture-specific bitmask to remove extra bits
    /// used for pointer authentication or tagged pointers, returning the "clean" virtual memory address.
    ///
    /// - Parameter rawVMAddr: The raw virtual memory address, potentially containing PAC or tagged pointer bits.
    /// - Returns: The virtual memory address with PAC and tagged pointer bits removed.
    public func stripPointerTags(of rawVMAddr: UInt64) -> UInt64 {
        var vmaddr = rawVMAddr
        if let vmaddrMask {
            vmaddr &= vmaddrMask // PAC & objc tagged pointer
        }
        // vmaddr &= ~3 // objc pointer union
        return vmaddr
    }

    public func stripPointerTags(of ptr: UnsafeRawPointer) throws -> UnsafeRawPointer {
        let address: UInt64 = .init(UInt(bitPattern: ptr))
        let strippedPtr: UInt64 = stripPointerTags(of: address)
        return try UnsafeRawPointer(nonZeroBitPattern: UInt(strippedPtr))
    }
}

extension MachORepresentableWithCache {
    private var isMacOS: Bool? {
        let loadCommands = loadCommands
        if let platform = loadCommands.info(of: LoadCommand.buildVersion)?.platform {
            return [
                .macOS,
                .macOSExclaveKit,
                .macOSExclaveCore,
                .macCatalyst,
            ].contains(
                platform
            )
        }
        if loadCommands.info(of: LoadCommand.versionMinMacosx) != nil {
            return true
        }

        if loadCommands.info(of: LoadCommand.versionMinIphoneos) != nil ||
            loadCommands.info(of: LoadCommand.versionMinWatchos) != nil ||
            loadCommands.info(of: LoadCommand.versionMinTvos) != nil {
            return false
        }

        if header.isInDyldCache,
           let cache = cache {
            return cache.header.platform == .macOS
        }

        return nil
    }
}

public func stripPointerTags(of rawVMAddr: UInt64) -> UInt64 {
    MachOImage.current().stripPointerTags(of: rawVMAddr)
}

extension UnsafeRawPointer {
    public func stripPointerTags() throws -> UnsafeRawPointer {
        try .init(nonZeroBitPattern: UInt(MachOKitExtensions.stripPointerTags(of: UInt64(UInt(bitPattern: self)))))
    }
}
