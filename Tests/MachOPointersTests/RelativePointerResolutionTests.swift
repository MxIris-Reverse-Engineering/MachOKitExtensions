import Foundation
import Testing
import MachOReading
import MachOResolving
import MachOPointers

/// Relative pointers read in this process's memory, laid out by hand: the
/// pointer types are what MachOSwiftSection's ABI model reads its descriptors
/// through, and this package had no test of its own for them.
///
/// Layout of the 64-byte buffer every test reads (offsets from its start):
///
/// | Offset | Contents |
/// |---|---|
/// | 0 | where the relative pointer under test sits |
/// | 16 | `directTarget` (`UInt32`) |
/// | 24 | an absolute pointer to offset 40 (the indirect slot) |
/// | 40 | `indirectTarget` (`UInt32`) |
@Suite
struct RelativePointerResolutionTests {
    private static let directTarget: UInt32 = 0xCAFE_F00D
    private static let indirectTarget: UInt32 = 0x1234_5678

    private static let directTargetOffset: Int32 = 16
    private static let indirectSlotOffset: Int32 = 24
    private static let indirectTargetOffset = 40

    /// Flag bits stored in the low bits of a relative offset, as the Swift
    /// runtime packs a descriptor's flags next to a 4-byte aligned target.
    private enum PackedFlag: UInt8 {
        case none = 0
        case first = 1
        case second = 2
        case third = 3
    }

    /// Runs `body` with the address of the pointer field (offset 0) of a
    /// freshly laid out buffer.
    private func withLaidOutBuffer<Result>(_ body: (UnsafeRawPointer) throws -> Result) rethrows -> Result {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        buffer.storeBytes(of: Self.directTarget, toByteOffset: Int(Self.directTargetOffset), as: UInt32.self)
        let indirectTargetAddress = UInt64(UInt(bitPattern: buffer + Self.indirectTargetOffset))
        buffer.storeBytes(of: indirectTargetAddress, toByteOffset: Int(Self.indirectSlotOffset), as: UInt64.self)
        buffer.storeBytes(of: Self.indirectTarget, toByteOffset: Self.indirectTargetOffset, as: UInt32.self)
        return try body(UnsafeRawPointer(buffer))
    }

    @Test func relativeDirectPointerResolvesToTargetInProcessMemory() throws {
        try withLaidOutBuffer { (pointerFieldAddress: UnsafeRawPointer) throws in
            let pointer = RelativeDirectPointer<UInt32>(relativeOffset: Self.directTargetOffset)
            #expect(try pointer.resolve(at: pointerFieldAddress, in: InProcessContext.shared) == Self.directTarget)
            #expect(pointer.resolveDirectOffset(from: 100) == 100 + Int(Self.directTargetOffset))
            #expect(!pointer.isNull)
        }
    }

    @Test func relativeIndirectPointerReadsTargetThroughSlot() throws {
        try withLaidOutBuffer { (pointerFieldAddress: UnsafeRawPointer) throws in
            let indirect = RelativeIndirectablePointer<UInt32, Pointer<UInt32>>(relativeOffsetPlusIndirect: Self.indirectSlotOffset | 1)
            #expect(indirect.isIndirect)
            #expect(indirect.relativeOffset == Self.indirectSlotOffset)
            #expect(try indirect.resolve(at: pointerFieldAddress, in: InProcessContext.shared) == Self.indirectTarget)

            // The same type with the low bit clear points at its target directly.
            let direct = RelativeIndirectablePointer<UInt32, Pointer<UInt32>>(relativeOffsetPlusIndirect: Self.directTargetOffset)
            #expect(!direct.isIndirect)
            #expect(try direct.resolve(at: pointerFieldAddress, in: InProcessContext.shared) == Self.directTarget)
        }
    }

    @Test func relativePointerIntPairSeparatesFlagBits() throws {
        try withLaidOutBuffer { (pointerFieldAddress: UnsafeRawPointer) throws in
            let pointer = RelativeDirectPointerIntPair<UInt32, PackedFlag>(relativeOffsetPlusInt: Self.directTargetOffset | 2)
            #expect(pointer.relativeOffset == Self.directTargetOffset)
            #expect(pointer.value == .second)
            #expect(try pointer.resolve(at: pointerFieldAddress, in: InProcessContext.shared) == Self.directTarget)
        }
    }
}
