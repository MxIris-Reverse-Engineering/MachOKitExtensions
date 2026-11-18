import Foundation
import Testing
import MachOResolving
@_spi(Internals) @testable import MachOSymbols

/// The packed name-reference budgets (22-bit byte length / 40-bit byte
/// offset) are enforced against binary-supplied values: a name that cannot
/// pack must degrade — the sweep skips its row — never trap. A
/// `precondition` here is fatal in release builds, so a malformed or hostile
/// binary's symbol-table geometry would decide whether the host process
/// lives.
@Suite
struct PackedNameReferenceBudgetTests {
    private static let oversizedName = "_" + String(repeating: "A", count: PackedNameReference.maximumByteLength + 64)

    @Test func packedNameReferenceRefusesOverBudgetComponents() {
        #expect(PackedNameReference(usesPrivateNameBuffer: true, isExternal: false, byteOffset: 0, byteLength: PackedNameReference.maximumByteLength + 1) == nil)
        #expect(PackedNameReference(usesPrivateNameBuffer: true, isExternal: false, byteOffset: PackedNameReference.maximumByteOffset + 1, byteLength: 1) == nil)
        #expect(PackedNameReference(usesPrivateNameBuffer: true, isExternal: false, byteOffset: -1, byteLength: 1) == nil)
        #expect(PackedNameReference(usesPrivateNameBuffer: true, isExternal: false, byteOffset: 0, byteLength: -1) == nil)

        let packedNameReference = PackedNameReference(usesPrivateNameBuffer: true, isExternal: true, byteOffset: 7, byteLength: 5)
        #expect(packedNameReference?.usesPrivateNameBuffer == true)
        #expect(packedNameReference?.isExternal == true)
        #expect(packedNameReference?.byteOffset == 7)
        #expect(packedNameReference?.byteLength == 5)
    }

    /// A private-buffer name beyond the byte-length budget is skipped (its
    /// row is refused, no orphan bytes are appended), while normal names
    /// keep minting rows.
    @Test func tableBuilderSkipsAnOverBudgetPrivateBufferName() {
        var tableBuilder = SymbolTableBuilder(mappedStringTableBase: nil)
        #expect(tableBuilder.canonicalRow(forName: Self.oversizedName, canonicalOffset: 0, isExternal: false) == nil)

        let normalRow = tableBuilder.canonicalRow(forName: "_normal_name", canonicalOffset: 8, isExternal: false)
        #expect(normalRow?.isNewRow == true)

        let symbolTable = tableBuilder.freeze()
        #expect(symbolTable.rowCount == 1)
        #expect(symbolTable.materializedName(atRow: 0) == "_normal_name")
    }

    /// The standalone one-row table clamps an over-budget name to the
    /// representable prefix instead of trapping.
    @Test func standaloneTableClampsAnOverBudgetName() {
        let symbolTable = SymbolTable(standaloneSymbol: .init(offset: 0, name: Self.oversizedName))
        #expect(symbolTable.rowCount == 1)
        #expect(symbolTable.materializedName(atRow: 0).utf8.count == PackedNameReference.maximumByteLength)
        #expect(Self.oversizedName.hasPrefix(symbolTable.materializedName(atRow: 0)))
    }

    /// Sixteen bytes a row is what the table's memory estimate rests on.
    @Test func symbolRowIsSixteenBytes() {
        #expect(MemoryLayout<SymbolRow>.stride == 16)
    }

    /// The bucket's whole contract: first append stays inline, the second
    /// spills to an array, iteration preserves insertion order, and
    /// `contains` answers both forms.
    @Test func symbolRowBucketAppendMigrationAndIterationOrder() {
        var bucket = SymbolRowBucket.empty
        #expect(bucket.isEmpty)
        #expect(!bucket.contains(7))

        bucket.append(7)
        #expect(bucket == .single(7))
        #expect(Array(bucket) == [7])

        bucket.append(9)
        #expect(bucket == .multiple([7, 9]))

        bucket.append(5)
        #expect(Array(bucket) == [7, 9, 5])
        #expect(bucket.count == 3)
        #expect(bucket.contains(5))
        #expect(!bucket.contains(6))
    }
}
