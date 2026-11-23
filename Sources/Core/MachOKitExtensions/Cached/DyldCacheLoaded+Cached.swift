import Foundation
import MachOKit
import OSToolbox

extension DyldCacheLoaded {
    /// `DyldCacheLoaded.current`, built once per process; always `nil` where
    /// there is no dyld.
    ///
    /// dyld maps the shared cache at launch and never remaps it, while
    /// `current` rebuilds the value and re-parses the cache header on every
    /// access.
    public static var cachedCurrent: DyldCacheLoaded? {
        #if canImport(Darwin)
        _cachedCurrent
        #else
        nil
        #endif
    }

    #if canImport(Darwin)
    // `DyldCacheLoaded` is not `Sendable` only because it holds a raw pointer.
    // That pointer targets the read-only shared cache mapping, so sharing one
    // value across threads is safe.
    nonisolated(unsafe) private static let _cachedCurrent: DyldCacheLoaded? = current
    #endif
}

extension DyldCacheLoaded {
    /// A concurrency-safe view over this shared cache that memoizes expensive
    /// parsing results.
    ///
    /// Every value for the same mapping shares one cache, which lives for the
    /// rest of the process: a loaded shared cache is never unmapped.
    public var cached: DyldCacheLoadedCached {
        DyldCacheLoadedCached(
            base: self,
            storage: DyldCacheLoadedCacheStorage.storage(for: self)
        )
    }
}

/// A concurrency-safe view over a ``DyldCacheLoaded`` that memoizes expensive
/// parsing results. Obtained through `cache.cached`.
public struct DyldCacheLoadedCached {
    /// The shared cache this view caches.
    public let base: DyldCacheLoaded

    let storage: DyldCacheLoadedCacheStorage
}

extension DyldCacheLoadedCached {
    /// The Objective-C header info at `index` in `headerOptimization`, or `nil`
    /// when `index` is out of range.
    ///
    /// `headerOptimization.headerInfos(in:)` builds the whole list on every
    /// call; this builds it once and indexes into it.
    public func headerInfo<HeaderOptimization: ObjCHeaderOptimizationROProtocol>(
        at index: Int,
        in headerOptimization: HeaderOptimization
    ) -> HeaderOptimization.HeaderInfo? {
        let headerInfos = storage.headerInfos(of: headerOptimization, in: base)
        guard headerInfos.indices.contains(index) else {
            return nil
        }
        return headerInfos[index]
    }
}

/// Backing store for a ``DyldCacheLoadedCached`` view, one per shared cache
/// mapping.
final class DyldCacheLoadedCacheStorage: Sendable {
    private static let registry = Registry()

    static func storage(for cache: DyldCacheLoaded) -> DyldCacheLoadedCacheStorage {
        registry.storage(forCacheAddress: UInt(bitPattern: cache.ptr))
    }

    /// Header info lists, keyed by the header optimization they were read
    /// from. Each value is a `[HeaderOptimization.HeaderInfo]`.
    private let headerInfosByHeaderOptimization = Mutex<[HeaderOptimizationKey: Any]>([:])

    func headerInfos<HeaderOptimization: ObjCHeaderOptimizationROProtocol>(
        of headerOptimization: HeaderOptimization,
        in cache: DyldCacheLoaded
    ) -> [HeaderOptimization.HeaderInfo] {
        let key = HeaderOptimizationKey(
            type: ObjectIdentifier(HeaderOptimization.self),
            offset: headerOptimization.offset
        )
        let cachedHeaderInfos = headerInfosByHeaderOptimization.withLock { headerInfosByHeaderOptimization in
            headerInfosByHeaderOptimization[key] as? [HeaderOptimization.HeaderInfo]
        }
        if let cachedHeaderInfos {
            return cachedHeaderInfos
        }

        let computedHeaderInfos = Array(headerOptimization.headerInfos(in: cache))

        // The header infos are not `Sendable`, and the list goes to every
        // thread that asks for it, which is what this storage is for. The
        // list made outside the lock is stored through `withLockUnchecked`
        // because `withLock` refuses to put a non-`Sendable` value the caller
        // still holds into the guarded state. A stored list is never mutated.
        return headerInfosByHeaderOptimization.withLockUnchecked { headerInfosByHeaderOptimization in
            if let headerInfos = headerInfosByHeaderOptimization[key] as? [HeaderOptimization.HeaderInfo] {
                return headerInfos
            }
            headerInfosByHeaderOptimization[key] = computedHeaderInfos
            return computedHeaderInfos
        }
    }
}

extension DyldCacheLoadedCacheStorage {
    struct HeaderOptimizationKey: Hashable {
        let type: ObjectIdentifier
        let offset: Int
    }

    final class Registry: Sendable {
        private let storagesByCacheAddress = Mutex<[UInt: DyldCacheLoadedCacheStorage]>([:])

        func storage(forCacheAddress cacheAddress: UInt) -> DyldCacheLoadedCacheStorage {
            storagesByCacheAddress.withLock { storagesByCacheAddress in
                if let storage = storagesByCacheAddress[cacheAddress] {
                    return storage
                }
                let storage = DyldCacheLoadedCacheStorage()
                storagesByCacheAddress[cacheAddress] = storage
                return storage
            }
        }
    }
}
