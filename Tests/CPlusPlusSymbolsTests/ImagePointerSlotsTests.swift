import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import MachOReading
@testable import CPlusPlusSymbols

/// Reading the pointers of an image's data three ways, checked against the
/// pointers dyld wrote into this process.
@Suite
struct ImagePointerSlotsTests {
    /// The sections dyld writes only while loading — `__DATA_CONST` and
    /// `__AUTH_CONST` — as offsets the indexes use. The other data sections
    /// may change after loading, so the process need not hold what the file
    /// does.
    private static func constantDataRanges(of file: MachOFile) -> [Range<Int>] {
        let sharedRegionStart = file.cache.map { Int($0.mainCacheHeader.sharedRegionStart) }
        return file.sections.filter { $0.segmentName == "__DATA_CONST" || $0.segmentName == "__AUTH_CONST" }.map { section in
            let start = sharedRegionStart.map { section.address - $0 } ?? section.offset
            return start ..< start + section.size
        }
    }

    /// Every pointer of the fixture image's data, read from its file, is the
    /// pointer this process holds at the same place: a rebase points to the
    /// same offset, a bind to the symbol dyld bound.
    @Test func fileSlotsMatchTheProcessForEveryDataPointerOfTheFixtureImage() throws {
        let image = try ClassIndexTestImages.fixtureImage()
        let file = try ClassIndexTestImages.fixtureFile()
        let processSlots = ImagePointerSlots(image: .process(image))
        let fileSlots = ImagePointerSlots(image: .file(file))
        #expect(processSlots.dataSectionRanges == fileSlots.dataSectionRanges)
        let constantRanges = Self.constantDataRanges(of: file)
        var comparedCount = 0
        var mismatches: [String] = []
        fileSlots.forEachDataSlot { offset, content in
            guard constantRanges.contains(where: { $0.contains(offset) }) else { return }
            comparedCount += 1
            let processContent = processSlots.content(atOffset: offset)
            switch content {
            case .internalPointer(let target, _):
                guard case .internalPointer(target, _)? = processContent else {
                    mismatches.append("\(offset): file \(content), process \(String(describing: processContent))")
                    return
                }
            case .boundSymbol(let name, let addend, _):
                guard case .externalAddress(let address)? = processContent else {
                    mismatches.append("\(offset): file \(content), process \(String(describing: processContent))")
                    return
                }
                // dyld bound the slot to the address the symbol has here.
                guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), String(name.dropFirst())),
                      UInt64(UInt(bitPattern: symbol)) & UInt64(InProcessContext.addressMask) == address &- UInt64(addend) else {
                    mismatches.append("\(offset): bound \(name)+\(addend), process holds \(address)")
                    return
                }
            case .externalAddress:
                mismatches.append("\(offset): a standalone file holds an address")
            }
        }
        #expect(comparedCount > 100)
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(comparedCount) differ: \(mismatches.prefix(5))")
    }

    /// The same for JavaScriptCore read out of this Mac's dyld shared cache:
    /// the cache's unslid pointers, moved by the slide, are the process's.
    @Test func cacheSlotsMatchTheProcessForEveryDataPointerOfJavaScriptCore() throws {
        let path = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore"
        let hostCache = try #require(FullDyldCache.cachedHost)
        let file = try #require(hostCache.machOFile(by: .path(path)))
        try #require(dlopen(path, RTLD_NOW) != nil)
        let image = try #require(MachOImage(name: "JavaScriptCore"))
        let sharedRegionStart = UInt64(hostCache.mainCacheHeader.sharedRegionStart)
        let unslidTextAddress = UInt64(try #require(file.segments.first { $0.segmentName == "__TEXT" }).virtualMemoryAddress)
        let headerAddress = UInt64(UInt(bitPattern: image.ptr))
        let slide = headerAddress &- unslidTextAddress
        // A cache offset is the unslid address minus the shared region's
        // start; a process offset is from the header.
        let processOffsetDelta = Int(unslidTextAddress - sharedRegionStart)

        let processSlots = ImagePointerSlots(image: .process(image))
        let fileSlots = ImagePointerSlots(image: .file(file))
        let constantRanges = Self.constantDataRanges(of: file)
        var comparedCount = 0
        var mismatches: [String] = []
        fileSlots.forEachDataSlot { offset, content in
            guard constantRanges.contains(where: { $0.contains(offset) }) else { return }
            // Only the words that are pointers in this process: a cache file
            // cannot tell every other word from a pointer.
            let processContent = processSlots.content(atOffset: offset - processOffsetDelta)
            switch processContent {
            case .internalPointer?:
                break
            case .externalAddress(let address)?:
                var information = Dl_info()
                guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)), dladdr(pointer, &information) != 0 else { return }
            default:
                return
            }
            comparedCount += 1
            switch content {
            case .internalPointer(let target, _):
                guard case .internalPointer(let processTarget, _)? = processContent, processTarget == target - processOffsetDelta else {
                    mismatches.append("\(offset): cache \(content), process \(String(describing: processContent))")
                    return
                }
            case .externalAddress(let address):
                guard case .externalAddress(let processAddress)? = processContent, processAddress == address &+ slide else {
                    mismatches.append("\(offset): cache \(content), process \(String(describing: processContent))")
                    return
                }
            case .boundSymbol:
                mismatches.append("\(offset): a cache file holds a bind")
            }
        }
        #expect(comparedCount > 1000)
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(comparedCount) differ: \(mismatches.prefix(5))")
    }

    /// `std::exception` of libc++abi, read out of this Mac's dyld shared
    /// cache and from this process, gives the same table.
    @Test func libraryClassOfTheCacheReadsLikeTheProcess() throws {
        let hostCache = try #require(FullDyldCache.cachedHost)
        let file = try #require(hostCache.machOFile(by: .path("/usr/lib/libc++abi.dylib")))
        let image = try #require(MachOImage(name: "libc++abi"))
        let store = CPlusPlusClassIndexStore(symbolStore: .shared)
        for machO in [file as any MachORepresentableWithCache, image] {
            let classes = store.classes(in: machO)
            let exception = try #require(classes.first { $0.qualifiedName == "std::exception" }, "\(classes.count) classes, no std::exception")
            #expect(exception.hasVirtualTable)
            let tables = store.virtualTables(of: exception, in: machO)
            #expect(tables.map { $0.functions.map { $0.name?.baseName } } == [["~exception", "~exception", "what"]])
        }
    }

    @Test func aBindSlotNamesItsSymbolAndLibrary() throws {
        let built = try ClassHierarchyLibraries.built()
        for url in [built.derivedURL, built.legacyDerivedURL] {
            let slots = ImagePointerSlots(image: .file(try ClassIndexTestImages.hostSlice(of: url)))
            var boundNames: [String: String?] = [:]
            slots.forEachDataSlot { _, content in
                if case .boundSymbol(let name, _, let installName) = content {
                    boundNames[name] = installName
                }
            }
            #expect(boundNames["__ZNK7library4Base6secondEv"] == .some("@rpath/libClassHierarchyBase.dylib"), "\(url.lastPathComponent)")
            #expect(boundNames["__ZTIN7library4BaseE"] == .some("@rpath/libClassHierarchyBase.dylib"), "\(url.lastPathComponent)")
        }
    }

    @Test func aWordThatIsNoPointerHasNoContent() throws {
        let file = try ClassIndexTestImages.fixtureFile()
        let image = try ClassIndexTestImages.fixtureImage()
        let left = try #require(CPlusPlusClassIndexStore.shared.class(named: "hierarchy::Left", in: file))
        let table = try #require(CPlusPlusClassIndexStore.shared.virtualTables(of: left, in: file).first)
        // The offset-to-top before the RTTI slot.
        let offsetToTopOffset = table.addressPointOffset - 16
        for slots in [ImagePointerSlots(image: .file(file)), ImagePointerSlots(image: .process(image))] {
            #expect(slots.content(atOffset: offsetToTopOffset) == nil)
            #expect(slots.holdsSmallInteger(atOffset: offsetToTopOffset))
            #expect(slots.word(atOffset: offsetToTopOffset) == 0)
        }
    }
}
