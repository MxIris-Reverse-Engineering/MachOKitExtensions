import Foundation
import MachOKit

extension FullDyldCache {
    /// `FullDyldCache.host`, opened once per process; `nil` where the system
    /// exposes no shared cache file.
    ///
    /// `host` opens and maps every file of the running system's dyld cache —
    /// 82 of them on macOS 27 — each time it is read. A client resolving
    /// dependencies against the system cache for every image it reads kept one
    /// copy per image: an evolution over 51 archived caches held 4,182 of those
    /// files open at once.
    public static var cachedHost: FullDyldCache? {
        _cachedHost
    }

    // The system's shared cache does not change while the process runs, so
    // the value is opened once and kept. `FullDyldCache` fills in its mapping
    // tables and symbol cache on first use, without a lock; they are read here,
    // before the value is shared, so that every later reader only reads them.
    nonisolated(unsafe) private static let _cachedHost: FullDyldCache? = {
        guard let host else { return nil }
        _ = host.mappingInfos
        _ = host.mappingAndSlideInfos
        _ = try? host.symbolCache
        return host
    }()
}
