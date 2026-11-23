import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import MachODependencies
import MachOFixtureSupport
import MachOTestingSupport
@testable import CPlusPlusSymbols

/// The class index, read from the image the C++ fixture is linked into —
/// both from its file and as this process loaded it. Each test reads through
/// both readers, expects them to agree, and then checks what they read.
@Suite
final class CPlusPlusClassIndexStoreTests: ClassIndexFixtureTests {
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

    private static func classShapes(_ qualifiedNames: [String], in machO: some MachORepresentableWithCache) throws -> [ClassShape] {
        try qualifiedNames.map { ClassShape(try requireClass($0, in: machO)) }
    }

    private static func primaryTableShapes(_ qualifiedNames: [String], in machO: some MachORepresentableWithCache) throws -> [VirtualTableShape] {
        try qualifiedNames.map { VirtualTableShape(try primaryTable(of: $0, in: machO)) }
    }

    // MARK: Classes and bases

    @Test func everyFixtureClassWithATypeInfoIsFound() throws {
        let names = try acrossAllReaders { machO in Self.store.classes(in: machO).map(\.qualifiedName) }
        let expected: Set<String> = [
            "fixture::Polymorphic", "fixture::VirtualBase", "fixture::Intermediate", "fixture::Complete",
            "hierarchy::Left", "hierarchy::Right", "hierarchy::Both", "hierarchy::Shape", "hierarchy::Square",
            "hierarchy::Retired", "hierarchy::Failure", "hierarchy::InlineOnly", "hierarchy::(anonymous namespace)::Anonymous",
        ]
        #expect(expected.isSubset(of: Set(names)), "missing \(expected.subtracting(names))")
        #expect(names == names.sorted())
    }

    @Test func singleInheritanceRecordsTheBaseAtOffsetZero() throws {
        struct Reading: Equatable {
            let square: ClassShape
            let shape: ClassShape
            /// Where each reader places `Shape`'s typeinfo differs; that the
            /// base points there does not.
            let squareBaseIsShapeInThisImage: Bool
        }
        let reading = try acrossAllReaders { machO in
            let square = try Self.requireClass("hierarchy::Square", in: machO)
            let shape = try Self.requireClass("hierarchy::Shape", in: machO)
            return Reading(
                square: ClassShape(square),
                shape: ClassShape(shape),
                squareBaseIsShapeInThisImage: square.bases.first?.location == .sameImage(typeInfoOffset: shape.typeInfoOffset)
            )
        }
        #expect(reading.square.bases.count == 1)
        let base = try #require(reading.square.bases.first)
        #expect(base.qualifiedName == "hierarchy::Shape")
        #expect(base.offset == 0)
        #expect(base.isPublic)
        #expect(!base.isVirtual)
        #expect(reading.squareBaseIsShapeInThisImage)
        #expect(reading.shape.bases.isEmpty)
        #expect(reading.square.hasVirtualTable && reading.shape.hasVirtualTable)
        #expect(reading.square.hasTypeInfoSymbol)
    }

    @Test func multipleInheritanceRecordsEveryBaseWithItsOffset() throws {
        let both = try acrossAllReaders { machO in ClassShape(try Self.requireClass("hierarchy::Both", in: machO)) }
        #expect(both.bases.map(\.qualifiedName) == ["hierarchy::Left", "hierarchy::Right"])
        // `Left` holds a virtual pointer and a long.
        #expect(both.bases.map(\.offset) == [0, 16])
        #expect(both.bases.allSatisfy { $0.isPublic && !$0.isVirtual })
        #expect(both.inheritanceShape.isEmpty)
    }

    @Test func virtualInheritanceRecordsTheVirtualBaseOffsetSlot() throws {
        let classes = try acrossAllReaders { machO in try Self.classShapes(["fixture::Intermediate", "fixture::Complete"], in: machO) }
        let intermediate = classes[0]
        let base = try #require(intermediate.bases.first)
        #expect(intermediate.bases.count == 1)
        #expect(base.qualifiedName == "fixture::VirtualBase")
        #expect(base.isVirtual)
        // Where the vtable stores the virtual base's offset: before the
        // offset-to-top and the RTTI slot.
        #expect(base.offset < -16)
        #expect(classes[1].bases.map(\.qualifiedName) == ["fixture::Intermediate"])
    }

    @Test func aBaseInAnotherImageIsNamedAndLocatedThere() throws {
        struct Reading: Equatable {
            let failure: ClassShape
            /// The file names libc++, which binds the typeinfo; the loaded
            /// image libc++abi, which defines it. Either is a libc++.
            let baseIsInALibCPlusPlus: Bool
        }
        let reading = try acrossAllReaders { machO in
            let failure = try Self.requireClass("hierarchy::Failure", in: machO)
            var baseIsInALibCPlusPlus = false
            if case .otherImage(let installName)? = failure.bases.first?.location, let installName {
                baseIsInALibCPlusPlus = installName.contains("libc++")
            }
            return Reading(failure: ClassShape(failure), baseIsInALibCPlusPlus: baseIsInALibCPlusPlus)
        }
        let base = try #require(reading.failure.bases.first)
        #expect(base.qualifiedName == "std::exception")
        #expect(base.location == .otherImage)
        #expect(reading.baseIsInALibCPlusPlus)
    }

    @Test func aClassWithoutAKeyFunctionHasANonUniqueTypeInfoAndItsNameStillReads() throws {
        let classes = try acrossAllReaders { machO in try Self.classShapes(["hierarchy::InlineOnly", "hierarchy::Left"], in: machO) }
        let inlineOnly = classes[0]
        #expect(inlineOnly.mangledTypeName == "N9hierarchy10InlineOnlyE")
        #if arch(arm64)
        #expect(!inlineOnly.hasUniqueTypeInfo)
        #endif
        #expect(classes[1].hasUniqueTypeInfo)
    }

    @Test func qualifiedNameFindsTheSameScopeInTheScopeTree() throws {
        struct Reading: Equatable {
            let both: ClassShape
            let scopePath: [String]?
            let scopeBaseName: String?
        }
        let reading = try acrossAllReaders { machO in
            let both = try Self.requireClass("hierarchy::Both", in: machO)
            let scope = CPlusPlusSymbolIndexStore.shared.scope(named: both.qualifiedName, in: machO)
            return Reading(both: ClassShape(both), scopePath: scope?.path, scopeBaseName: scope?.baseName)
        }
        let scopePath = try #require(reading.scopePath, "no scope \(reading.both.qualifiedName)")
        #expect(scopePath == reading.both.scopePath)
        #expect(reading.scopeBaseName == reading.both.baseName)
    }

    @Test func derivedClassesListTheDirectSubclassesInTheImage() throws {
        struct Reading: Equatable {
            let derivedNames: Set<String>
            let classAtLeftsTypeInfoIsLeft: Bool
        }
        let reading = try acrossAllReaders { machO in
            let left = try Self.requireClass("hierarchy::Left", in: machO)
            return Reading(
                derivedNames: Set(Self.store.derivedClasses(of: left, in: machO).map(\.qualifiedName)),
                classAtLeftsTypeInfoIsLeft: Self.store.class(atTypeInfoOffset: left.typeInfoOffset, in: machO) == left
            )
        }
        #expect(reading.derivedNames == ["hierarchy::Both", "hierarchy::(anonymous namespace)::Anonymous"])
        #expect(reading.classAtLeftsTypeInfoIsLeft)
    }

    @Test func processImageAndItsFileGiveTheSameClasses() throws {
        let classes = try acrossAllReaders { machO in Self.store.classes(in: machO).map(ClassShape.init) }
        #expect(!classes.isEmpty)
    }

    /// A standalone file binds `std::exception`'s typeinfo from libc++,
    /// which re-exports libc++abi, where it is defined.
    @Test func aStandaloneFileReachesABaseThroughAReexportingLibrary() throws {
        let file = machOFile
        let failure = try Self.requireClass("hierarchy::Failure", in: file)
        let storage = try #require(Self.store.storage(in: file))
        let record = try #require(storage.record(atTypeInfoOffset: failure.typeInfoOffset))
        let reference = try #require(record.bases.first?.reference)
        let locator = BaseClassLocator(root: .file(file), dependencySearchPaths: nil)
        let located = locator.locate(reference, from: .file(file))
        // How far a locator of the same search paths gets, for the failure
        // message.
        let searchPaths = DependencySearchPath.inferred(forRoot: file) + [.systemDyldSharedCache]
        let fileLocator = FileDependencyLocator(searchPaths: searchPaths, preferredCPU: file.header.cpu, platforms: DependencyPlatforms.platforms(of: file))
        let libraryCPlusPlus = fileLocator.locate(loadName: "/usr/lib/libc++.1.dylib")
        let reexported = libraryCPlusPlus.map { IndexedImage.file($0).reexportedInstallNames } ?? []
        let libraryCPlusPlusABI = reexported.first.flatMap { fileLocator.locate(loadName: $0) }
        let definition = libraryCPlusPlusABI.flatMap { CPlusPlusSymbolIndexStore.shared.symbol(named: "__ZTISt9exception", in: $0) }
        let trail = "search paths \(searchPaths); libc++ \(libraryCPlusPlus?.imagePath ?? "not located"), re-exports \(reexported), libc++abi \(libraryCPlusPlusABI?.imagePath ?? "not located"), definition \(definition.map { "\($0.offset)" } ?? "none")"
        let (image, offset) = try #require(located, "\(reference) not located: \(trail)")
        #expect(image.imagePath == "/usr/lib/libc++abi.dylib")
        let exception = Self.store.class(atTypeInfoOffset: offset, in: image.representable)
        #expect(exception?.qualifiedName == "std::exception", "\(reference) located at \(offset) in \(image.imagePath), \(Self.store.classes(in: image.representable).count) classes there")
    }

    // MARK: Vtables

    @Test func primaryTableListsSlotsInDeclarationOrder() throws {
        let table = try acrossAllReaders { machO in VirtualTableShape(try Self.primaryTable(of: "hierarchy::Left", in: machO)) }
        // The virtual destructor takes two slots: complete and deleting.
        #expect(table.baseNames == ["~Left", "~Left", "left"])
        #expect(table.functions.map(\.slotIndex) == [0, 1, 2])
        #expect(table.offsetToTop == 0)
        #expect(table.subobjectClassName == nil)
        #expect(table.functions.allSatisfy { $0.implementation == .function })
    }

    @Test func secondaryTableBelongsToTheBaseAtItsOffset() throws {
        let tables = try acrossAllReaders { machO in
            let both = try Self.requireClass("hierarchy::Both", in: machO)
            return Self.store.virtualTables(of: both, in: machO).map(VirtualTableShape.init)
        }
        #expect(tables.map(\.offsetToTop) == [0, -16])
        #expect(tables.map(\.subobjectClassName) == [nil, "hierarchy::Right"])
        // `right` overrides a function of the secondary base: it gets a slot
        // of its own in the primary table, after `Left`'s.
        #expect(tables.first?.baseNames == ["~Both", "~Both", "left", "right", "both"])
    }

    @Test func secondaryTableSlotsAreThunksNamedAfterTheOverrider() throws {
        let tables = try acrossAllReaders { machO in
            let both = try Self.requireClass("hierarchy::Both", in: machO)
            return Self.store.virtualTables(of: both, in: machO).map(VirtualTableShape.init)
        }
        let secondary = try #require(tables.last)
        let right = try #require(secondary.functions.last)
        #expect(right.slotIndex == 2)
        #expect(right.symbolName?.kind == .nonVirtualThunk)
        #expect(right.symbolName?.baseName == "right")
        #expect(right.symbolName?.scopePath == ["hierarchy", "Both"])
        #expect(right.baseFunction?.className == "hierarchy::Right")
        #expect(right.baseFunction?.isInherited == false)
    }

    @Test func theOwnTableIsPickedOverAConstructionTable() throws {
        struct Reading: Equatable {
            let tables: [VirtualTableShape]
            /// How far into the vtable symbol the primary table's address
            /// point lies.
            let addressPointDistance: Int
        }
        let reading = try acrossAllReaders { machO in
            let intermediate = try Self.requireClass("fixture::Intermediate", in: machO)
            let tables = Self.store.virtualTables(of: intermediate, in: machO)
            let foundSymbol = CPlusPlusSymbolIndexStore.shared.symbol(named: "__ZTVN7fixture12IntermediateE", in: machO)
            let virtualTableSymbol = try #require(foundSymbol)
            let primary = try #require(tables.first)
            return Reading(tables: tables.map(VirtualTableShape.init), addressPointDistance: primary.addressPointOffset - virtualTableSymbol.offset)
        }
        let primary = try #require(reading.tables.first)
        #expect(primary.isPrimary)
        // The primary table starts right after the group's virtual base
        // offset, offset-to-top and RTTI slot.
        #expect(reading.addressPointDistance > 0)
        #expect(reading.addressPointDistance <= 8 * 8)
        // `VirtualBase` holds nothing but its virtual pointer: as a nearly
        // empty virtual base it is `Intermediate`'s primary base and shares
        // its table, which names the slots after it.
        #expect(reading.tables.count == 1)
        #expect(primary.functions.map { $0.baseFunction?.className } == Array(repeating: "fixture::VirtualBase", count: 3))
        #expect(primary.baseNames == ["~Intermediate", "~Intermediate", "run"])
    }

    @Test func pureAndDeletedVirtualSlotsAreMarked() throws {
        let tables = try acrossAllReaders { machO in try Self.primaryTableShapes(["hierarchy::Shape", "hierarchy::Retired"], in: machO) }
        let shape = tables[0]
        #expect(shape.functions.count == 3)
        #expect(shape.functions.last?.implementation == .pureVirtual)
        let retired = tables[1]
        #expect(retired.functions.count == 4)
        #expect(retired.functions.last?.implementation == .deletedVirtual)
        #expect(retired.functions[2].name?.baseName == "kept")
    }

    @Test func anOverrideIsNotInheritedAndAnUntouchedSlotIs() throws {
        let tables = try acrossAllReaders { machO in try Self.primaryTableShapes(["hierarchy::Both", "hierarchy::Square"], in: machO) }
        // `Both` keeps `Left::left` and overrides the destructor.
        let both = tables[0]
        #expect(both.functions[2].baseFunction?.isInherited == true)
        #expect(both.functions[2].baseFunction?.className == "hierarchy::Left")
        #expect(both.functions[2].baseFunction?.name?.baseName == "left")
        #expect(both.functions[0].baseFunction?.isInherited == false)
        let square = tables[1]
        #expect(square.functions[2].baseFunction?.className == "hierarchy::Shape")
        #expect(square.functions[2].baseFunction?.isInherited == false)
        #expect(square.functions[2].name?.baseName == "area")
    }

    @Test func aSlotTheClassIntroducesHasNoBaseFunction() throws {
        let tables = try acrossAllReaders { machO in try Self.primaryTableShapes(["hierarchy::Both", "hierarchy::Left"], in: machO) }
        let both = tables[0]
        #expect(both.functions[3].baseFunction == nil)
        #expect(both.functions[4].baseFunction == nil)
        #expect(tables[1].functions.allSatisfy { $0.baseFunction == nil })
    }

    @Test func aBaseInAnotherImageNamesTheSlotsTheClassInherits() throws {
        let failure = try acrossAllReaders { machO in VirtualTableShape(try Self.primaryTable(of: "hierarchy::Failure", in: machO)) }
        // `std::exception`: two destructor slots and `what`.
        #expect(failure.baseNames == ["~Failure", "~Failure", "what"])
        #expect(failure.functions.allSatisfy { $0.baseFunction?.className == "std::exception" })
        #expect(failure.functions[2].baseFunction?.name?.baseName == "what")
        #expect(failure.functions[2].baseFunction?.isInherited == false)
    }

    @Test func tableScanStopsAtTheNextObject() throws {
        let expectedSlotCounts: [String: [Int]] = [
            "hierarchy::Left": [3], "hierarchy::Right": [3], "hierarchy::Both": [5, 3],
            "hierarchy::Shape": [3], "hierarchy::Square": [3], "hierarchy::Retired": [4],
            "hierarchy::Failure": [3], "hierarchy::InlineOnly": [3], "fixture::Polymorphic": [3],
        ]
        let slotCounts = try acrossAllReaders { machO in
            var slotCounts: [String: [Int]] = [:]
            for qualifiedName in expectedSlotCounts.keys {
                let polymorphicClass = try Self.requireClass(qualifiedName, in: machO)
                slotCounts[qualifiedName] = Self.store.virtualTables(of: polymorphicClass, in: machO).map(\.functions.count)
            }
            return slotCounts
        }
        for (qualifiedName, expected) in expectedSlotCounts {
            #expect(slotCounts[qualifiedName] == expected, "\(qualifiedName)")
        }
    }

    // MARK: Store

    @Test func prepareBuildsAndRemoveDrops() throws {
        let image = machOImage
        let store = CPlusPlusClassIndexStore(symbolStore: .shared)
        #expect(!store.contains(in: image))
        store.prepare(in: image)
        #expect(store.contains(in: image))
        store.remove(for: image)
        #expect(!store.contains(in: image))
    }
}
