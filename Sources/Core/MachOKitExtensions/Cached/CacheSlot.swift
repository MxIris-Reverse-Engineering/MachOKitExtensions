/// A storage slot for a lazily computed, memoized value.
///
/// Distinguishes "never computed" from "computed", so an API whose result is
/// `nil` is cached as `.computed(nil)` instead of being recomputed on every
/// access.
enum CacheSlot<Value> {
    case notComputed
    case computed(Value)
}
