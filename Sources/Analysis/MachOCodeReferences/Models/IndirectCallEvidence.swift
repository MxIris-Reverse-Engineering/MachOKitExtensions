/// Evidence for where an indirect call may go: the language-free facts the
/// scan reads off the call site. Which kind of table a load came from (a
/// class's virtual table, a witness table) is a language's knowledge, so a
/// language layer adds it if it ever classifies one.
public struct IndirectCallEvidence: Hashable, Sendable {
    /// The displacement of the load that produced the callee, when it came
    /// from memory.
    public let tableOffset: Int64?
    /// The 16-bit arm64e discriminator constant, when there is one.
    public let pointerAuthenticationConstant: UInt16?
    /// Whether the constant was blended into an address (`movk xN, #imm,
    /// lsl #48`) or used alone (`mov x17, #imm`).
    public let isAddressBlended: Bool

    public init(tableOffset: Int64?, pointerAuthenticationConstant: UInt16?, isAddressBlended: Bool) {
        self.tableOffset = tableOffset
        self.pointerAuthenticationConstant = pointerAuthenticationConstant
        self.isAddressBlended = isAddressBlended
    }
}
