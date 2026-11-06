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

    // MARK: - Exports

    var exportTrie: CacheSlot<Base.ExportTrie?> = .notComputed

    // MARK: - Dyld cache files

    var subCacheTable: CacheSlot<DyldCacheSubCacheTable?> = .notComputed

    // MARK: - Legacy binds

    /// The slots `MachOFile`'s LC_DYLD_INFO(_ONLY) bind streams bind, by file
    /// offset.
    var dyldInfoBindsByFileOffset: CacheSlot<[UInt64: MachOFile.DyldInfoBind]> = .notComputed

    // MARK: - Resolved fixups

    /// What `MachOFile.resolveRebase(fileOffset:)` resolved, by the slot's
    /// file offset.
    var resolvedRebaseTargetsByFileOffset: [Int: UInt64] = [:]

    /// What `MachOFile.resolveBind(fileOffset:)` resolved, by the slot's
    /// file offset.
    var resolvedBindSymbolNamesByFileOffset: [UInt64: String] = [:]

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

    /// The entry the dictionary at `keyPath` holds for `key`, if any.
    func memoizedEntry<Key: Hashable, Value>(
        in keyPath: ReferenceWritableKeyPath<MachOCacheStorage, [Key: Value]>,
        for key: Key
    ) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return self[keyPath: keyPath][key]
    }

    /// Records `value` for `key` in the dictionary at `keyPath`.
    ///
    /// The dictionary lives in this storage and grows in place. Held in an
    /// associated object instead, each new entry read the dictionary out and
    /// stored a copy back, so resolving a file's slots one after another took
    /// time quadratic in their number.
    func memoize<Key: Hashable, Value>(
        _ value: Value,
        for key: Key,
        in keyPath: ReferenceWritableKeyPath<MachOCacheStorage, [Key: Value]>
    ) {
        lock.lock()
        defer { lock.unlock() }
        self[keyPath: keyPath][key] = value
    }
}
