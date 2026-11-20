/// A C++ class an image carries run-time type information for: its name and
/// its direct bases, read from its `std::type_info` object, so a class whose
/// symbols are stripped is found too.
///
/// ```swift
/// let store = CPlusPlusClassIndexStore.shared
/// for polymorphicClass in store.classes(in: machO) where !polymorphicClass.hasTypeInfoSymbol {
///     print(polymorphicClass.qualifiedName, polymorphicClass.bases.map(\.qualifiedName))
/// }
/// ```
///
/// A class comes from an image's ``CPlusPlusClassIndexStore`` index and
/// describes what that image stores.
public struct CPlusPlusClass: Hashable, Sendable, CustomStringConvertible {
    /// `TST::CellID`, printed the way ``CPlusPlusScope/qualifiedName`` prints
    /// a scope, so `CPlusPlusSymbolIndexStore.shared.scope(named:in:)` finds
    /// the scope that holds the class's other symbols. The mangled name
    /// itself when the demangler does not parse it.
    public let qualifiedName: String

    /// The components of ``qualifiedName``, outermost first.
    public let scopePath: [String]

    /// The last component without template arguments.
    public let baseName: String

    /// The type's mangling as its typeinfo names it: `N3TST6CellIDE`.
    public let mangledTypeName: String

    /// Where the typeinfo object sits, as an offset in the image.
    public let typeInfoOffset: Int

    /// The direct bases, in declaration order.
    public let bases: [Base]

    /// What the typeinfo records about repeated and diamond-shaped bases.
    public let inheritanceShape: InheritanceShape

    /// Whether the image has a vtable for the class; `false` for a class only
    /// `typeid` or a `catch` clause needs.
    public let hasVirtualTable: Bool

    /// Whether a `__ZTI…` symbol names the typeinfo; `false` for a class only
    /// its run-time type information shows.
    public let hasTypeInfoSymbol: Bool

    /// `false` when the typeinfo is not unique program-wide and is compared
    /// by name: on Apple arm64, the typeinfo of a type with default
    /// visibility and no key function — a class whose virtual functions are
    /// all inline, a template specialization — of which every image keeps a
    /// hidden copy of its own.
    public let hasUniqueTypeInfo: Bool

    init(
        qualifiedName: String,
        scopePath: [String],
        baseName: String,
        mangledTypeName: String,
        typeInfoOffset: Int,
        bases: [Base],
        inheritanceShape: InheritanceShape,
        hasVirtualTable: Bool,
        hasTypeInfoSymbol: Bool,
        hasUniqueTypeInfo: Bool
    ) {
        self.qualifiedName = qualifiedName
        self.scopePath = scopePath
        self.baseName = baseName
        self.mangledTypeName = mangledTypeName
        self.typeInfoOffset = typeInfoOffset
        self.bases = bases
        self.inheritanceShape = inheritanceShape
        self.hasVirtualTable = hasVirtualTable
        self.hasTypeInfoSymbol = hasTypeInfoSymbol
        self.hasUniqueTypeInfo = hasUniqueTypeInfo
    }

    public var description: String {
        qualifiedName
    }
}

extension CPlusPlusClass {
    /// A direct base of a class.
    public struct Base: Hashable, Sendable, CustomStringConvertible {
        public let qualifiedName: String

        /// The base's mangling as its typeinfo names it.
        public let mangledTypeName: String

        public let isVirtual: Bool

        public let isPublic: Bool

        /// For a non-virtual base, where its subobject sits in the class. For
        /// a virtual base, where the vtable stores the subobject's offset,
        /// relative to the address point (negative).
        public let offset: Int

        public let location: Location

        init(qualifiedName: String, mangledTypeName: String, isVirtual: Bool, isPublic: Bool, offset: Int, location: Location) {
            self.qualifiedName = qualifiedName
            self.mangledTypeName = mangledTypeName
            self.isVirtual = isVirtual
            self.isPublic = isPublic
            self.offset = offset
            self.location = location
        }

        public var description: String {
            (isVirtual ? "virtual " : "") + (isPublic ? "public " : "") + qualifiedName
        }
    }

    /// Where a base's typeinfo is defined.
    public enum Location: Hashable, Sendable {
        case sameImage(typeInfoOffset: Int)
        /// `installName` is the library a standalone file binds the typeinfo
        /// from, or the path of the image of the dyld shared cache or of the
        /// process that holds it; `nil` when neither is known.
        case otherImage(installName: String?)
    }

    /// What a typeinfo records about how a class's bases repeat.
    public struct InheritanceShape: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// Two or more distinct base subobjects of the same type.
        public static let repeatedBase = InheritanceShape(rawValue: 1 << 0)

        /// A base subobject reached along two or more paths.
        public static let diamond = InheritanceShape(rawValue: 1 << 1)
    }
}
