import Foundation

/// A global actor for test code that must not run concurrently with itself
/// but has no actor of its own.
@globalActor
public actor TestActor {
    public static let shared = TestActor()
}
