/// A namespace, type or function that C++ symbols of an image sit in.
///
/// ```swift
/// let store = CPlusPlusSymbolIndexStore.shared
/// for scope in store.childScopes(of: .global, in: machO) where scope.kind == .type {
///     print(scope.qualifiedName, scope.evidence)
/// }
/// ```
///
/// A scope comes from an image's ``CPlusPlusSymbolIndexStore`` index, and
/// ``kind`` and ``evidence`` are what that image's symbol names show: the
/// same class may be a type in one image and undetermined in another.
public struct CPlusPlusScope: Hashable, Sendable, CustomStringConvertible {
    /// The global namespace: the parent of every top-level scope.
    public static let global = CPlusPlusScope(path: [], baseName: "", kind: .namespace, evidence: [])

    /// The scope's components, outermost first, each as C++ prints it;
    /// empty for ``global``.
    public let path: [String]

    /// The last component without template arguments — `vector` for
    /// `vector<int, std::__1::allocator<int>>` — so that every specialization
    /// of one class template shares it; a function's name without its
    /// parameters.
    public let baseName: String

    public let kind: Kind

    /// What the image's symbol names show about the scope.
    public let evidence: Evidence

    init(path: [String], baseName: String, kind: Kind, evidence: Evidence) {
        self.path = path
        self.baseName = baseName
        self.kind = kind
        self.evidence = evidence
    }

    /// The last component as C++ prints it:
    /// `vector<int, std::__1::allocator<int>>`; empty for ``global``.
    public var name: String {
        path.last ?? ""
    }

    /// The components joined as C++ joins them:
    /// `std::__1::vector<int, std::__1::allocator<int>>`; empty for
    /// ``global``. It identifies the scope within an image.
    public var qualifiedName: String {
        path.joined(separator: "::")
    }

    public var description: String {
        path.isEmpty ? "(global)" : qualifiedName
    }
}

extension CPlusPlusScope {
    /// What a scope is. The mangling never says whether a component is a
    /// namespace or a class; a scope is a type or a namespace only when some
    /// symbol name of the image shows it, and is ``undetermined`` otherwise.
    ///
    /// The rules may learn more evidence, so a scope's kind can change
    /// between versions — an ``undetermined`` scope may become a ``type``.
    public struct Kind: Hashable, Sendable, CustomStringConvertible {
        private enum Storage: Hashable, Sendable {
            case namespace
            case type
            case function
            case undetermined
        }

        private let storage: Storage

        private init(_ storage: Storage) {
            self.storage = storage
        }

        /// The global namespace, `std`, an anonymous namespace.
        public static let namespace = Kind(.namespace)
        /// A class, struct, union or enum.
        public static let type = Kind(.type)
        /// The function a local entity sits in.
        public static let function = Kind(.function)
        /// A namespace or a type; no symbol name shows which.
        public static let undetermined = Kind(.undetermined)

        public var description: String {
            switch storage {
            case .namespace: "namespace"
            case .type: "type"
            case .function: "function"
            case .undetermined: "undetermined"
            }
        }
    }

    /// What an image's symbol names show about a scope.
    public struct Evidence: OptionSet, Hashable, Sendable {
        public let rawValue: UInt16

        public init(rawValue: UInt16) {
            self.rawValue = rawValue
        }

        /// The mangling itself names it a namespace: `std`, an anonymous
        /// namespace.
        public static let mangledAsNamespace = Evidence(rawValue: 1 << 0)
        /// The mangling itself names it a type: a lambda, an unnamed type,
        /// `std::allocator` and the other standard substitutions.
        public static let mangledAsType = Evidence(rawValue: 1 << 1)
        /// A constructor or a destructor sits in it.
        public static let constructorOrDestructor = Evidence(rawValue: 1 << 2)
        /// Its vtable, VTT or a construction vtable.
        public static let virtualTable = Evidence(rawValue: 1 << 3)
        /// Its typeinfo or typeinfo name.
        public static let typeInfo = Evidence(rawValue: 1 << 4)
        /// A `const`, `volatile`, `&` or `&&` member function sits in it.
        public static let qualifiedMemberFunction = Evidence(rawValue: 1 << 5)
        /// A thunk to one of its member functions.
        public static let thunk = Evidence(rawValue: 1 << 6)
        /// A signature or a type template argument uses it as a type.
        public static let usedAsType = Evidence(rawValue: 1 << 7)

        /// Every evidence of a type.
        public static let anyType: Evidence = [
            .mangledAsType,
            .constructorOrDestructor,
            .virtualTable,
            .typeInfo,
            .qualifiedMemberFunction,
            .thunk,
            .usedAsType,
        ]
    }
}
