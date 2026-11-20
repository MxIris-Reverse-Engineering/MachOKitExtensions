import MachOKit
import MachOKitExtensions

// The address mask comes from `MachOImage.current()`, which MachOKit only
// declares where dyld is, and a process off Darwin has no Mach-O images of
// its own to read.
#if canImport(Darwin)

/// A reading context for direct in-process memory access.
///
/// `InProcessContext` provides zero-copy memory access using `UnsafeRawPointer`
/// as addresses. This is the most efficient way to read data when working with
/// memory that's already loaded in the current process.
///
/// ## Usage
///
/// ```swift
/// let ptr: UnsafeRawPointer = ...
/// let context = InProcessContext.shared
///
/// // Read data directly from memory
/// let descriptor: ProtocolDescriptor = try context.readWrapperElement(at: ptr)
/// ```
///
/// ## Address Type
///
/// `InProcessContext` uses `UnsafeRawPointer` as its address type, allowing
/// direct memory operations without any copying or offset calculations.
///
/// ## Thread Safety
///
/// `InProcessContext` is stateless and can be safely shared across threads.
/// The `shared` singleton is recommended for most use cases.
///
/// Note: This type is marked as `@unchecked Sendable` because `UnsafeRawPointer`
/// is not `Sendable`. Thread safety must be ensured by the caller when using
/// addresses across thread boundaries.
public struct InProcessContext: ReadingContext, Sendable {
    /// The runtime target for in-process access.
    public typealias Runtime = InProcess

    /// Addresses are raw memory pointers.
    public typealias Address = UnsafeRawPointer

    /// A shared singleton instance.
    ///
    /// Since `InProcessContext` is stateless, using a shared instance
    /// avoids unnecessary allocations.
    public static let shared = InProcessContext()

    /// Creates a new in-process reading context.
    public init() {}

    /// The bits of an address in this process that are the address itself,
    /// without pointer authentication or tag bits.
    ///
    /// Every image in a process shares one architecture and platform, so the
    /// mask is computed once. `UnsafeRawPointer.stripPointerTags()` computes
    /// it again on every call — it looks up the current image and walks its
    /// load commands — which is a cost paid once per read here.
    ///
    /// Which bits these are depends on the platform: a Mac's user addresses
    /// fit in 47 bits, an iPhone's in 36, and an arm64e signature starts
    /// right above them. Code that reads pointers out of this process's
    /// memory strips them with this mask rather than a constant of its own.
    public static let addressMask = UInt(truncatingIfNeeded: MachOImage.current().vmaddrMask ?? .max)

    /// `address` without its tag bits; throws for an address that is only tag
    /// bits, the way a null pointer throws.
    private func strippingTags(from address: Address) throws -> Address {
        try UnsafeRawPointer(nonZeroBitPattern: UInt(bitPattern: address) & Self.addressMask)
    }

    public func readElement<Element>(at pointer: Address) throws -> Element {
        try strippingTags(from: pointer).readElement()
    }

    public func readElements<Element>(at pointer: Address, numberOfElements: Int) throws -> [Element] {
        try strippingTags(from: pointer).readElements(numberOfElements: numberOfElements)
    }

    public func readWrapperElement<Element: LocatableLayoutWrapper>(at pointer: Address) throws -> Element {
        try strippingTags(from: pointer).readWrapperElement()
    }

    public func readWrapperElements<Element>(at pointer: Address, numberOfElements: Int) throws -> [Element] where Element: LocatableLayoutWrapper {
        try strippingTags(from: pointer).readWrapperElements(numberOfElements: numberOfElements)
    }

    public func readString(at pointer: Address) throws -> String {
        try strippingTags(from: pointer).readString()
    }

    /// Advances from the untagged address: a tagged base plus a delta is not
    /// an address the process can use, signed or not.
    public func advanceAddress(_ address: Address, by delta: Int) -> Address {
        ((try? strippingTags(from: address)) ?? address).advanced(by: delta)
    }

    public func advanceAddress<Element>(_ address: Address, of type: Element.Type) -> Address {
        advanceAddress(address, by: MemoryLayout<Element>.size)
    }

    public func addressFromOffset(_ offset: Int) throws -> Address {
        // For InProcess context, the offset is a pointer bit pattern
        try UnsafeRawPointer(nonZeroBitPattern: offset)
    }

    public func addressFromVirtualAddress(_ virtualAddress: UInt64) throws -> Address {
        // For InProcess context, the virtual address is a pointer bit pattern.
        try UnsafeRawPointer(nonZeroBitPattern: UInt(truncatingIfNeeded: virtualAddress) & Self.addressMask)
    }

    public func offsetFromAddress(_ address: Address) throws -> Int {
        Int(bitPattern: address)
    }
}

// MARK: - Runtime Pointer Support

extension InProcessContext {
    /// In-process addresses are already runtime pointers, so this returns
    /// the address unchanged.
    public func runtimePointer(at address: UnsafeRawPointer) throws -> UnsafeRawPointer? {
        address
    }

    /// Addresses are absolute in this process, so memo entries are
    /// process-wide.
    public var cacheScope: ReadingContextCacheScope {
        .process
    }
}

extension ReadingContext where Self == InProcessContext {
    public static var inProcess: Self { .shared }
}

#endif
