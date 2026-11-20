/// What identifies a slot's implementation, so that a derived class's slot
/// can be compared with its base's across images.
struct ImplementationIdentity: Hashable, Sendable {
    enum Location: Hashable, Sendable {
        /// A function of a standalone file, by the file's path and offset.
        case local(imagePath: String, offset: Int)
        /// A function at an unslid address of a dyld shared cache, or at an
        /// address of this process.
        case absolute(UInt64)
        case pureVirtual
        case deletedVirtual
    }

    let location: Location?

    /// The implementation's mangled name, when it has one.
    let mangledName: String?

    /// Whether both identify the same implementation: the same place, or
    /// failing that the same name.
    func isSame(as other: ImplementationIdentity) -> Bool {
        if let location, let otherLocation = other.location, location == otherLocation {
            return true
        }
        if let mangledName, let otherMangledName = other.mangledName {
            return mangledName == otherMangledName
        }
        return false
    }
}

/// Names a slot after the base class function it overrides or inherits.
///
/// Slot `i` of a class's primary vtable is the function slot `i` of its
/// primary base's primary vtable declares, for every `i` the base's table
/// has; a secondary vtable's slots follow the primary table of the base
/// whose subobject uses it. The name comes from the nearest base, walking up
/// the primary bases, whose slot has one.
///
/// How classes, their primary bases and their slots are found is the
/// caller's: the store reads them from images, tests make them up.
struct VirtualFunctionNaming<ClassReference: Hashable> {
    struct Slot {
        let name: CPlusPlusSymbolName?
        let identity: ImplementationIdentity
    }

    /// Bases are followed at most this deep, in case data loops.
    static var maximumDepth: Int {
        64
    }

    let primaryBase: (ClassReference) -> ClassReference?
    let className: (ClassReference) -> String
    /// The slots of a class's primary vtable; `nil` when the class or its
    /// table cannot be read.
    let primarySlots: (ClassReference) -> [Slot]?

    /// The base function of slot `slotIndex`, which holds `identity`, when
    /// the slots follow `base`'s primary vtable; `nil` when that table is
    /// shorter, or cannot be read.
    func baseFunction(forSlotAt slotIndex: Int, implementedBy identity: ImplementationIdentity, startingAt base: ClassReference) -> CPlusPlusVirtualFunction.BaseFunction? {
        guard let baseSlots = primarySlots(base), slotIndex < baseSlots.count else { return nil }
        let isInherited = baseSlots[slotIndex].identity.isSame(as: identity)
        var candidate: ClassReference? = base
        var depth = 0
        while let current = candidate, depth < Self.maximumDepth {
            guard let slots = primarySlots(current), slotIndex < slots.count else { break }
            if let name = slots[slotIndex].name {
                return CPlusPlusVirtualFunction.BaseFunction(className: className(current), name: name, isInherited: isInherited)
            }
            candidate = primaryBase(current)
            depth += 1
        }
        return CPlusPlusVirtualFunction.BaseFunction(className: className(base), name: nil, isInherited: isInherited)
    }
}
