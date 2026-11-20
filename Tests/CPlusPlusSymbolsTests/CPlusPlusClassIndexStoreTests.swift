import Foundation
import Testing
import MachOKit
import MachOKitExtensions
@testable import CPlusPlusSymbols

/// The class index, read from the image the C++ fixture is linked into —
/// both as this process loaded it and from its file.
@Suite
struct CPlusPlusClassIndexStoreTests {
    typealias Reader = ClassIndexTestImages.Reader

    private static let store = CPlusPlusClassIndexStore.shared

    private static func requireClass(_ qualifiedName: String, in machO: some MachORepresentableWithCache) throws -> CPlusPlusClass {
        let found = store.class(named: qualifiedName, in: machO)
        return try #require(found, "no class \(qualifiedName)")
    }

    private static func primaryTable(of qualifiedName: String, in machO: some MachORepresentableWithCache) throws -> CPlusPlusVirtualTable {
        let polymorphicClass = try requireClass(qualifiedName, in: machO)
        let primary = store.virtualTables(of: polymorphicClass, in: machO).first { $0.isPrimary }
        return try #require(primary, "no primary vtable of \(qualifiedName)")
    }

    private static func baseNames(_ table: CPlusPlusVirtualTable) -> [String?] {
        table.functions.map { $0.name?.baseName }
    }

    // MARK: Classes and bases

    @Test(arguments: Reader.allCases)
    func everyFixtureClassWithATypeInfoIsFound(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let names = Set(Self.store.classes(in: machO).map(\.qualifiedName))
        let expected: Set<String> = [
            "fixture::Polymorphic", "fixture::VirtualBase", "fixture::Intermediate", "fixture::Complete",
            "hierarchy::Left", "hierarchy::Right", "hierarchy::Both", "hierarchy::Shape", "hierarchy::Square",
            "hierarchy::Retired", "hierarchy::Failure", "hierarchy::HiddenInline", "hierarchy::(anonymous namespace)::Anonymous",
        ]
        #expect(expected.isSubset(of: names), "missing \(expected.subtracting(names))")
        let classes = Self.store.classes(in: machO)
        #expect(classes.map(\.qualifiedName) == classes.map(\.qualifiedName).sorted())
    }

    @Test(arguments: Reader.allCases)
    func singleInheritanceRecordsTheBaseAtOffsetZero(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let square = try Self.requireClass("hierarchy::Square", in: machO)
        let shape = try Self.requireClass("hierarchy::Shape", in: machO)
        #expect(square.bases.count == 1)
        let base = try #require(square.bases.first)
        #expect(base.qualifiedName == "hierarchy::Shape")
        #expect(base.offset == 0)
        #expect(base.isPublic)
        #expect(!base.isVirtual)
        #expect(base.location == .sameImage(typeInfoOffset: shape.typeInfoOffset))
        #expect(shape.bases.isEmpty)
        #expect(square.hasVirtualTable && shape.hasVirtualTable)
        #expect(square.hasTypeInfoSymbol)
    }

    @Test(arguments: Reader.allCases)
    func multipleInheritanceRecordsEveryBaseWithItsOffset(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let both = try Self.requireClass("hierarchy::Both", in: machO)
        #expect(both.bases.map(\.qualifiedName) == ["hierarchy::Left", "hierarchy::Right"])
        // `Left` holds a virtual pointer and a long.
        #expect(both.bases.map(\.offset) == [0, 16])
        #expect(both.bases.allSatisfy { $0.isPublic && !$0.isVirtual })
        #expect(both.inheritanceShape.isEmpty)
    }

    @Test(arguments: Reader.allCases)
    func virtualInheritanceRecordsTheVirtualBaseOffsetSlot(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let intermediate = try Self.requireClass("fixture::Intermediate", in: machO)
        let base = try #require(intermediate.bases.first)
        #expect(intermediate.bases.count == 1)
        #expect(base.qualifiedName == "fixture::VirtualBase")
        #expect(base.isVirtual)
        // Where the vtable stores the virtual base's offset: before the
        // offset-to-top and the RTTI slot.
        #expect(base.offset < -16)
        let complete = try Self.requireClass("fixture::Complete", in: machO)
        #expect(complete.bases.map(\.qualifiedName) == ["fixture::Intermediate"])
    }

    @Test(arguments: Reader.allCases)
    func aBaseInAnotherImageIsNamedAndLocatedThere(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let failure = try Self.requireClass("hierarchy::Failure", in: machO)
        let base = try #require(failure.bases.first)
        #expect(base.qualifiedName == "std::exception")
        guard case .otherImage(let installName) = base.location else {
            Issue.record("std::exception is in \(base.location)")
            return
        }
        let library = try #require(installName)
        #expect(library.contains("libc++"), "std::exception located in \(library)")
    }

    @Test(arguments: Reader.allCases)
    func aHiddenClassHasANonUniqueTypeInfoAndItsNameStillReads(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let hiddenInline = try Self.requireClass("hierarchy::HiddenInline", in: machO)
        #expect(hiddenInline.mangledTypeName == "N9hierarchy12HiddenInlineE")
        #if arch(arm64)
        #expect(!hiddenInline.hasUniqueTypeInfo)
        #endif
        let left = try Self.requireClass("hierarchy::Left", in: machO)
        #expect(left.hasUniqueTypeInfo)
    }

    @Test(arguments: Reader.allCases)
    func qualifiedNameFindsTheSameScopeInTheScopeTree(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let both = try Self.requireClass("hierarchy::Both", in: machO)
        let foundScope = CPlusPlusSymbolIndexStore.shared.scope(named: both.qualifiedName, in: machO)
        let scope = try #require(foundScope)
        #expect(scope.path == both.scopePath)
        #expect(scope.baseName == both.baseName)
    }

    @Test(arguments: Reader.allCases)
    func derivedClassesListTheDirectSubclassesInTheImage(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let left = try Self.requireClass("hierarchy::Left", in: machO)
        let derived = Self.store.derivedClasses(of: left, in: machO).map(\.qualifiedName)
        #expect(Set(derived) == ["hierarchy::Both", "hierarchy::(anonymous namespace)::Anonymous"])
        let classAtOffset = Self.store.class(atTypeInfoOffset: left.typeInfoOffset, in: machO)
        #expect(classAtOffset == left)
    }

    @Test func processImageAndItsFileGiveTheSameClasses() throws {
        let image = try ClassIndexTestImages.fixtureImage()
        let file = try ClassIndexTestImages.fixtureFile()
        func shape(of classes: [CPlusPlusClass]) -> [String] {
            classes.map { polymorphicClass in
                polymorphicClass.qualifiedName + ": " + polymorphicClass.bases.map { "\($0.qualifiedName)@\($0.offset)\($0.isVirtual ? "v" : "")" }.joined(separator: ", ")
                    + " vtable \(polymorphicClass.hasVirtualTable) symbol \(polymorphicClass.hasTypeInfoSymbol) unique \(polymorphicClass.hasUniqueTypeInfo)"
            }
        }
        #expect(shape(of: Self.store.classes(in: image)) == shape(of: Self.store.classes(in: file)))
    }

    // MARK: Vtables

    @Test(arguments: Reader.allCases)
    func primaryTableListsSlotsInDeclarationOrder(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let table = try Self.primaryTable(of: "hierarchy::Left", in: machO)
        // The virtual destructor takes two slots: complete and deleting.
        #expect(Self.baseNames(table) == ["~Left", "~Left", "left"])
        #expect(table.functions.map(\.slotIndex) == [0, 1, 2])
        #expect(table.offsetToTop == 0)
        #expect(table.subobjectClassName == nil)
        #expect(table.functions.allSatisfy { if case .function = $0.implementation { true } else { false } })
    }

    @Test(arguments: Reader.allCases)
    func secondaryTableBelongsToTheBaseAtItsOffset(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let both = try Self.requireClass("hierarchy::Both", in: machO)
        let tables = Self.store.virtualTables(of: both, in: machO)
        #expect(tables.map(\.offsetToTop) == [0, -16])
        #expect(tables.map(\.subobjectClassName) == [nil, "hierarchy::Right"])
        // `right` overrides a function of the secondary base: it gets a slot
        // of its own in the primary table, after `Left`'s.
        #expect(tables.first.map(Self.baseNames) == ["~Both", "~Both", "left", "right", "both"])
    }

    @Test(arguments: Reader.allCases)
    func secondaryTableSlotsAreThunksNamedAfterTheOverrider(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let both = try Self.requireClass("hierarchy::Both", in: machO)
        let tables = Self.store.virtualTables(of: both, in: machO)
        let secondary = try #require(tables.last)
        let right = try #require(secondary.functions.last)
        #expect(right.slotIndex == 2)
        #expect(right.symbolName?.kind == .nonVirtualThunk)
        #expect(right.symbolName?.baseName == "right")
        #expect(right.symbolName?.scopePath == ["hierarchy", "Both"])
        #expect(right.baseFunction?.className == "hierarchy::Right")
        #expect(right.baseFunction?.isInherited == false)
    }

    @Test(arguments: Reader.allCases)
    func theOwnTableIsPickedOverAConstructionTable(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let intermediate = try Self.requireClass("fixture::Intermediate", in: machO)
        let tables = Self.store.virtualTables(of: intermediate, in: machO)
        let foundSymbol = CPlusPlusSymbolIndexStore.shared.symbol(named: "__ZTVN7fixture12IntermediateE", in: machO)
        let virtualTableSymbol = try #require(foundSymbol)
        let primary = try #require(tables.first)
        #expect(primary.isPrimary)
        // The primary table starts right after the group's virtual base
        // offset, offset-to-top and RTTI slot.
        #expect(primary.addressPointOffset > virtualTableSymbol.offset)
        #expect(primary.addressPointOffset - virtualTableSymbol.offset <= 8 * 8)
        // The secondary table belongs to the virtual base.
        #expect(tables.dropFirst().map(\.subobjectClassName) == ["fixture::VirtualBase"])
    }

    @Test(arguments: Reader.allCases)
    func pureAndDeletedVirtualSlotsAreMarked(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let shape = try Self.primaryTable(of: "hierarchy::Shape", in: machO)
        #expect(shape.functions.count == 3)
        #expect(shape.functions.last?.implementation == .pureVirtual)
        let retired = try Self.primaryTable(of: "hierarchy::Retired", in: machO)
        #expect(retired.functions.count == 4)
        #expect(retired.functions.last?.implementation == .deletedVirtual)
        #expect(retired.functions[2].name?.baseName == "kept")
    }

    @Test(arguments: Reader.allCases)
    func anOverrideIsNotInheritedAndAnUntouchedSlotIs(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let both = try Self.primaryTable(of: "hierarchy::Both", in: machO)
        // `Both` keeps `Left::left` and overrides the destructor.
        #expect(both.functions[2].baseFunction?.isInherited == true)
        #expect(both.functions[2].baseFunction?.className == "hierarchy::Left")
        #expect(both.functions[2].baseFunction?.name?.baseName == "left")
        #expect(both.functions[0].baseFunction?.isInherited == false)
        let square = try Self.primaryTable(of: "hierarchy::Square", in: machO)
        #expect(square.functions[2].baseFunction?.className == "hierarchy::Shape")
        #expect(square.functions[2].baseFunction?.isInherited == false)
        #expect(square.functions[2].name?.baseName == "area")
    }

    @Test(arguments: Reader.allCases)
    func aSlotTheClassIntroducesHasNoBaseFunction(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let both = try Self.primaryTable(of: "hierarchy::Both", in: machO)
        #expect(both.functions[3].baseFunction == nil)
        #expect(both.functions[4].baseFunction == nil)
        let left = try Self.primaryTable(of: "hierarchy::Left", in: machO)
        #expect(left.functions.allSatisfy { $0.baseFunction == nil })
    }

    @Test(arguments: Reader.allCases)
    func aBaseInAnotherImageNamesTheSlotsTheClassInherits(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let failure = try Self.primaryTable(of: "hierarchy::Failure", in: machO)
        // `std::exception`: two destructor slots and `what`.
        #expect(Self.baseNames(failure) == ["~Failure", "~Failure", "what"])
        #expect(failure.functions.allSatisfy { $0.baseFunction?.className == "std::exception" })
        #expect(failure.functions[2].baseFunction?.name?.baseName == "what")
        #expect(failure.functions[2].baseFunction?.isInherited == false)
    }

    @Test(arguments: Reader.allCases)
    func tableScanStopsAtTheNextObject(reader: Reader) throws {
        let machO = try ClassIndexTestImages.fixture(reader)
        let expectedSlotCounts: [String: [Int]] = [
            "hierarchy::Left": [3], "hierarchy::Right": [3], "hierarchy::Both": [5, 3],
            "hierarchy::Shape": [3], "hierarchy::Square": [3], "hierarchy::Retired": [4],
            "hierarchy::Failure": [3], "hierarchy::HiddenInline": [3], "fixture::Polymorphic": [3],
        ]
        for (qualifiedName, slotCounts) in expectedSlotCounts {
            let polymorphicClass = try Self.requireClass(qualifiedName, in: machO)
            let tables = Self.store.virtualTables(of: polymorphicClass, in: machO)
            #expect(tables.map(\.functions.count) == slotCounts, "\(qualifiedName)")
        }
    }

    // MARK: Store

    @Test func prepareBuildsAndRemoveDrops() throws {
        let image = try ClassIndexTestImages.fixtureImage()
        let store = CPlusPlusClassIndexStore(symbolStore: .shared)
        #expect(!store.contains(in: image))
        store.prepare(in: image)
        #expect(store.contains(in: image))
        store.remove(for: image)
        #expect(!store.contains(in: image))
    }
}
