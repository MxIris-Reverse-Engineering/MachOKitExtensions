import Foundation
import MachOKit
import MachOKitExtensions
import MachOReading
@_spi(Internals) import MachOAddressResolution

/// How an image refers to the few libc++abi objects the class index looks
/// for: the vtables of the three class `type_info` kinds, which a typeinfo's
/// virtual pointer points into, and the two functions a vtable slot holds
/// for a pure virtual and a deleted virtual function.
///
/// A standalone file names them through its binds. A file out of a dyld
/// shared cache and an image of this process hold their addresses, found
/// once from libc++abi's exports.
struct RuntimeLibraryMarkers {
    enum ClassTypeInfoKind: Sendable {
        /// `__cxxabiv1::__class_type_info`: no base.
        case noBase
        /// `__cxxabiv1::__si_class_type_info`: one public, non-virtual base
        /// at offset zero.
        case singleBase
        /// `__cxxabiv1::__vmi_class_type_info`: any other bases.
        case multipleOrVirtualBases
    }

    enum MarkedFunction: Sendable {
        case pureVirtual
        case deletedVirtual
    }

    static let classTypeInfoVirtualTableNames: [String: ClassTypeInfoKind] = [
        "__ZTVN10__cxxabiv117__class_type_infoE": .noBase,
        "__ZTVN10__cxxabiv120__si_class_type_infoE": .singleBase,
        "__ZTVN10__cxxabiv121__vmi_class_type_infoE": .multipleOrVirtualBases,
    ]

    static let markedFunctionNames: [String: MarkedFunction] = [
        "___cxa_pure_virtual": .pureVirtual,
        "___cxa_deleted_virtual": .deletedVirtual,
    ]

    /// A typeinfo's virtual pointer points past the vtable's offset-to-top
    /// and RTTI slots.
    static let virtualPointerAddend = 16

    /// The addresses (virtual pointer values) of the three kinds, when the
    /// image holds addresses.
    private var kindsByVirtualPointerAddress: [UInt64: ClassTypeInfoKind] = [:]
    private var markedFunctionsByAddress: [UInt64: MarkedFunction] = [:]
    /// The same, as offsets into the image itself, when the image is
    /// libc++abi.
    private var kindsByInternalVirtualPointerOffset: [Int: ClassTypeInfoKind] = [:]
    private var markedFunctionsByInternalOffset: [Int: MarkedFunction] = [:]

    static let libraryInstallName = "/usr/lib/libc++abi.dylib"

    /// Finds the markers for `image`. A cache file finds libc++abi in the
    /// same cache.
    init(for image: IndexedImage, cacheImageLocator: CacheImageLocator?) {
        let ownExports = Self.exportedAddresses(in: image)
        for (name, kind) in Self.classTypeInfoVirtualTableNames {
            if let offset = ownExports.offsetsByName[name] {
                kindsByInternalVirtualPointerOffset[offset + Self.virtualPointerAddend] = kind
            }
        }
        for (name, function) in Self.markedFunctionNames {
            if let offset = ownExports.offsetsByName[name] {
                markedFunctionsByInternalOffset[offset] = function
            }
        }
        switch image {
        case .file(let file):
            guard let cache = file.cache, let cacheImageLocator else { return }
            let mainCache = cache.mainCache ?? cache
            guard let libraryInformation = mainCache.imageInfos?.first(where: { $0.path(in: mainCache) == Self.libraryInstallName }),
                  let library = cacheImageLocator.image(containing: UInt64(libraryInformation.layout.address)) else {
                return
            }
            let exports = Self.exportedAddresses(in: .file(library))
            for (name, kind) in Self.classTypeInfoVirtualTableNames {
                if let address = exports.addressesByName[name] {
                    kindsByVirtualPointerAddress[address + UInt64(Self.virtualPointerAddend)] = kind
                }
            }
            for (name, function) in Self.markedFunctionNames {
                if let address = exports.addressesByName[name] {
                    markedFunctionsByAddress[address] = function
                }
            }
        case .process:
            #if canImport(Darwin)
            let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
            for (name, kind) in Self.classTypeInfoVirtualTableNames {
                if let symbol = dlsym(defaultHandle, String(name.dropFirst())) {
                    let address = UInt64(UInt(bitPattern: symbol)) & UInt64(InProcessContext.addressMask)
                    kindsByVirtualPointerAddress[address + UInt64(Self.virtualPointerAddend)] = kind
                }
            }
            for (name, function) in Self.markedFunctionNames {
                if let symbol = dlsym(defaultHandle, String(name.dropFirst())) {
                    markedFunctionsByAddress[UInt64(UInt(bitPattern: symbol)) & UInt64(InProcessContext.addressMask)] = function
                }
            }
            #endif
        }
    }

    /// The class typeinfo kind a typeinfo's first slot marks; `nil` when the
    /// slot is no class typeinfo's virtual pointer.
    func classTypeInfoKind(ofVirtualPointer content: ImagePointerSlots.Content) -> ClassTypeInfoKind? {
        switch content {
        case .boundSymbol(let name, let addend, _):
            guard addend == Self.virtualPointerAddend else { return nil }
            return Self.classTypeInfoVirtualTableNames[name]
        case .externalAddress(let address):
            return kindsByVirtualPointerAddress[address]
        case .internalPointer(let offset, _):
            return kindsByInternalVirtualPointerOffset[offset]
        }
    }

    /// Whether a vtable slot holds `__cxa_pure_virtual` or
    /// `__cxa_deleted_virtual`.
    func markedFunction(in content: ImagePointerSlots.Content) -> MarkedFunction? {
        switch content {
        case .boundSymbol(let name, _, _):
            return Self.markedFunctionNames[name]
        case .externalAddress(let address):
            return markedFunctionsByAddress[address]
        case .internalPointer(let offset, _):
            return markedFunctionsByInternalOffset[offset]
        }
    }

    /// The exports of `image` among the names this type looks for, as
    /// offsets the indexes use and as addresses.
    private static func exportedAddresses(in image: IndexedImage) -> (offsetsByName: [String: Int], addressesByName: [String: UInt64]) {
        guard case .file(let file) = image else {
            #if canImport(Darwin)
            if case .process(let processImage) = image {
                return exportedAddresses(inProcessImage: processImage)
            }
            #endif
            return ([:], [:])
        }
        guard let exportTrie = file.cached.exportTrie else { return ([:], [:]) }
        let addressSpace = ImageAddressSpace(of: file)
        var offsetsByName: [String: Int] = [:]
        var addressesByName: [String: UInt64] = [:]
        for name in Array(classTypeInfoVirtualTableNames.keys) + Array(markedFunctionNames.keys) {
            guard let exported = exportTrie.search(by: name), !exported.flags.contains(.reexport),
                  let headerOffset = exported.offset,
                  let address = addressSpace.address(forExportedSymbolOffset: headerOffset),
                  let offset = addressSpace.offset(forAddress: address) else {
                continue
            }
            offsetsByName[name] = offset
            addressesByName[name] = address
        }
        return (offsetsByName, addressesByName)
    }

    #if canImport(Darwin)
    private static func exportedAddresses(inProcessImage image: MachOImage) -> (offsetsByName: [String: Int], addressesByName: [String: UInt64]) {
        guard let exportTrie = image.exportTrie else { return ([:], [:]) }
        let headerAddress = UInt64(UInt(bitPattern: image.ptr))
        var offsetsByName: [String: Int] = [:]
        var addressesByName: [String: UInt64] = [:]
        for name in Array(classTypeInfoVirtualTableNames.keys) + Array(markedFunctionNames.keys) {
            guard let exported = exportTrie.search(by: name), !exported.flags.contains(.reexport), let headerOffset = exported.offset else {
                continue
            }
            offsetsByName[name] = headerOffset
            addressesByName[name] = headerAddress + UInt64(headerOffset)
        }
        return (offsetsByName, addressesByName)
    }
    #endif
}
