import Foundation

/// The languages other packages taught this package to tell apart.
///
/// A package that owns a language registers it once, when its image loads:
/// a C target's `__attribute__((constructor))` calling a Swift function the
/// package exports with `@c` runs with no caller involved, so the language is
/// known before any code asks.
///
/// ```swift
/// extension SymbolLanguage {
///     public static let rust = SymbolLanguage(rawValue: "Rust")
/// }
///
/// SymbolLanguageRegistry.shared.register(.rust, where: { name in
///     strncmp(name, "__R", 3) == 0
/// })
/// ```
///
/// A name's language is decided in this order: C++ mangling, which this
/// package recognizes itself; then each registered language in the order it
/// registered, the first whose recognizer accepts the name winning; then
/// ``SymbolLanguage/c``. ``SymbolIndexStore`` keeps C and C++ names and only
/// the offsets of every other language's.
public final class SymbolLanguageRegistry: @unchecked Sendable {
    /// The registry every classification and ``SymbolIndexStore/shared`` use
    /// unless told otherwise.
    public static let shared = SymbolLanguageRegistry()

    private let lock = NSLock()

    /// Guarded by `lock`.
    private var registrations: [SymbolLanguageRegistration] = []

    /// How many languages have registered: an index built from an older
    /// classification is out of date. Guarded by `lock`.
    private var registrationCount = 0

    /// An empty registry, for classifying apart from the shared one — a
    /// test, say.
    public init() {}

    /// Teaches the registry `language`: from now on a name `recognizes`
    /// accepts is `language`, unless C++ mangling or a language registered
    /// earlier claims it first.
    ///
    /// `recognizes` gets a NUL-terminated name as the symbol table spells it,
    /// valid only for the call, and is asked once for every name a sweep
    /// files, so it should read no more than the name's leading bytes.
    ///
    /// Registering a language a second time keeps the first recognizer: the
    /// same package can be linked into two images, and both register the
    /// same rule. Registering ``SymbolLanguage/c`` or
    /// ``SymbolLanguage/cPlusPlus`` is a programmer error — they are the
    /// order itself.
    ///
    /// Every index ``SymbolIndexStore`` built from this registry before is
    /// dropped on that store's next query, and built again.
    public func register(_ language: SymbolLanguage, where recognizes: @escaping @Sendable (UnsafePointer<CChar>) -> Bool) {
        precondition(language != .c && language != .cPlusPlus, "\(language) is built into SymbolLanguage and cannot be registered")
        lock.lock()
        defer { lock.unlock() }
        guard !registrations.contains(where: { $0.language == language }) else { return }
        registrations.append(SymbolLanguageRegistration(language: language, recognizes: recognizes))
        registrationCount += 1
    }

    /// The registered languages, in registration order.
    public var registeredLanguages: [SymbolLanguage] {
        lock.lock()
        defer { lock.unlock() }
        return registrations.map(\.language)
    }

    /// How many languages have registered so far.
    var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrationCount
    }

    /// The registrations as they stand now, to classify many names without
    /// taking the lock for each.
    func classifier() -> SymbolLanguageClassifier {
        lock.lock()
        defer { lock.unlock() }
        return SymbolLanguageClassifier(generation: registrationCount, registrations: registrations)
    }

    func language(ofSymbolNameBytes name: UnsafePointer<CChar>) -> SymbolLanguage {
        classifier().language(ofSymbolNameBytes: name)
    }
}

/// One language a registry knows, and the rule that recognizes its names.
struct SymbolLanguageRegistration: Sendable {
    let language: SymbolLanguage

    let recognizes: @Sendable (UnsafePointer<CChar>) -> Bool
}

/// A registry's registrations at one moment, classifying names in the
/// registry's order.
struct SymbolLanguageClassifier: Sendable {
    /// The registry's ``SymbolLanguageRegistry/generation`` when this was
    /// taken.
    let generation: Int

    let registrations: [SymbolLanguageRegistration]

    func language(ofSymbolNameBytes name: UnsafePointer<CChar>) -> SymbolLanguage {
        if SymbolLanguage.isItaniumMangled(name) {
            return .cPlusPlus
        }
        for registration in registrations where registration.recognizes(name) {
            return registration.language
        }
        return .c
    }
}
