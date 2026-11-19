import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import MachOReading
@_spi(Internals) import ARM64InstructionDecoding
@_spi(Internals) import MachOAddressResolution

/// The offline resolution of stubs and pointer slots, read from the running
/// system's dyld shared cache file, against what the process itself holds
/// for the same cache: dyld has rebased and bound the process's copy, so it
/// is the answer the decoding must reach.
@Suite(.enabled(if: DyldCacheLoaded.current != nil, "needs an arm64 process with a dyld shared cache"))
struct MachOAddressResolutionTests {
    private static let appKitInstallName = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"

    /// The running system's dyld shared cache, read from its file.
    private static let runningCachePath = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e"

    private func runningCache() throws -> DyldCache {
        try DyldCache(url: URL(fileURLWithPath: Self.runningCachePath))
    }

    private func appKitFile() throws -> MachOFile {
        try #require(runningCache().machOFile(by: .path(Self.appKitInstallName)), "the running system's cache has no AppKit")
    }

    /// How far the process's copy of the shared cache lies from the
    /// addresses its files spell.
    private func cacheSlide() throws -> Int {
        let loadedCache = try #require(DyldCacheLoaded.current)
        return try #require(loadedCache.slide)
    }

    /// The `bl` targets in an image's `__text` that lie outside it, by call
    /// site, the first `limit` of them.
    private func outsideCallSites(in machO: MachOFile, addressSpace: ImageAddressSpace, limit: Int) throws -> [(site: UInt64, target: UInt64)] {
        let text = try #require(machO.sections64.first { $0.segmentName == "__TEXT" && $0.sectionName == "__text" })
        let start = UInt64(text.address)
        let offset = try #require(addressSpace.offset(forAddress: start))
        let words: [UInt32] = try machO.readElements(offset: offset, numberOfElements: min(text.size / 4, 400_000))
        var sites: [(site: UInt64, target: UInt64)] = []
        for (index, word) in words.enumerated() {
            let site = start &+ UInt64(index * 4)
            guard let target = ARM64InstructionWord.callTarget(UInt32(littleEndian: word), at: site), !addressSpace.containsAddress(target) else { continue }
            sites.append((site, target))
            if sites.count >= limit { break }
        }
        return sites
    }

    /// The constant a cache-shared selector stub sets `x1` to, read from the
    /// cache file, is the address of the same selector the process holds
    /// there.
    @Test func stubChainCarriesTheSelectorRegisterConstantOfACacheSharedSelectorStub() throws {
        let machO = try appKitFile()
        let slide = try cacheSlide()
        let addressSpace = ImageAddressSpace(of: machO)
        let resolver = StubChainResolver(machO: machO, addressSpace: addressSpace)

        var compared = 0
        for (_, target) in try outsideCallSites(in: machO, addressSpace: addressSpace, limit: 20000) {
            guard case .registerSettingStub(_, let register, let value, _)? = resolver.hop(at: target),
                  let valueOffset = addressSpace.offset(forAddress: value),
                  let bytes: [UInt8] = try? machO.readElements(offset: valueOffset, numberOfElements: 256),
                  let terminator = bytes.firstIndex(of: 0)
            else { continue }
            #expect(register == 1)
            let selector = String(decoding: bytes[..<terminator], as: UTF8.self)
            let processString = try #require(UnsafePointer<CChar>(bitPattern: Int(bitPattern: UInt(value)) &+ slide))
            #expect(String(cString: processString) == selector, "\(String(target, radix: 16)): the file says \(selector)")
            compared += 1
            if compared >= 50 { break }
        }
        #expect(compared >= 50, "only \(compared) calls through cache-shared selector stubs in AppKit")
    }

    /// iOS 26.3.1, arm64e: a device cache, too large for a `bl` to reach
    /// across its subcaches, so a cross-image call goes through stub islands
    /// the cache builder places between the images.
    private static let archivedIOSCachePath = "/Volumes/DyldSharedCaches/iOS/26.3.1/dyld_shared_cache_arm64e"

    /// Each hop of a chain through stub islands starts where the one before
    /// it ended, and the chain ends at an address that is no trampoline,
    /// inside an image of the cache.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: archivedIOSCachePath), "needs the archived iOS 26.3.1 device cache"))
    func stubChainRecordsEveryStubIslandHop() throws {
        let cache = try DyldCache(url: URL(fileURLWithPath: Self.archivedIOSCachePath))
        let swiftUI = try #require(cache.machOFile(by: .name("SwiftUI")), "the archived cache has no SwiftUI")
        let addressSpace = ImageAddressSpace(of: swiftUI)
        let stubs = StubChainResolver(machO: swiftUI, addressSpace: addressSpace)
        let slots = SlotResolver(machO: swiftUI, addressSpace: addressSpace)
        let locator = try #require(CacheImageLocator(cacheOf: swiftUI))

        var chainsThroughIslands = 0
        for (_, target) in try outsideCallSites(in: swiftUI, addressSpace: addressSpace, limit: 5000) {
            let hops = stubs.hops(from: target, isDestination: { _ in false }, followSlot: { slots.rebaseTarget(ofSlotAt: $0) })
            guard hops.contains(where: { if case .island = $0 { true } else { false } }) else { continue }
            chainsThroughIslands += 1
            var expectedTrampoline = target
            var end: UInt64?
            for hop in hops {
                #expect(hop.trampolineAddress == expectedTrampoline, "\(String(target, radix: 16)): \(hops)")
                switch hop {
                case .island(_, let islandTarget):
                    expectedTrampoline = islandTarget
                    end = islandTarget
                case .slotLoad(_, let slotAddress):
                    end = slots.rebaseTarget(ofSlotAt: slotAddress)
                    if let end { expectedTrampoline = end }
                case .registerSettingStub:
                    end = nil
                }
            }
            if hops.count < StubChainResolver.maximumHops, let end {
                #expect(stubs.hop(at: end) == nil, "\(String(target, radix: 16)) ends on another trampoline")
                #expect(locator.imagePath(containing: end) != nil, "\(String(target, radix: 16)) ends outside every image: \(hops), at \(String(end, radix: 16))")
            }
        }
        #expect(chainsThroughIslands > 100, "only \(chainsThroughIslands) calls of SwiftUI go through stub islands")
    }

    /// Every GOT slot of AppKit decodes to the address dyld put there in
    /// the process, unslid — classes of AppKit's own and other images'
    /// functions alike.
    @Test func slotResolverMatchesTheProcessForEveryGlobalOffsetTableSlotOfAppKit() throws {
        let machO = try appKitFile()
        let slide = try cacheSlide()
        let resolver = SlotResolver(machO: machO)
        let mask = InProcessContext.addressMask

        var compared = 0
        var ownImageTargets = 0
        let appKitAddressSpace = ImageAddressSpace(of: machO)
        for section in machO.sections64 where section.sectionName == "__got" || section.sectionName == "__auth_got" {
            for slotIndex in 0 ..< section.size / 8 {
                let slot = UInt64(section.address) &+ UInt64(slotIndex * 8)
                guard let processSlot = UnsafePointer<UInt>(bitPattern: Int(bitPattern: UInt(slot)) &+ slide) else { continue }
                let processValue = processSlot.pointee
                guard processValue != 0 else { continue }
                let processTarget = UInt64(bitPattern: Int64(Int(bitPattern: processValue & mask) &- slide))
                #expect(resolver.content(ofSlotAt: slot) == .address(processTarget), "slot \(String(slot, radix: 16))")
                if appKitAddressSpace.containsAddress(processTarget) { ownImageTargets += 1 }
                compared += 1
            }
        }
        #expect(compared > 1000)
        #expect(ownImageTargets > 0, "no GOT slot of AppKit holds an address of AppKit itself")
    }

    /// The image that contains an address is the one whose `__TEXT` lies
    /// there.
    @Test func cacheImageLocatorFindsTheImageAnAddressLiesIn() throws {
        let cache = try runningCache()
        let machO = try appKitFile()
        let locator = try #require(CacheImageLocator(cacheOf: machO))
        let textAddress = try #require(machO.segments64.first { $0.segmentName == "__TEXT" }).vmaddr
        #expect(locator.imagePath(containing: UInt64(textAddress) &+ 0x100) == Self.appKitInstallName)
        let libobjc = try #require(cache.machOFile(by: .path("/usr/lib/libobjc.A.dylib")), "the running system's cache has no libobjc")
        let libobjcText = try #require(libobjc.segments64.first { $0.segmentName == "__TEXT" }).vmaddr
        let libobjcImage = try #require(locator.image(containing: UInt64(libobjcText) &+ 0x100))
        #expect(libobjcImage.imagePath == "/usr/lib/libobjc.A.dylib")
    }
}
