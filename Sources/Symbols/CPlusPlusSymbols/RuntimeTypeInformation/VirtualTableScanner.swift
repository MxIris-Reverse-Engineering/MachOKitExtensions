import Foundation

/// What a vtable slot holds, as the image stores it.
enum VirtualSlotRecord: Hashable, Sendable {
    case function(offset: Int)
    case imported(symbolName: String, installName: String?)
    case otherImage(address: UInt64)
    case pureVirtual
    case deletedVirtual
}

/// One vtable: the slots after one RTTI slot.
struct VirtualTableRecord: Hashable, Sendable {
    /// The offset of the first function slot, where a virtual pointer
    /// points.
    let addressPointOffset: Int
    let offsetToTop: Int
    let slots: [VirtualSlotRecord]

    /// The offset just past the last slot.
    var endOffset: Int {
        addressPointOffset + 8 * slots.count
    }
}

/// Finds the vtables that point at an image's typeinfos and groups them.
///
/// A vtable's RTTI slot points at its class's typeinfo and follows the
/// offset-to-top, a small integer no greater than zero. Its function slots
/// run until a word that is no function. Tables of one class that follow
/// each other with only integers between them — the next table's
/// offset-to-top and its vcall and virtual base offsets — are one group:
/// the primary table and the secondary ones. A class with virtual bases can
/// have more groups, the construction vtables of the classes deriving from
/// it.
struct VirtualTableScanner {
    /// No vtable is longer; a run this long is some other data.
    static let maximumSlotCount = 1 << 14
    /// The integers allowed between two tables of a group.
    static let maximumGapWordCount = 64

    let slots: ImagePointerSlots
    let markers: RuntimeLibraryMarkers
    /// Whether an address in another image is code.
    let isExternalCode: (UInt64) -> Bool

    /// The groups of tables of each typeinfo, by typeinfo offset, each group
    /// and each table in ascending order.
    func scan(typeInfos: [TypeInfoRecord]) -> [Int: [[VirtualTableRecord]]] {
        let typeInfoOffsets = Set(typeInfos.map(\.offset))
        let typeInfoRanges = typeInfos.map { $0.offset ..< $0.offset + $0.byteCount }.sorted { $0.lowerBound < $1.lowerBound }
        func isInsideTypeInfo(_ offset: Int) -> Bool {
            var low = 0
            var high = typeInfoRanges.count
            while low < high {
                let middle = (low + high) / 2
                if typeInfoRanges[middle].lowerBound <= offset { low = middle + 1 } else { high = middle }
            }
            return low > 0 && typeInfoRanges[low - 1].contains(offset)
        }

        var runtimeTypeInformationSlotsByTypeInfo: [Int: [Int]] = [:]
        slots.forEachDataSlot { offset, content in
            guard case .internalPointer(let target, _) = content,
                  typeInfoOffsets.contains(target),
                  !isInsideTypeInfo(offset),
                  slots.holdsSmallInteger(atOffset: offset - 8),
                  let offsetToTop = slots.word(atOffset: offset - 8),
                  offsetToTop <= 0 else {
                return
            }
            runtimeTypeInformationSlotsByTypeInfo[target, default: []].append(offset)
        }
        let allRuntimeTypeInformationSlots = Set(runtimeTypeInformationSlotsByTypeInfo.values.joined())

        var groupsByTypeInfo: [Int: [[VirtualTableRecord]]] = [:]
        for (typeInfoOffset, runtimeTypeInformationSlots) in runtimeTypeInformationSlotsByTypeInfo {
            var groups: [[VirtualTableRecord]] = []
            for runtimeTypeInformationSlot in runtimeTypeInformationSlots.sorted() {
                let table = VirtualTableRecord(
                    addressPointOffset: runtimeTypeInformationSlot + 8,
                    offsetToTop: Int(slots.word(atOffset: runtimeTypeInformationSlot - 8) ?? 0),
                    slots: functionSlots(from: runtimeTypeInformationSlot + 8, stoppingAt: allRuntimeTypeInformationSlots, isInsideTypeInfo: isInsideTypeInfo)
                )
                if let previous = groups.last?.last, continuesGroup(after: previous, with: table) {
                    groups[groups.count - 1].append(table)
                } else {
                    groups.append([table])
                }
            }
            groupsByTypeInfo[typeInfoOffset] = groups
        }
        return groupsByTypeInfo
    }

    private func functionSlots(from start: Int, stoppingAt runtimeTypeInformationSlots: Set<Int>, isInsideTypeInfo: (Int) -> Bool) -> [VirtualSlotRecord] {
        var records: [VirtualSlotRecord] = []
        var offset = start
        while records.count < Self.maximumSlotCount, !runtimeTypeInformationSlots.contains(offset), !isInsideTypeInfo(offset),
              let content = slots.content(atOffset: offset),
              let record = slotRecord(for: content) {
            records.append(record)
            offset += 8
        }
        return records
    }

    private func slotRecord(for content: ImagePointerSlots.Content) -> VirtualSlotRecord? {
        if let markedFunction = markers.markedFunction(in: content) {
            return switch markedFunction {
            case .pureVirtual: .pureVirtual
            case .deletedVirtual: .deletedVirtual
            }
        }
        switch content {
        case .internalPointer(let target, _):
            return slots.isExecutable(offset: target) ? .function(offset: target) : nil
        case .boundSymbol(let name, let addend, let installName):
            guard addend == 0, !Self.namesData(name) else { return nil }
            return .imported(symbolName: name, installName: installName)
        case .externalAddress(let address):
            return isExternalCode(address) ? .otherImage(address: address) : nil
        }
    }

    /// Whether a bound symbol is data rather than a function: a vtable, a
    /// typeinfo or its name, or an Objective-C object.
    private static func namesData(_ name: String) -> Bool {
        name.hasPrefix("__ZTV") || name.hasPrefix("__ZTI") || name.hasPrefix("__ZTS") || name.hasPrefix("__ZTT") || name.hasPrefix("_OBJC_")
    }

    /// Whether `table` follows `previous` in the same group: only integers
    /// lie between the end of `previous` and `table`'s offset-to-top.
    private func continuesGroup(after previous: VirtualTableRecord, with table: VirtualTableRecord) -> Bool {
        let gapStart = previous.endOffset
        let gapEnd = table.addressPointOffset - 16
        guard gapEnd >= gapStart, (gapEnd - gapStart) / 8 <= Self.maximumGapWordCount else { return false }
        return stride(from: gapStart, to: gapEnd, by: 8).allSatisfy { slots.holdsSmallInteger(atOffset: $0) }
    }
}
