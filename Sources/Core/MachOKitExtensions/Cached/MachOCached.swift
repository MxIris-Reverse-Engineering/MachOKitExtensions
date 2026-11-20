import MachOKit

/// A concurrency-safe view over a Mach-O that memoizes expensive parsing
/// results.
///
/// Obtained through `machO.cached`. Each member mirrors the MachOKit API of the
/// same name and returns the same result: the first access computes it, later
/// accesses reuse it. The cache lives exactly as long as the underlying Mach-O
/// instance.
public struct MachOCached<Base: MachORepresentable> {
    /// The Mach-O this view caches.
    public let base: Base

    let storage: MachOCacheStorage<Base>

    init(base: Base, storage: MachOCacheStorage<Base>) {
        self.base = base
        self.storage = storage
    }
}
