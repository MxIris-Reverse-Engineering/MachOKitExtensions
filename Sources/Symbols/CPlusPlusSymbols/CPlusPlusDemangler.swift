internal import CPlusPlusDemangling

/// The vendored Itanium demangler, through its C interface. One parse at a
/// time: not thread-safe, so a demangler belongs to one task or thread.
///
/// Noncopyable, so the parser has exactly one owner, which destroys it.
/// Parsing is `mutating`: a parse invalidates the previous ``ParsedName``,
/// and exclusive access keeps a second parse from starting inside the body
/// that still reads the first.
struct CPlusPlusDemangler: ~Copyable {
    private let pointer: OpaquePointer

    init() {
        guard let pointer = CPlusPlusDemanglerCreate() else {
            fatalError("Allocating a C++ demangler failed")
        }
        self.pointer = pointer
    }

    deinit {
        CPlusPlusDemanglerDestroy(pointer)
    }

    /// Parses `nameBytes` — a symbol name as the symbol table spells it —
    /// and hands the result to `body`; `nil` when the name does not parse.
    /// The result is valid only inside `body`.
    mutating func withParsedName<Result>(bytes nameBytes: UnsafeBufferPointer<UInt8>, _ body: (ParsedName) throws -> Result) rethrows -> Result? {
        let isParsed = nameBytes.withMemoryRebound(to: CChar.self) { characters in
            CPlusPlusDemanglerParse(pointer, characters.baseAddress, characters.count)
        }
        guard isParsed else { return nil }
        return try body(ParsedName(pointer: pointer))
    }

    mutating func withParsedName<Result>(_ mangledName: String, _ body: (ParsedName) throws -> Result) rethrows -> Result? {
        var mangledName = mangledName
        return try mangledName.withUTF8 { nameBytes in
            try withParsedName(bytes: nameBytes, body)
        }
    }
}

extension CPlusPlusDemangler {
    /// What the mangling says a scope component is.
    enum ScopeHint: Sendable {
        case none
        case namespace
        case type
        case function
    }

    /// A parsed name, read through the demangler that parsed it. Valid only
    /// until that demangler parses again.
    struct ParsedName {
        fileprivate let pointer: OpaquePointer

        var kind: CPlusPlusSymbolName.Kind {
            CPlusPlusSymbolName.Kind(CPlusPlusDemanglerGetKind(pointer))
        }

        var demangledName: String {
            Self.string(CPlusPlusDemanglerGetDemangledName(pointer)) ?? ""
        }

        var scopeComponentCount: Int {
            CPlusPlusDemanglerGetScopeComponentCount(pointer)
        }

        func scopeComponentName(at componentIndex: Int) -> String {
            Self.string(CPlusPlusDemanglerGetScopeComponentName(pointer, componentIndex)) ?? ""
        }

        func scopeComponentBaseName(at componentIndex: Int) -> String {
            Self.string(CPlusPlusDemanglerGetScopeComponentBaseName(pointer, componentIndex)) ?? ""
        }

        func scopeComponentHint(at componentIndex: Int) -> ScopeHint {
            switch CPlusPlusDemanglerGetScopeComponentHint(pointer, componentIndex) {
            case .none:
                .none
            case .namespace:
                .namespace
            case .type:
                .type
            case .function:
                .function
            }
        }

        var scopePath: [String] {
            (0 ..< scopeComponentCount).map(scopeComponentName(at:))
        }

        var baseName: String {
            Self.string(CPlusPlusDemanglerGetBaseName(pointer)) ?? ""
        }

        var templateArguments: String? {
            Self.string(CPlusPlusDemanglerGetTemplateArguments(pointer))
        }

        var parameters: String? {
            Self.string(CPlusPlusDemanglerGetParameters(pointer))
        }

        var returnType: String? {
            Self.string(CPlusPlusDemanglerGetReturnType(pointer))
        }

        var suffix: String? {
            Self.string(CPlusPlusDemanglerGetSuffix(pointer))
        }

        var functionQualifiers: CPlusPlusSymbolName.FunctionQualifiers {
            CPlusPlusSymbolName.FunctionQualifiers(demanglerQualifiers: CPlusPlusDemanglerGetFunctionQualifiers(pointer))
        }

        var constructorOrDestructorVariant: Int? {
            let variant = CPlusPlusDemanglerGetConstructorOrDestructorVariant(pointer)
            return variant < 0 ? nil : Int(variant)
        }

        /// The scope paths of the named types the name uses as types.
        var referencedTypePaths: [[String]] {
            (0 ..< CPlusPlusDemanglerGetReferencedTypeCount(pointer)).map { typeIndex in
                (0 ..< CPlusPlusDemanglerGetReferencedTypeComponentCount(pointer, typeIndex)).map { componentIndex in
                    Self.string(CPlusPlusDemanglerGetReferencedTypeComponentName(pointer, typeIndex, componentIndex)) ?? ""
                }
            }
        }

        /// The named types `parameters`, which `text` must be, spells.
        func parameterTypeReferences(in text: String?) -> [CPlusPlusSymbolName.TypeReference] {
            typeReferences(of: .parameters, in: text)
        }

        /// The named types `returnType`, which `text` must be, spells.
        func returnTypeReferences(in text: String?) -> [CPlusPlusSymbolName.TypeReference] {
            typeReferences(of: .returnType, in: text)
        }

        private func typeReferences(of part: CPlusPlusDemanglerSignaturePart, in text: String?) -> [CPlusPlusSymbolName.TypeReference] {
            guard let text else { return [] }
            let utf8 = text.utf8
            return (0 ..< CPlusPlusDemanglerGetSignatureTypeCount(pointer, part)).compactMap { typeIndex in
                let byteRange = CPlusPlusDemanglerGetSignatureTypeRange(pointer, part, typeIndex)
                // The text came from these bytes, so their offsets are its
                // UTF-8 offsets; one that is no character boundary would
                // mean the text was decoded with replacements.
                guard byteRange.start <= byteRange.end, byteRange.end <= utf8.count,
                      let lowerBound = String.Index(utf8.index(utf8.startIndex, offsetBy: byteRange.start), within: text),
                      let upperBound = String.Index(utf8.index(utf8.startIndex, offsetBy: byteRange.end), within: text)
                else { return nil }
                let path = (0 ..< CPlusPlusDemanglerGetSignatureTypeComponentCount(pointer, part, typeIndex)).map { componentIndex in
                    Self.string(CPlusPlusDemanglerGetSignatureTypeComponentName(pointer, part, typeIndex, componentIndex)) ?? ""
                }
                return CPlusPlusSymbolName.TypeReference(path: path, range: lowerBound ..< upperBound)
            }
        }

        private static func string(_ text: CPlusPlusDemanglerText) -> String? {
            guard let bytes = text.bytes else { return nil }
            return String(decoding: UnsafeRawBufferPointer(start: bytes, count: text.length), as: UTF8.self)
        }
    }
}

extension CPlusPlusSymbolName.Kind {
    fileprivate init(_ demanglerKind: CPlusPlusDemanglerSymbolKind) {
        self = switch demanglerKind {
        case .function: .function
        case .constructor: .constructor
        case .destructor: .destructor
        case .variable: .variable
        case .virtualTable: .virtualTable
        case .virtualTableTable: .virtualTableTable
        case .constructionVirtualTable: .constructionVirtualTable
        case .typeInfo: .typeInfo
        case .typeInfoName: .typeInfoName
        case .nonVirtualThunk: .nonVirtualThunk
        case .virtualThunk: .virtualThunk
        case .covariantReturnThunk: .covariantReturnThunk
        case .guardVariable: .guardVariable
        case .referenceTemporary: .referenceTemporary
        case .threadLocalWrapper: .threadLocalWrapper
        case .threadLocalInitializer: .threadLocalInitializer
        case .templateParameterObject: .templateParameterObject
        case .moduleInitializer: .moduleInitializer
        case .blockInvocation: .blockInvocation
        }
    }
}

extension CPlusPlusSymbolName.FunctionQualifiers {
    fileprivate init(demanglerQualifiers: UInt32) {
        var qualifiers: Self = []
        if demanglerQualifiers & UInt32(CPlusPlusDemanglerQualifierConst) != 0 {
            qualifiers.insert(.const)
        }
        if demanglerQualifiers & UInt32(CPlusPlusDemanglerQualifierVolatile) != 0 {
            qualifiers.insert(.volatile)
        }
        if demanglerQualifiers & UInt32(CPlusPlusDemanglerQualifierRestrict) != 0 {
            qualifiers.insert(.restrict)
        }
        if demanglerQualifiers & UInt32(CPlusPlusDemanglerQualifierLValueReference) != 0 {
            qualifiers.insert(.lValueReference)
        }
        if demanglerQualifiers & UInt32(CPlusPlusDemanglerQualifierRValueReference) != 0 {
            qualifiers.insert(.rValueReference)
        }
        self = qualifiers
    }
}
