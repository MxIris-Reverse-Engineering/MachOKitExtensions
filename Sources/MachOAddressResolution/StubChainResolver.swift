import Foundation
import MachOKit
import MachOReading
@_spi(Internals) import ARM64InstructionDecoding

/// Reads the trampolines a call passes through on its way to a function,
/// from a Mach-O file: an image's own stubs (`adrp` / `ldr` / `br`, or ld64's
/// `nop` / `ldr x16, <slot>` / `br x16`), the four-instruction GOT stubs and
/// the stub islands a shared cache keeps between images, and macOS / iOS
/// 27's cache-shared selector stubs. The shapes are `ARM64Trampoline`'s; this
/// reads the bytes and walks the chain.
///
/// Shared by the accessor-thunk reader and the cross-reference analysis
/// (evolution proposal `offline-cross-references-and-symbolication`).
@_spi(Internals) public struct StubChainResolver {
    /// One step of a chain.
    @_spi(Internals) public enum Hop: Hashable, Sendable {
        /// A stub that loads its target from the slot at this unslid address.
        case slotLoad(trampolineAddress: UInt64, slotAddress: UInt64)
        /// A stub island that computes its target outright.
        case island(trampolineAddress: UInt64, target: UInt64)
        /// A stub that puts a constant in a register before it branches on —
        /// a cache-shared selector stub's `x1`, the selector string.
        case registerSettingStub(trampolineAddress: UInt64, register: Int, value: UInt64, target: UInt64)

        /// Where this step's trampoline sits.
        @_spi(Internals) public var trampolineAddress: UInt64 {
            switch self {
            case .slotLoad(let trampolineAddress, _), .island(let trampolineAddress, _), .registerSettingStub(let trampolineAddress, _, _, _):
                return trampolineAddress
            }
        }
    }

    /// How many trampolines are followed from one call before giving up: one
    /// is the norm, a hop per subcache crossed the worst case seen described.
    @_spi(Internals) public static let maximumHops = 8

    @_spi(Internals) public let machO: MachOFile
    @_spi(Internals) public let addressSpace: ImageAddressSpace

    @_spi(Internals) public init(machO: MachOFile, addressSpace: ImageAddressSpace) {
        self.machO = machO
        self.addressSpace = addressSpace
    }

    /// The trampoline at the unslid `address`, read from the file; `nil`
    /// when the code there has no trampoline's shape.
    @_spi(Internals) public func trampoline(at address: UInt64) -> ARM64Trampoline? {
        let byteCount = ARM64Trampoline.maximumInstructionCount * 4
        guard let offset = addressSpace.offset(forAddress: address),
              let bytes: [UInt8] = try? machO.readElements(offset: offset, numberOfElements: byteCount),
              bytes.count == byteCount
        else { return nil }
        return bytes.withUnsafeBytes { buffer in
            ARM64Trampoline(readingAt: buffer.baseAddress!, address: address)
        }
    }

    /// The step the trampoline at `address` takes, if one is there.
    @_spi(Internals) public func hop(at address: UInt64) -> Hop? {
        switch trampoline(at: address) {
        case .slotLoad(let slotAddress)?:
            return .slotLoad(trampolineAddress: address, slotAddress: slotAddress)
        case .computed(let target)?:
            return .island(trampolineAddress: address, target: target)
        case .selectorStub(let selectorAddress, let target)?:
            return .registerSettingStub(trampolineAddress: address, register: 1, value: selectorAddress, target: target)
        case nil:
            return nil
        }
    }

    /// Every trampoline from `address` on, in order, until `isDestination`
    /// says an address is where the call ends, a slot is reached — whose
    /// content `followSlot` decodes, or not — or `maximumHops` are taken.
    /// The last element of `hops` names where the chain stopped.
    @_spi(Internals) public func hops(
        from address: UInt64,
        isDestination: (UInt64) -> Bool,
        followSlot: (UInt64) -> UInt64?
    ) -> [Hop] {
        var hops: [Hop] = []
        var current = address
        while hops.count < Self.maximumHops, !isDestination(current), let hop = hop(at: current) {
            hops.append(hop)
            switch hop {
            case .slotLoad(_, let slotAddress):
                guard let target = followSlot(slotAddress) else { return hops }
                current = target
            case .island(_, let target):
                current = target
            case .registerSettingStub:
                // Where a selector stub branches is a copy of `objc_msgSend`;
                // the constant is what tells the call.
                return hops
            }
        }
        return hops
    }
}
