import Foundation

/// Where a typeinfo's base pointer points.
enum TypeInfoReference: Hashable, Sendable {
    /// A typeinfo of the same image, at this offset.
    case local(offset: Int)
    /// A standalone file's bind to a typeinfo of another library: its
    /// `__ZTI…` symbol and the library it is bound from.
    case boundSymbol(name: String, installName: String?)
    /// A typeinfo of another image: an unslid address of the same dyld
    /// shared cache, or an address of this process.
    case address(UInt64)
}

/// A class typeinfo object as the image stores it.
struct TypeInfoRecord: Sendable {
    struct BaseRecord: Sendable {
        let reference: TypeInfoReference
        /// libc++abi's `__offset_flags`: bit 0 virtual, bit 1 public, the
        /// offset from bit 8 on.
        let offsetFlags: Int64
    }

    let offset: Int
    let kind: RuntimeLibraryMarkers.ClassTypeInfoKind
    /// The type's mangling without `_Z`: `N4llvm5ValueE`.
    let mangledTypeName: String
    /// `false` when the name pointer carries Apple arm64's non-unique bit.
    let hasUniqueName: Bool
    /// `__vmi_class_type_info::__flags`; `0` for the other kinds.
    let inheritanceFlags: UInt32
    let bases: [BaseRecord]

    /// The bytes the object takes.
    var byteCount: Int {
        switch kind {
        case .noBase:
            16
        case .singleBase:
            24
        case .multipleOrVirtualBases:
            24 + 16 * bases.count
        }
    }
}

/// Finds the class typeinfo objects of an image by their virtual pointers,
/// which point into one of libc++abi's three class `type_info` vtables.
enum TypeInfoScanner {
    /// A vmi typeinfo claiming more bases is taken for some other data.
    static let maximumBaseCount: UInt32 = 1024

    /// A mangled name longer than this is taken for some other data.
    static let maximumNameLength = 1 << 16

    static func scan(_ slots: ImagePointerSlots, markers: RuntimeLibraryMarkers) -> [TypeInfoRecord] {
        var records: [TypeInfoRecord] = []
        slots.forEachDataSlot { offset, content in
            guard let kind = markers.classTypeInfoKind(ofVirtualPointer: content),
                  let record = record(at: offset, kind: kind, in: slots) else {
                return
            }
            records.append(record)
        }
        return records
    }

    private static func record(at offset: Int, kind: RuntimeLibraryMarkers.ClassTypeInfoKind, in slots: ImagePointerSlots) -> TypeInfoRecord? {
        guard case .internalPointer(let nameOffset, let topByte) = slots.content(atOffset: offset + 8),
              let name = slots.string(atOffset: nameOffset),
              isPlausibleMangledTypeName(name) else {
            return nil
        }
        var bases: [TypeInfoRecord.BaseRecord] = []
        var inheritanceFlags: UInt32 = 0
        switch kind {
        case .noBase:
            break
        case .singleBase:
            guard let reference = reference(atOffset: offset + 16, in: slots) else { return nil }
            // One public, non-virtual base at offset zero.
            bases = [TypeInfoRecord.BaseRecord(reference: reference, offsetFlags: 0x2)]
        case .multipleOrVirtualBases:
            guard let flags = slots.unsignedWord32(atOffset: offset + 16),
                  let baseCount = slots.unsignedWord32(atOffset: offset + 20),
                  baseCount >= 1, baseCount <= maximumBaseCount else {
                return nil
            }
            inheritanceFlags = flags
            for baseIndex in 0 ..< Int(baseCount) {
                let entryOffset = offset + 24 + 16 * baseIndex
                guard let reference = reference(atOffset: entryOffset, in: slots),
                      let offsetFlags = slots.word(atOffset: entryOffset + 8) else {
                    return nil
                }
                bases.append(TypeInfoRecord.BaseRecord(reference: reference, offsetFlags: offsetFlags))
            }
        }
        return TypeInfoRecord(
            offset: offset,
            kind: kind,
            mangledTypeName: name,
            hasUniqueName: topByte & 0x80 == 0,
            inheritanceFlags: inheritanceFlags,
            bases: bases
        )
    }

    private static func reference(atOffset offset: Int, in slots: ImagePointerSlots) -> TypeInfoReference? {
        switch slots.content(atOffset: offset) {
        case .internalPointer(let target, _):
            .local(offset: target)
        case .boundSymbol(let name, _, let installName):
            name.hasPrefix("__ZTI") ? .boundSymbol(name: name, installName: installName) : nil
        case .externalAddress(let address):
            .address(address)
        case nil:
            nil
        }
    }

    private static func isPlausibleMangledTypeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumNameLength else { return false }
        return name.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }
}
