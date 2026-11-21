/// A C++ (Itanium) symbol name taken apart: what it names, the scopes that
/// entity sits in, and the parts of its signature, each as C++ prints it.
///
/// ```swift
/// let name = CPlusPlusSymbolName(mangledName: "__ZNK4llvm5Value4dumpEv")!
/// name.demangledName          // "llvm::Value::dump() const"
/// name.kind                   // .function
/// name.scopePath              // ["llvm", "Value"]
/// name.baseName               // "dump"
/// name.parameters             // "()"
/// name.functionQualifiers     // [.const]
/// ```
///
/// Where a name files its entity:
///
/// - a function or a variable: the scopes of its qualified name;
/// - a name about a type — its vtable, VTT or typeinfo — that type itself, so
///   the path ends with the type and ``baseName`` repeats its last
///   component; a construction vtable goes to the complete class being
///   constructed; a name about a type without a name of its own (a pointer's
///   typeinfo, a built-in type's) sits at global scope;
/// - a thunk, a guard variable, a reference temporary or a thread-local
///   routine: the function or variable it is for;
/// - a block: the function it sits in, without that function's signature;
/// - a template parameter object or a module initializer: global scope.
///
/// A local entity's path runs through the function it sits in, printed with
/// its parameters: `localThing()::Bar::baz()` is `baz` in
/// `["localThing()", "Bar"]`. An Objective-C method, which the mangling
/// spells without parameters, is its bare name: a static local of
/// `-[CAMetalDrawable texture]` is in `["-[CAMetalDrawable texture]"]`.
///
/// ``parameterTypeReferences`` and ``returnTypeReferences`` say where the
/// signature's text spells each named type, for a caller that shows the
/// types apart from the punctuation and the built-in types around them.
public struct CPlusPlusSymbolName: Hashable, Sendable, CustomStringConvertible {
    public let mangledName: String

    /// The whole name as `__cxa_demangle` prints it.
    public let demangledName: String

    public let kind: Kind

    /// The scopes the entity sits in, outermost first, each as C++ prints
    /// it — a specialization with its arguments, a function with its
    /// parameters: `["std", "__1", "vector<int, std::__1::allocator<int>>"]`.
    /// Empty at global scope.
    public let scopePath: [String]

    /// The entity's own name without template arguments: `push_back`;
    /// `vector` and `~vector` for a constructor and a destructor; for a name
    /// about a type, the type's last component.
    public let baseName: String

    /// `<int>` when the entity itself is a template specialization.
    public let templateArguments: String?

    /// `(int, char const*)` for a function; `nil` for anything else.
    public let parameters: String?

    /// The return type, which the mangling records only for a function
    /// template specialization; `nil` otherwise.
    public let returnType: String?

    /// The named types ``parameters`` spells, each with its range in
    /// ``parameters``: `CA::Render::Surface` in `(CA::Render::Surface*)`.
    /// Empty when there are no parameters, or only built-in types.
    public let parameterTypeReferences: [TypeReference]

    /// The named types ``returnType`` spells, each with its range in
    /// ``returnType``.
    public let returnTypeReferences: [TypeReference]

    public let functionQualifiers: FunctionQualifiers

    /// The Itanium variant of a constructor (`C1` → 1, `C2` → 2, …) or a
    /// destructor (`D0` → 0, …); `nil` for anything else. Variants of one
    /// constructor print the same name and sit at different offsets.
    public let constructorOrDestructorVariant: Int?

    /// What follows the name after a dot — `.cold.1` — or `nil`.
    public let suffix: String?

    /// `nil` when `mangledName` is not an Itanium name this demangler parses.
    /// `mangledName` is spelled as the symbol table spells it on Darwin:
    /// `__Z…`, or `____Z…_block_invoke` for a block inside a C++ function.
    public init?(mangledName: String) {
        let demangler = CPlusPlusDemangler()
        guard let name = demangler.withParsedName(mangledName, { Self(mangledName: mangledName, parsedName: $0) }) else { return nil }
        self = name
    }

    init(mangledName: String, parsedName: CPlusPlusDemangler.ParsedName) {
        self.mangledName = mangledName
        self.demangledName = parsedName.demangledName
        self.kind = parsedName.kind
        self.scopePath = parsedName.scopePath
        self.baseName = parsedName.baseName
        self.templateArguments = parsedName.templateArguments
        let parameters = parsedName.parameters
        let returnType = parsedName.returnType
        self.parameters = parameters
        self.returnType = returnType
        self.parameterTypeReferences = parsedName.parameterTypeReferences(in: parameters)
        self.returnTypeReferences = parsedName.returnTypeReferences(in: returnType)
        self.functionQualifiers = parsedName.functionQualifiers
        self.constructorOrDestructorVariant = parsedName.constructorOrDestructorVariant
        self.suffix = parsedName.suffix
    }

    public var description: String {
        demangledName
    }
}

extension CPlusPlusSymbolName {
    /// A named type a function's signature spells, and where its text
    /// spells it.
    ///
    /// ```swift
    /// let name = CPlusPlusSymbolName(mangledName: "__Z4takeRKNSt3__16vectorIN2CA3FooENS_9allocatorIS2_EEEE")!
    /// let parameters = name.parameters!   // "(std::__1::vector<CA::Foo, std::__1::allocator<CA::Foo>> const&)"
    /// name.parameterTypeReferences.map { parameters[$0.range] }
    /// // ["std::__1::vector<CA::Foo, std::__1::allocator<CA::Foo>>", "CA::Foo",
    /// //  "std::__1::allocator<CA::Foo>", "CA::Foo"]
    /// ```
    ///
    /// The references are ordered by where they start. A template comes
    /// before the types its argument list spells, and its range covers them:
    /// ranges nest, they never overlap otherwise. A qualifier is part of the
    /// name it qualifies, never a reference of its own. Built-in types,
    /// pointers, references and cv-qualifiers are no references; the range of
    /// `CA::Foo const*` covers `CA::Foo`.
    public struct TypeReference: Hashable, Sendable {
        /// The type's scopes and the type itself, outermost first, each as
        /// C++ prints it — a ``CPlusPlusScope`` path:
        /// `["std", "__1", "vector<CA::Foo, std::__1::allocator<CA::Foo>>"]`.
        public let path: [String]

        /// Where the text the reference comes from — ``parameters`` or
        /// ``returnType`` — spells the type, template arguments included.
        public let range: Range<String.Index>

        init(path: [String], range: Range<String.Index>) {
            self.path = path
            self.range = range
        }
    }
}

extension CPlusPlusSymbolName {
    /// What a C++ symbol names. More kinds can be added as the Itanium ABI
    /// grows, so a caller never switches over all of them.
    public struct Kind: Hashable, Sendable, CustomStringConvertible {
        private enum Storage: Hashable, Sendable {
            case function
            case constructor
            case destructor
            case variable
            case virtualTable
            case virtualTableTable
            case constructionVirtualTable
            case typeInfo
            case typeInfoName
            case nonVirtualThunk
            case virtualThunk
            case covariantReturnThunk
            case guardVariable
            case referenceTemporary
            case threadLocalWrapper
            case threadLocalInitializer
            case templateParameterObject
            case moduleInitializer
            case blockInvocation
        }

        private let storage: Storage

        private init(_ storage: Storage) {
            self.storage = storage
        }

        /// A function, member or not, other than a constructor or destructor.
        public static let function = Kind(.function)
        public static let constructor = Kind(.constructor)
        public static let destructor = Kind(.destructor)
        /// Data: a variable at namespace scope or a static data member.
        public static let variable = Kind(.variable)
        /// A class's vtable.
        public static let virtualTable = Kind(.virtualTable)
        /// A class's VTT, the table of vtables a class with virtual bases
        /// uses while it is constructed.
        public static let virtualTableTable = Kind(.virtualTableTable)
        /// The vtable a base subobject uses while a class with virtual bases
        /// is constructed.
        public static let constructionVirtualTable = Kind(.constructionVirtualTable)
        public static let typeInfo = Kind(.typeInfo)
        /// The string a typeinfo names its type with.
        public static let typeInfoName = Kind(.typeInfoName)
        public static let nonVirtualThunk = Kind(.nonVirtualThunk)
        public static let virtualThunk = Kind(.virtualThunk)
        public static let covariantReturnThunk = Kind(.covariantReturnThunk)
        /// The flag a function-local static checks before it is initialized.
        public static let guardVariable = Kind(.guardVariable)
        /// The object a reference with static storage is bound to.
        public static let referenceTemporary = Kind(.referenceTemporary)
        public static let threadLocalWrapper = Kind(.threadLocalWrapper)
        public static let threadLocalInitializer = Kind(.threadLocalInitializer)
        public static let templateParameterObject = Kind(.templateParameterObject)
        public static let moduleInitializer = Kind(.moduleInitializer)
        /// The function a block literal inside a C++ function runs.
        public static let blockInvocation = Kind(.blockInvocation)

        public var description: String {
            switch storage {
            case .function: "function"
            case .constructor: "constructor"
            case .destructor: "destructor"
            case .variable: "variable"
            case .virtualTable: "vtable"
            case .virtualTableTable: "VTT"
            case .constructionVirtualTable: "construction vtable"
            case .typeInfo: "typeinfo"
            case .typeInfoName: "typeinfo name"
            case .nonVirtualThunk: "non-virtual thunk"
            case .virtualThunk: "virtual thunk"
            case .covariantReturnThunk: "covariant return thunk"
            case .guardVariable: "guard variable"
            case .referenceTemporary: "reference temporary"
            case .threadLocalWrapper: "thread-local wrapper"
            case .threadLocalInitializer: "thread-local initializer"
            case .templateParameterObject: "template parameter object"
            case .moduleInitializer: "module initializer"
            case .blockInvocation: "block invocation"
            }
        }

        /// Whether the kind is a thunk of any sort.
        var isThunk: Bool {
            switch storage {
            case .nonVirtualThunk, .virtualThunk, .covariantReturnThunk:
                true
            default:
                false
            }
        }
    }

    /// The cv and ref qualifiers of a member function.
    public struct FunctionQualifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let const = FunctionQualifiers(rawValue: 1 << 0)
        public static let volatile = FunctionQualifiers(rawValue: 1 << 1)
        public static let restrict = FunctionQualifiers(rawValue: 1 << 2)
        /// `&`
        public static let lValueReference = FunctionQualifiers(rawValue: 1 << 3)
        /// `&&`
        public static let rValueReference = FunctionQualifiers(rawValue: 1 << 4)
    }
}
