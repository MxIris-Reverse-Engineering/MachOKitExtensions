import Foundation
import MachOKit
import MachOKitExtensions
import MachODependencies
@_spi(Internals) import MachOCaches
@_spi(Internals) import MachOAddressResolution

/// The C++ classes of an image, read from its run-time type information
/// and its vtables. An image's index is built on first use and shared by
/// every caller.
///
/// ```swift
/// let store = CPlusPlusClassIndexStore.shared
/// let hiddenClasses = store.classes(in: machO).filter { !$0.hasTypeInfoSymbol }
/// if let cellID = store.class(named: "TST::CellID", in: machO) {
///     for function in store.virtualTables(of: cellID, in: machO).first?.functions ?? [] {
///         print(function.slotIndex, function.name?.demangledName ?? "?")
///     }
/// }
/// ```
///
/// The index finds every class typeinfo of the image — the objects whose
/// virtual pointer points into one of libc++abi's three class `type_info`
/// vtables — whether or not a symbol names it, and every vtable whose RTTI
/// slot points at one of them. It reads data, not symbols: a class whose
/// symbols are stripped is found by its typeinfo's name.
///
/// A vtable slot is named when queried: by the C++ symbol at its
/// implementation, else by the function the same slot holds in the primary
/// base's table, walking up the bases — into other images too. An image of
/// this process reaches the other loaded images, a file out of a dyld shared
/// cache the same cache, and a standalone file the libraries its dependency
/// search paths locate.
///
/// Offsets are the ones ``CPlusPlusSymbolIndexStore`` uses. Nothing evicts
/// an index on its own: call ``remove(for:)`` when an image is no longer of
/// interest.
///
/// `Sendable`: an index is immutable once built, and the caches lock
/// themselves.
public final class CPlusPlusClassIndexStore: Sendable {
    public static let shared = CPlusPlusClassIndexStore(symbolStore: .shared)

    private let cache = SharedCache<Storage>(evictionGroup: .cPlusPlusClassStore)

    /// Where slot implementations and typeinfos find their C++ symbols.
    private let symbolStore: CPlusPlusSymbolIndexStore

    private let locators = LocatorCache()

    /// A store of its own — for tests; everything else uses ``shared``.
    init(symbolStore: CPlusPlusSymbolIndexStore) {
        self.symbolStore = symbolStore
    }

    /// Every class with a typeinfo in the image, ascending by qualified name.
    public func classes(in machO: some MachORepresentableWithCache) -> [CPlusPlusClass] {
        storage(in: machO)?.classes.map(\.value) ?? []
    }

    /// The class named `qualifiedName`; the one with the lowest typeinfo
    /// offset when hidden classes of several translation units share it.
    public func `class`(named qualifiedName: String, in machO: some MachORepresentableWithCache) -> CPlusPlusClass? {
        guard let storage = storage(in: machO), let classIndex = storage.classIndexByQualifiedName[qualifiedName] else { return nil }
        return storage.classes[classIndex].value
    }

    /// The class whose typeinfo sits at `offset`.
    public func `class`(atTypeInfoOffset offset: Int, in machO: some MachORepresentableWithCache) -> CPlusPlusClass? {
        guard let storage = storage(in: machO), let classIndex = storage.classIndexByTypeInfoOffset[offset] else { return nil }
        return storage.classes[classIndex].value
    }

    /// The classes of the image whose direct bases include `baseClass`,
    /// ascending by qualified name.
    public func derivedClasses(of baseClass: CPlusPlusClass, in machO: some MachORepresentableWithCache) -> [CPlusPlusClass] {
        guard let storage = storage(in: machO), let classIndex = storage.classIndexByTypeInfoOffset[baseClass.typeInfoOffset] else { return [] }
        return storage.derivedClassIndices[classIndex].map { storage.classes[$0].value }
    }

    /// The class's vtables, primary first, each slot named. Bases in other
    /// images are read from the process for an image of the process, from
    /// the same cache for an image of a dyld shared cache, and for a
    /// standalone file from the paths inferred from where it sits plus this
    /// Mac's dyld shared cache.
    public func virtualTables(of polymorphicClass: CPlusPlusClass, in machO: some MachORepresentableWithCache) -> [CPlusPlusVirtualTable] {
        guard let image = IndexedImage(machO) else { return [] }
        return virtualTables(of: polymorphicClass, in: image, locator: locators.locator(for: image, dependencySearchPaths: nil))
    }

    /// The class's vtables, each slot named, reading bases of other images
    /// through `dependencySearchPaths` — the way to reach `@rpath` siblings
    /// of a standalone file.
    public func virtualTables(of polymorphicClass: CPlusPlusClass, in machO: MachOFile, dependencySearchPaths: [DependencySearchPath]) -> [CPlusPlusVirtualTable] {
        let image = IndexedImage.file(machO)
        return virtualTables(of: polymorphicClass, in: image, locator: locators.locator(for: image, dependencySearchPaths: dependencySearchPaths))
    }

    /// Builds the image's index now instead of on first use.
    public func prepare(in machO: some MachORepresentableWithCache) {
        _ = storage(in: machO)
    }

    /// Whether the image's index is built.
    public func contains(in machO: some MachORepresentableWithCache) -> Bool {
        cache.contains(in: machO)
    }

    /// Drops the image's index; the next query builds it again.
    public func remove(for machO: some MachORepresentableWithCache) {
        cache.remove(for: machO)
    }

    func storage(in machO: some MachORepresentableWithCache) -> Storage? {
        cache.storage(in: machO) { machO in
            IndexedImage(machO).map { Storage(image: $0, symbolStore: symbolStore) }
        }
    }

    func virtualTables(of polymorphicClass: CPlusPlusClass, in image: IndexedImage, locator: BaseClassLocator) -> [CPlusPlusVirtualTable] {
        let resolver = ClassResolver(store: self, symbolStore: symbolStore, locator: locator)
        let root = ClassHandle(image: image, typeInfoOffset: polymorphicClass.typeInfoOffset)
        guard let record = resolver.record(of: root) else { return [] }
        let naming = VirtualFunctionNaming<ClassHandle>(
            primaryBase: resolver.primaryBase(of:),
            className: resolver.className(of:),
            primarySlots: resolver.primarySlots(of:)
        )
        let subobjects = resolver.subobjects(of: root)
        let primaryBase = resolver.primaryBase(of: root)
        return record.virtualTables.map { table in
            let subobject = table.offsetToTop == 0 ? nil : subobjects.first { $0.offset == -table.offsetToTop }
            let namingBase = table.offsetToTop == 0 ? primaryBase : subobject?.handle
            let functions = table.slots.enumerated().map { slotIndex, slot in
                let described = resolver.describe(slot, in: image)
                return CPlusPlusVirtualFunction(
                    slotIndex: slotIndex,
                    implementation: CPlusPlusVirtualFunction.Implementation(slot),
                    symbolName: described.name,
                    baseFunction: namingBase.flatMap { naming.baseFunction(forSlotAt: slotIndex, implementedBy: described.identity, startingAt: $0) }
                )
            }
            return CPlusPlusVirtualTable(
                addressPointOffset: table.addressPointOffset,
                offsetToTop: table.offsetToTop,
                subobjectClassName: subobject?.className,
                functions: functions
            )
        }
    }
}

extension CPlusPlusVirtualFunction.Implementation {
    fileprivate init(_ slot: VirtualSlotRecord) {
        self = switch slot {
        case .function(let offset): .function(offset: offset)
        case .imported(let symbolName, let installName): .imported(symbolName: symbolName, installName: installName)
        case .otherImage(let address): .otherImage(address: address)
        case .pureVirtual: .pureVirtual
        case .deletedVirtual: .deletedVirtual
        }
    }
}

// MARK: - Storage

extension CPlusPlusClassIndexStore {
    /// One image's index.
    final class Storage: Sendable {
        struct BaseEntry: Sendable {
            let reference: TypeInfoReference
            let isVirtual: Bool
            let offset: Int
        }

        struct ClassRecord: Sendable {
            let value: CPlusPlusClass
            let bases: [BaseEntry]
            /// The class's own group of tables, primary first; empty when it
            /// has none.
            let virtualTables: [VirtualTableRecord]
        }

        /// Ascending by qualified name, then typeinfo offset.
        let classes: [ClassRecord]
        let classIndexByQualifiedName: [String: Int]
        let classIndexByTypeInfoOffset: [Int: Int]
        /// For each class, the classes of the image deriving directly from it.
        let derivedClassIndices: [[Int]]

        init(image: IndexedImage, symbolStore: CPlusPlusSymbolIndexStore) {
            let machO = image.representable
            let slots = ImagePointerSlots(image: image)
            let locator = BaseClassLocator(root: image, dependencySearchPaths: [])
            let cacheImageLocator: CacheImageLocator? = if case .file(let file) = image, file.cache != nil {
                CacheImageLocator(cacheOf: file)
            } else {
                nil
            }
            let markers = RuntimeLibraryMarkers(for: image, cacheImageLocator: cacheImageLocator)
            let typeInfos = TypeInfoScanner.scan(slots, markers: markers)
            let tableScanner = VirtualTableScanner(slots: slots, markers: markers) { address in
                locator.isCode(address, from: image)
            }
            let groupsByTypeInfo = tableScanner.scan(typeInfos: typeInfos)

            let demangler = CPlusPlusDemangler()
            var mangledNamesByLocalOffset: [Int: String] = [:]
            for typeInfo in typeInfos {
                mangledNamesByLocalOffset[typeInfo.offset] = typeInfo.mangledTypeName
            }
            var mangledNamesByExternalReference: [TypeInfoReference: String] = [:]
            func mangledName(of reference: TypeInfoReference) -> String? {
                switch reference {
                case .local(let offset):
                    if let known = mangledNamesByLocalOffset[offset] {
                        return known
                    }
                    guard case .internalPointer(let nameOffset, _) = slots.content(atOffset: offset + 8) else { return nil }
                    return slots.string(atOffset: nameOffset)
                case .boundSymbol(let name, _):
                    return String(name.dropFirst("__ZTI".count))
                case .address:
                    if let known = mangledNamesByExternalReference[reference] {
                        return known
                    }
                    guard let (other, offset) = locator.locate(reference, from: image) else { return nil }
                    let otherSlots = ImagePointerSlots(image: other)
                    guard case .internalPointer(let nameOffset, _) = otherSlots.content(atOffset: offset + 8),
                          let name = otherSlots.string(atOffset: nameOffset) else {
                        return nil
                    }
                    mangledNamesByExternalReference[reference] = name
                    return name
                }
            }
            func location(of reference: TypeInfoReference) -> CPlusPlusClass.Location {
                switch reference {
                case .local(let offset):
                    .sameImage(typeInfoOffset: offset)
                case .boundSymbol(_, let installName):
                    .otherImage(installName: installName)
                case .address:
                    .otherImage(installName: locator.locate(reference, from: image)?.image.imagePath)
                }
            }

            var records: [ClassRecord] = []
            records.reserveCapacity(typeInfos.count)
            for typeInfo in typeInfos {
                let names = Self.names(ofMangledTypeName: typeInfo.mangledTypeName, using: demangler)
                var bases: [CPlusPlusClass.Base] = []
                var baseEntries: [BaseEntry] = []
                for base in typeInfo.bases {
                    let baseMangledName = mangledName(of: base.reference) ?? ""
                    let isVirtual = base.offsetFlags & 0x1 != 0
                    let offset = Int(base.offsetFlags >> 8)
                    bases.append(CPlusPlusClass.Base(
                        qualifiedName: baseMangledName.isEmpty ? "" : Self.names(ofMangledTypeName: baseMangledName, using: demangler).qualifiedName,
                        mangledTypeName: baseMangledName,
                        isVirtual: isVirtual,
                        isPublic: base.offsetFlags & 0x2 != 0,
                        offset: offset,
                        location: location(of: base.reference)
                    ))
                    baseEntries.append(BaseEntry(reference: base.reference, isVirtual: isVirtual, offset: offset))
                }
                let groups = groupsByTypeInfo[typeInfo.offset] ?? []
                let virtualTables = Self.ownGroup(among: groups, virtualTableSymbolOffset: symbolStore.symbol(named: "__ZTV" + typeInfo.mangledTypeName, in: machO)?.offset)
                let hasTypeInfoSymbol = symbolStore.symbols(for: typeInfo.offset, in: machO).contains { $0.name.kind == .typeInfo }
                let value = CPlusPlusClass(
                    qualifiedName: names.qualifiedName,
                    scopePath: names.scopePath,
                    baseName: names.baseName,
                    mangledTypeName: typeInfo.mangledTypeName,
                    typeInfoOffset: typeInfo.offset,
                    bases: bases,
                    inheritanceShape: CPlusPlusClass.InheritanceShape(rawValue: typeInfo.inheritanceFlags & 0x3),
                    hasVirtualTable: !virtualTables.isEmpty,
                    hasTypeInfoSymbol: hasTypeInfoSymbol,
                    hasUniqueTypeInfo: typeInfo.hasUniqueName
                )
                records.append(ClassRecord(value: value, bases: baseEntries, virtualTables: virtualTables))
            }
            records.sort { ($0.value.qualifiedName, $0.value.typeInfoOffset) < ($1.value.qualifiedName, $1.value.typeInfoOffset) }

            var classIndexByQualifiedName: [String: Int] = [:]
            var classIndexByTypeInfoOffset: [Int: Int] = [:]
            for (classIndex, record) in records.enumerated() {
                if classIndexByQualifiedName[record.value.qualifiedName] == nil {
                    classIndexByQualifiedName[record.value.qualifiedName] = classIndex
                }
                classIndexByTypeInfoOffset[record.value.typeInfoOffset] = classIndex
            }
            var derivedClassIndices = Array(repeating: [Int](), count: records.count)
            for (classIndex, record) in records.enumerated() {
                for base in record.bases {
                    if case .local(let offset) = base.reference, let baseIndex = classIndexByTypeInfoOffset[offset], !derivedClassIndices[baseIndex].contains(classIndex) {
                        derivedClassIndices[baseIndex].append(classIndex)
                    }
                }
            }
            self.classes = records
            self.classIndexByQualifiedName = classIndexByQualifiedName
            self.classIndexByTypeInfoOffset = classIndexByTypeInfoOffset
            self.derivedClassIndices = derivedClassIndices
        }

        func record(atTypeInfoOffset offset: Int) -> ClassRecord? {
            classIndexByTypeInfoOffset[offset].map { classes[$0] }
        }

        /// The qualified name, scope path and base name of a type, from its
        /// typeinfo name; the mangling itself when the demangler does not
        /// parse it.
        static func names(ofMangledTypeName mangledTypeName: String, using demangler: CPlusPlusDemangler) -> (qualifiedName: String, scopePath: [String], baseName: String) {
            let parsed = demangler.withParsedName("__ZTS" + mangledTypeName) { parsedName -> (scopePath: [String], baseName: String)? in
                guard parsedName.kind == .typeInfoName, parsedName.scopeComponentCount > 0 else { return nil }
                return (parsedName.scopePath, parsedName.baseName)
            }
            guard let parsed = parsed ?? nil else {
                return (mangledTypeName, [mangledTypeName], mangledTypeName)
            }
            return (parsed.scopePath.joined(separator: "::"), parsed.scopePath, parsed.baseName)
        }

        /// The group of tables that is the class's own: the one at its
        /// `__ZTV` symbol when there is one, else the first. The others are
        /// construction vtables of classes deriving from it.
        static func ownGroup(among groups: [[VirtualTableRecord]], virtualTableSymbolOffset: Int?) -> [VirtualTableRecord] {
            if let virtualTableSymbolOffset,
               let group = groups.first(where: { ($0.first?.addressPointOffset ?? .min) - 16 >= virtualTableSymbolOffset }) {
                return group
            }
            return groups.first ?? []
        }
    }
}

// MARK: - Query-time resolution

/// A class of some image, by its typeinfo.
struct ClassHandle: Hashable {
    let image: IndexedImage
    let typeInfoOffset: Int

    static func == (lhs: ClassHandle, rhs: ClassHandle) -> Bool {
        lhs.image.key == rhs.image.key && lhs.typeInfoOffset == rhs.typeInfoOffset
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(image.key)
        hasher.combine(typeInfoOffset)
    }
}

/// Reads the classes a query walks through, across images, remembering what
/// it read for the length of the query.
final class ClassResolver {
    private let store: CPlusPlusClassIndexStore
    private let symbolStore: CPlusPlusSymbolIndexStore
    private let locator: BaseClassLocator
    private var primarySlotsByClass: [ClassHandle: [VirtualFunctionNaming<ClassHandle>.Slot]?] = [:]
    private var primaryBasesByClass: [ClassHandle: ClassHandle?] = [:]

    init(store: CPlusPlusClassIndexStore, symbolStore: CPlusPlusSymbolIndexStore, locator: BaseClassLocator) {
        self.store = store
        self.symbolStore = symbolStore
        self.locator = locator
    }

    func record(of handle: ClassHandle) -> CPlusPlusClassIndexStore.Storage.ClassRecord? {
        store.storage(in: handle.image.representable)?.record(atTypeInfoOffset: handle.typeInfoOffset)
    }

    func className(of handle: ClassHandle) -> String {
        record(of: handle)?.value.qualifiedName ?? ""
    }

    /// The primary base, by the Itanium ABI's layout rules: the first
    /// non-virtual base at offset zero that has a vtable; failing that, a
    /// virtual base the class's own table places at offset zero — a nearly
    /// empty virtual base, which shares the class's virtual pointer.
    func primaryBase(of handle: ClassHandle) -> ClassHandle? {
        if let known = primaryBasesByClass[handle] {
            return known
        }
        let record = record(of: handle)
        var primaryBase: ClassHandle?
        var firstCandidate: ClassHandle?
        for base in record?.bases ?? [] where !base.isVirtual && base.offset == 0 {
            guard let (image, offset) = locator.locate(base.reference, from: handle.image) else { continue }
            let candidate = ClassHandle(image: image, typeInfoOffset: offset)
            firstCandidate = firstCandidate ?? candidate
            if self.record(of: candidate)?.virtualTables.isEmpty == false {
                primaryBase = candidate
                break
            }
        }
        if primaryBase == nil, firstCandidate == nil, let primaryTable = record?.virtualTables.first(where: { $0.offsetToTop == 0 }) {
            for base in record?.bases ?? [] where base.isVirtual {
                guard handle.image.word(atOffset: primaryTable.addressPointOffset + base.offset) == 0,
                      let (image, offset) = locator.locate(base.reference, from: handle.image) else {
                    continue
                }
                primaryBase = ClassHandle(image: image, typeInfoOffset: offset)
                break
            }
        }
        let result = primaryBase ?? firstCandidate
        primaryBasesByClass.updateValue(result, forKey: handle)
        return result
    }

    func primarySlots(of handle: ClassHandle) -> [VirtualFunctionNaming<ClassHandle>.Slot]? {
        if let known = primarySlotsByClass[handle] {
            return known
        }
        let slots = record(of: handle)?.virtualTables.first { $0.offsetToTop == 0 }?.slots.map { describe($0, in: handle.image) }
        primarySlotsByClass.updateValue(slots, forKey: handle)
        return slots
    }

    /// The name and identity of what a slot of `image` holds.
    func describe(_ slot: VirtualSlotRecord, in image: IndexedImage) -> VirtualFunctionNaming<ClassHandle>.Slot {
        switch slot {
        case .function(let offset):
            let symbol = functionSymbol(at: offset, in: image)
            return .init(name: symbol?.name, identity: ImplementationIdentity(location: location(ofFunctionAt: offset, in: image), mangledName: symbol?.symbol.name))
        case .imported(let symbolName, _):
            return .init(name: CPlusPlusSymbolName(mangledName: symbolName), identity: ImplementationIdentity(location: nil, mangledName: symbolName))
        case .otherImage(let address):
            let symbol = locator.image(containing: address, from: image).flatMap { functionSymbol(at: $0.offset, in: $0.image) }
            return .init(name: symbol?.name, identity: ImplementationIdentity(location: .absolute(address), mangledName: symbol?.symbol.name))
        case .pureVirtual:
            return .init(name: nil, identity: ImplementationIdentity(location: .pureVirtual, mangledName: nil))
        case .deletedVirtual:
            return .init(name: nil, identity: ImplementationIdentity(location: .deletedVirtual, mangledName: nil))
        }
    }

    /// Every base subobject of `handle`'s class with its offset in the
    /// class, outermost first: the direct bases and, after each, its own
    /// bases. A virtual base's offset is read from the class's own primary
    /// table; virtual bases of its bases are left out.
    func subobjects(of handle: ClassHandle) -> [(offset: Int, className: String, handle: ClassHandle?)] {
        subobjects(of: handle, at: 0, depth: 0, rootPrimaryTable: record(of: handle)?.virtualTables.first { $0.offsetToTop == 0 })
    }

    private func subobjects(of handle: ClassHandle, at classOffset: Int, depth: Int, rootPrimaryTable: VirtualTableRecord?) -> [(offset: Int, className: String, handle: ClassHandle?)] {
        guard depth < 16, let record = record(of: handle) else { return [] }
        var result: [(offset: Int, className: String, handle: ClassHandle?)] = []
        for (baseIndex, base) in record.bases.enumerated() {
            let baseHandle = locator.locate(base.reference, from: handle.image).map { ClassHandle(image: $0.image, typeInfoOffset: $0.offset) }
            let subobjectOffset: Int
            if base.isVirtual {
                guard depth == 0, let rootPrimaryTable,
                      let virtualBaseOffset = handle.image.word(atOffset: rootPrimaryTable.addressPointOffset + base.offset) else {
                    continue
                }
                subobjectOffset = Int(virtualBaseOffset)
            } else {
                subobjectOffset = classOffset + base.offset
            }
            result.append((subobjectOffset, record.value.bases[baseIndex].qualifiedName, baseHandle))
            if let baseHandle {
                result += subobjects(of: baseHandle, at: subobjectOffset, depth: depth + 1, rootPrimaryTable: rootPrimaryTable)
            }
        }
        return result
    }

    private func functionSymbol(at offset: Int, in image: IndexedImage) -> CPlusPlusSymbol? {
        let symbols = symbolStore.symbols(for: offset, in: image.representable)
        return symbols.first { $0.name.kind != .variable && $0.name.kind != .guardVariable } ?? symbols.first
    }

    private func location(ofFunctionAt offset: Int, in image: IndexedImage) -> ImplementationIdentity.Location {
        switch image {
        case .file(let file):
            if let cache = file.cache {
                return .absolute(UInt64(offset) + UInt64(cache.mainCacheHeader.sharedRegionStart))
            }
            return .local(imagePath: file.imagePath, offset: offset)
        case .process(let processImage):
            return .absolute(UInt64(UInt(bitPattern: processImage.ptr)) + UInt64(offset))
        }
    }
}

extension IndexedImage {
    /// The 8 bytes at `offset`, as stored.
    func word(atOffset offset: Int) -> Int64? {
        switch self {
        case .file(let file):
            try? file.readElement(offset: offset) as Int64
        case .process(let processImage):
            processImage.ptr.loadUnaligned(fromByteOffset: offset, as: Int64.self)
        }
    }
}

/// The locators of a store, one per image and set of search paths, so that
/// a query does not locate the same libraries again.
final class LocatorCache: @unchecked Sendable {
    private struct Key: Hashable {
        let imageKey: AnyHashable
        let dependencySearchPaths: [DependencySearchPath]?
    }

    private let lock = NSLock()
    private var locatorsByKey: [Key: BaseClassLocator] = [:]

    func locator(for image: IndexedImage, dependencySearchPaths: [DependencySearchPath]?) -> BaseClassLocator {
        let key = Key(imageKey: image.key, dependencySearchPaths: dependencySearchPaths)
        lock.lock()
        defer { lock.unlock() }
        if let existing = locatorsByKey[key] {
            return existing
        }
        let created = BaseClassLocator(root: image, dependencySearchPaths: dependencySearchPaths)
        locatorsByKey[key] = created
        return created
    }
}
