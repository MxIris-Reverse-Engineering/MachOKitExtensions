/// One vtable of a class: the primary table, or a secondary table that a
/// base subobject's virtual pointer points at.
///
/// ```swift
/// let store = CPlusPlusClassIndexStore.shared
/// for table in store.virtualTables(of: polymorphicClass, in: machO) {
///     for function in table.functions {
///         print(table.offsetToTop, function.slotIndex, function.name?.demangledName ?? "?")
///     }
/// }
/// ```
public struct CPlusPlusVirtualTable: Hashable, Sendable {
    /// The offset of the slot a virtual pointer points at: the first
    /// function.
    public let addressPointOffset: Int

    /// `0` for the primary table; minus the subobject's offset otherwise.
    public let offsetToTop: Int

    /// The base whose subobject uses the table; `nil` for the primary table,
    /// and for a secondary table no base explains.
    public let subobjectClassName: String?

    public let functions: [CPlusPlusVirtualFunction]

    init(addressPointOffset: Int, offsetToTop: Int, subobjectClassName: String?, functions: [CPlusPlusVirtualFunction]) {
        self.addressPointOffset = addressPointOffset
        self.offsetToTop = offsetToTop
        self.subobjectClassName = subobjectClassName
        self.functions = functions
    }

    public var isPrimary: Bool {
        offsetToTop == 0
    }
}

/// A slot of a vtable and what it reaches.
public struct CPlusPlusVirtualFunction: Hashable, Sendable, CustomStringConvertible {
    /// The slot's position after the address point, from 0.
    public let slotIndex: Int

    public let implementation: Implementation

    /// The implementation's own name: the C++ symbol at it, or the symbol a
    /// file binds the slot to. `nil` when stripped.
    public let symbolName: CPlusPlusSymbolName?

    /// The base class function the slot overrides or inherits; `nil` for a
    /// function the class introduces, or when the base cannot be read. The
    /// rules may learn more, so a slot without a base function can gain one
    /// in a later version.
    public let baseFunction: BaseFunction?

    init(slotIndex: Int, implementation: Implementation, symbolName: CPlusPlusSymbolName?, baseFunction: BaseFunction?) {
        self.slotIndex = slotIndex
        self.implementation = implementation
        self.symbolName = symbolName
        self.baseFunction = baseFunction
    }

    /// ``symbolName``, else the name of ``baseFunction``.
    public var name: CPlusPlusSymbolName? {
        symbolName ?? baseFunction?.name
    }

    public var description: String {
        "[\(slotIndex)] " + (name?.demangledName ?? "\(implementation)")
    }
}

extension CPlusPlusVirtualFunction {
    /// What a slot holds. The set is the Itanium ABI's: a function, or one
    /// of the two markers libc++abi provides.
    public enum Implementation: Hashable, Sendable {
        /// A function in this image, at this offset.
        case function(offset: Int)
        /// A function a standalone file binds from another library.
        case imported(symbolName: String, installName: String?)
        /// A function in another image: an unslid address of the same dyld
        /// shared cache, or an address of this process.
        case otherImage(address: UInt64)
        /// `__cxa_pure_virtual`.
        case pureVirtual
        /// `__cxa_deleted_virtual`.
        case deletedVirtual
    }

    /// The base class function a slot overrides or inherits.
    public struct BaseFunction: Hashable, Sendable {
        /// The nearest base whose table names the slot, or the primary base
        /// when none does.
        public let className: String

        public let name: CPlusPlusSymbolName?

        /// Whether the class keeps the base's implementation instead of
        /// overriding it.
        public let isInherited: Bool

        init(className: String, name: CPlusPlusSymbolName?, isInherited: Bool) {
            self.className = className
            self.name = name
            self.isInherited = isInherited
        }
    }
}
