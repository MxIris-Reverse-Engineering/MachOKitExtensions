import Foundation
import MachOKit

/// Backing store for a ``MachOCached`` view.
///
/// The storage is attached to the Mach-O it serves, so it never holds that
/// Mach-O itself — a reference back would form a cycle and leak both. Every
/// computation receives the Mach-O from the view instead.
final class MachOCacheStorage<Base: MachORepresentable>: @unchecked Sendable {
    private let lock = NSLock()

    // MARK: - Chained fixups

    var dyldChainedFixups: CacheSlot<Base.DyldChainedFixups?> = .notComputed
    var chainedImports: CacheSlot<[DyldChainedImport]> = .notComputed
    var fixupPointersByOffset: CacheSlot<[Int: DyldChainedFixupPointer]> = .notComputed

    // MARK: - Dyld cache files

    var subCacheTable: CacheSlot<DyldCacheSubCacheTable?> = .notComputed

    // MARK: - Memoization

    /// Returns the value cached at `keyPath`, computing and storing it on first
    /// access.
    ///
    /// `compute` runs outside the lock, so a slow parse neither blocks access
    /// to other slots nor deadlocks when it reads another memoized slot. Two
    /// threads racing on the same empty slot may both compute it; the first
    /// stored value wins and is returned to both, which is safe because every
    /// cached value is a pure function of immutable file contents.
    func memoized<Value>(
        _ keyPath: ReferenceWritableKeyPath<MachOCacheStorage, CacheSlot<Value>>,
        _ compute: () -> Value
    ) -> Value {
        lock.lock()
        if case .computed(let value) = self[keyPath: keyPath] {
            lock.unlock()
            return value
        }
        lock.unlock()

        let computedValue = compute()

        lock.lock()
        defer { lock.unlock() }
        if case .computed(let existingValue) = self[keyPath: keyPath] {
            return existingValue
        }
        self[keyPath: keyPath] = .computed(computedValue)
        return computedValue
    }
}
