// The C interface of `include/CPlusPlusDemangling.h`: parses a name with the
// vendored Itanium demangler, then walks its AST the way LLVM's
// `ItaniumPartialDemangler` does (llvm/lib/Demangle/ItaniumDemangle.cpp),
// splitting the name into the parts a classification needs.

// First, so that `DemangleConfig.h` sets up its abort hook before any
// standard header defines one.
#include "ItaniumDemangle/ItaniumDemangle.h"

#include "CPlusPlusDemangling.h"

#include <cctype>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

using namespace itanium_demangle;

// ===== Copied from libc++abi =====
//
// `parse_discriminator` and the allocator below are copied from libc++abi,
// src/cxa_demangle.cpp (lines 31-58 and 290-366 at llvm-project
// 903b9faaae5c): `ItaniumDemangle.h` declares the one and expects a client to
// bring the other. Part of the LLVM Project, under the Apache License v2.0
// with LLVM Exceptions; see ItaniumDemangle/LICENSE.TXT.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

// <discriminator> := _ <non-negative number>      # when number < 10
//                 := __ <non-negative number> _   # when number >= 10
//  extension      := decimal-digit+               # at the end of string
const char *itanium_demangle::parse_discriminator(const char *first,
                                                  const char *last) {
  // parse but ignore discriminator
  if (first != last) {
    if (*first == '_') {
      const char *t1 = first + 1;
      if (t1 != last) {
        if (std::isdigit(*t1))
          first = t1 + 1;
        else if (*t1 == '_') {
          for (++t1; t1 != last && std::isdigit(*t1); ++t1)
            ;
          if (t1 != last && *t1 == '_')
            first = t1 + 1;
        }
      }
    } else if (std::isdigit(*first)) {
      const char *t1 = first + 1;
      for (; t1 != last && std::isdigit(*t1); ++t1)
        ;
      if (t1 == last)
        first = last;
    }
  }
  return first;
}

namespace {

class BumpPointerAllocator {
  struct BlockMeta {
    BlockMeta* Next;
    size_t Current;
  };

  static constexpr size_t AllocSize = 4096;
  static constexpr size_t UsableAllocSize = AllocSize - sizeof(BlockMeta);

  alignas(long double) char InitialBuffer[AllocSize];
  BlockMeta* BlockList = nullptr;

  void grow() {
    char* NewMeta = static_cast<char *>(std::malloc(AllocSize));
    if (NewMeta == nullptr)
      std::terminate();
    BlockList = new (NewMeta) BlockMeta{BlockList, 0};
  }

  void* allocateMassive(size_t NBytes) {
    NBytes += sizeof(BlockMeta);
    BlockMeta* NewMeta = reinterpret_cast<BlockMeta*>(std::malloc(NBytes));
    if (NewMeta == nullptr)
      std::terminate();
    BlockList->Next = new (NewMeta) BlockMeta{BlockList->Next, 0};
    return static_cast<void*>(NewMeta + 1);
  }

public:
  BumpPointerAllocator()
      : BlockList(new (InitialBuffer) BlockMeta{nullptr, 0}) {}

  void* allocate(size_t N) {
    N = (N + 15u) & ~15u;
    if (N + BlockList->Current >= UsableAllocSize) {
      if (N > UsableAllocSize)
        return allocateMassive(N);
      grow();
    }
    BlockList->Current += N;
    return static_cast<void*>(reinterpret_cast<char*>(BlockList + 1) +
                              BlockList->Current - N);
  }

  void reset() {
    while (BlockList) {
      BlockMeta* Tmp = BlockList;
      BlockList = BlockList->Next;
      if (reinterpret_cast<char*>(Tmp) != InitialBuffer)
        std::free(Tmp);
    }
    BlockList = new (InitialBuffer) BlockMeta{nullptr, 0};
  }

  ~BumpPointerAllocator() { reset(); }
};

class DefaultAllocator {
  BumpPointerAllocator Alloc;

public:
  void reset() { Alloc.reset(); }

  template<typename T, typename ...Args> T *makeNode(Args &&...args) {
    return new (Alloc.allocate(sizeof(T)))
        T(std::forward<Args>(args)...);
  }

  void *allocateNodeArray(size_t sz) {
    return Alloc.allocate(sizeof(Node *) * sz);
  }
};

// ===== End of the code copied from libc++abi =====

using Demangler = ManglingParser<DefaultAllocator>;

/// The deepest a walk over types goes. A forward template reference can make
/// the AST cyclic; real names stay far shallower.
constexpr int maximumTypeDepth = 64;

std::string printedText(const Node *node) {
    OutputBuffer buffer;
    node->print(buffer);
    std::string text(buffer.getBuffer() == nullptr ? "" : buffer.getBuffer(), buffer.getCurrentPosition());
    std::free(buffer.getBuffer());
    return text;
}

const Node *withoutAbiTags(const Node *node) {
    while (node->getKind() == Node::KAbiTagAttr) {
        node = static_cast<const AbiTagAttr *>(node)->Base;
    }
    return node;
}

void appendQualifiers(OutputBuffer &buffer, Qualifiers qualifiers, FunctionRefQual referenceQualifier) {
    if (qualifiers & QualConst) {
        buffer += " const";
    }
    if (qualifiers & QualVolatile) {
        buffer += " volatile";
    }
    if (qualifiers & QualRestrict) {
        buffer += " restrict";
    }
    if (referenceQualifier == FrefQualLValue) {
        buffer += " &";
    } else if (referenceQualifier == FrefQualRValue) {
        buffer += " &&";
    }
}

/// Text computed on first request and kept until the next parse.
struct CachedText {
    bool isComputed = false;
    bool isPresent = false;
    std::string value;

    void clear() {
        isComputed = false;
        isPresent = false;
        value.clear();
    }

    template <typename Compute>
    CPlusPlusDemanglerText get(Compute compute) {
        if (!isComputed) {
            isComputed = true;
            isPresent = compute(value);
        }
        if (!isPresent) {
            return CPlusPlusDemanglerText{nullptr, 0};
        }
        return CPlusPlusDemanglerText{value.data(), value.size()};
    }
};

/// One component of a scope path.
struct ScopeComponent {
    /// The component's unqualified name; `nullptr` when `fixedName` stands in.
    const Node *name = nullptr;
    const Node *templateArguments = nullptr;
    /// Set for the function a local entity sits in.
    const FunctionEncoding *function = nullptr;
    /// For a component a substitution spells (`std`, `allocator`).
    std::string_view fixedName;
    /// Whether the printed name drops a leading `std::` (an expanded
    /// substitution prints its namespace with it).
    bool dropsStandardPrefix = false;
    CPlusPlusDemanglerScopeHint hint = CPlusPlusDemanglerScopeHintNone;

    mutable CachedText printedName;
    mutable CachedText printedBaseName;

    CPlusPlusDemanglerText nameText() const {
        return printedName.get([this](std::string &text) {
            if (name == nullptr) {
                text.assign(fixedName);
                return true;
            }
            OutputBuffer buffer;
            name->print(buffer);
            if (templateArguments != nullptr) {
                templateArguments->print(buffer);
            }
            if (function != nullptr) {
                buffer += "(";
                function->getParams().printWithComma(buffer);
                buffer += ")";
                appendQualifiers(buffer, function->getCVQuals(), function->getRefQual());
            }
            text.assign(buffer.getBuffer() == nullptr ? "" : buffer.getBuffer(), buffer.getCurrentPosition());
            std::free(buffer.getBuffer());
            if (dropsStandardPrefix && text.compare(0, 5, "std::") == 0) {
                text.erase(0, 5);
            }
            return true;
        });
    }

    CPlusPlusDemanglerText baseNameText() const {
        return printedBaseName.get([this](std::string &text) {
            if (name == nullptr) {
                text.assign(fixedName);
            } else if (dropsStandardPrefix) {
                text.assign(name->getBaseName());
            } else {
                text = printedText(withoutAbiTags(name));
            }
            return true;
        });
    }
};

using ScopePath = std::vector<ScopeComponent>;

} // namespace

struct CPlusPlusDemangler {
    std::string input;
    Demangler parser{nullptr, nullptr};

    const Node *root = nullptr;
    CPlusPlusDemanglerSymbolKind kind = CPlusPlusDemanglerSymbolKindFunction;
    ScopePath scope;
    /// The entity's own name, with its template arguments.
    ScopeComponent entity;
    /// Stands in for `entity` when the name is about something unnamed: a
    /// pointer's typeinfo, a template parameter object.
    const Node *unnamedEntity = nullptr;
    /// The function whose parameters, return type and qualifiers the name
    /// carries.
    const FunctionEncoding *function = nullptr;
    std::string_view suffix;
    bool hasSuffix = false;
    uint32_t qualifiers = 0;
    int32_t constructorOrDestructorVariant = -1;
    std::vector<ScopePath> referencedTypes;

    CachedText demangledName;
    CachedText baseName;
    CachedText templateArguments;
    CachedText parameters;
    CachedText returnType;

    void clear() {
        root = nullptr;
        kind = CPlusPlusDemanglerSymbolKindFunction;
        scope.clear();
        entity = ScopeComponent();
        unnamedEntity = nullptr;
        function = nullptr;
        suffix = std::string_view();
        hasSuffix = false;
        qualifiers = 0;
        constructorOrDestructorVariant = -1;
        referencedTypes.clear();
        demangledName.clear();
        baseName.clear();
        templateArguments.clear();
        parameters.clear();
        returnType.clear();
    }

    /// Whether `text` points into the name being parsed — a source name,
    /// rather than a built-in type's spelling, which the demangler keeps as
    /// a string literal.
    bool isSourceText(std::string_view text) const {
        return text.data() >= input.data() && text.data() + text.size() <= input.data() + input.size();
    }

    // ===== Scope paths =====

    /// Appends the components of the qualified name `node` to `path`; the
    /// last one gets `trailingTemplateArguments`.
    void appendPath(const Node *node, const Node *trailingTemplateArguments, ScopePath &path) {
        switch (node->getKind()) {
        case Node::KNestedName: {
            const auto *nestedName = static_cast<const NestedName *>(node);
            appendPath(nestedName->Qual, nullptr, path);
            appendPath(nestedName->Name, trailingTemplateArguments, path);
            return;
        }
        case Node::KNameWithTemplateArgs: {
            const auto *nameWithTemplateArguments = static_cast<const NameWithTemplateArgs *>(node);
            appendPath(nameWithTemplateArguments->Name, nameWithTemplateArguments->TemplateArgs, path);
            return;
        }
        case Node::KLocalName: {
            const auto *localName = static_cast<const LocalName *>(node);
            appendEnclosingFunction(localName->Encoding, path);
            appendPath(localName->Entity, trailingTemplateArguments, path);
            return;
        }
        case Node::KModuleEntity:
            appendPath(static_cast<const ModuleEntity *>(node)->Name, trailingTemplateArguments, path);
            return;
        case Node::KGlobalQualifiedName:
            static_cast<const GlobalQualifiedName *>(node)->match([&](const Node *child) {
                appendPath(child, trailingTemplateArguments, path);
            });
            return;
        case Node::KSpecialSubstitution:
        case Node::KExpandedSpecialSubstitution: {
            ScopeComponent standardNamespace;
            standardNamespace.fixedName = "std";
            standardNamespace.hint = CPlusPlusDemanglerScopeHintNamespace;
            path.push_back(std::move(standardNamespace));
            ScopeComponent component;
            component.name = node;
            component.templateArguments = trailingTemplateArguments;
            component.dropsStandardPrefix = true;
            component.hint = CPlusPlusDemanglerScopeHintType;
            path.push_back(std::move(component));
            return;
        }
        default:
            break;
        }
        ScopeComponent component;
        component.name = node;
        component.templateArguments = trailingTemplateArguments;
        const Node *untagged = withoutAbiTags(node);
        switch (untagged->getKind()) {
        case Node::KNameType: {
            std::string_view text = static_cast<const NameType *>(untagged)->getName();
            if (text == "std" || text == "(anonymous namespace)") {
                component.hint = CPlusPlusDemanglerScopeHintNamespace;
            }
            break;
        }
        case Node::KClosureTypeName:
        case Node::KUnnamedTypeName:
            component.hint = CPlusPlusDemanglerScopeHintType;
            break;
        default:
            break;
        }
        path.push_back(std::move(component));
    }

    /// Appends the function a local entity sits in: the scopes of the
    /// function's own name, then the function as one component.
    void appendEnclosingFunction(const Node *encoding, ScopePath &path) {
        if (encoding->getKind() != Node::KFunctionEncoding) {
            appendPath(encoding, nullptr, path);
            return;
        }
        const auto *enclosingFunction = static_cast<const FunctionEncoding *>(encoding);
        ScopePath functionPath;
        appendPath(enclosingFunction->getName(), nullptr, functionPath);
        if (functionPath.empty()) {
            return;
        }
        ScopeComponent functionComponent = std::move(functionPath.back());
        functionPath.pop_back();
        for (ScopeComponent &component : functionPath) {
            path.push_back(std::move(component));
        }
        functionComponent.function = enclosingFunction;
        functionComponent.hint = CPlusPlusDemanglerScopeHintFunction;
        path.push_back(std::move(functionComponent));
    }

    /// Splits the qualified name `node` into `scope` and `entity`.
    bool takeName(const Node *node) {
        ScopePath path;
        appendPath(node, nullptr, path);
        if (path.empty()) {
            return false;
        }
        entity = std::move(path.back());
        path.pop_back();
        scope = std::move(path);
        return true;
    }

    // ===== Referenced types =====

    /// Whether `node` is a type with a name this classification can file,
    /// rather than a built-in type, a pointer or a function type.
    bool isNamedType(const Node *node) const {
        switch (node->getKind()) {
        case Node::KNestedName:
        case Node::KNameWithTemplateArgs:
        case Node::KLocalName:
        case Node::KModuleEntity:
        case Node::KGlobalQualifiedName:
        case Node::KSpecialSubstitution:
        case Node::KExpandedSpecialSubstitution:
        case Node::KClosureTypeName:
        case Node::KUnnamedTypeName:
            return true;
        case Node::KAbiTagAttr:
            return isNamedType(static_cast<const AbiTagAttr *>(node)->Base);
        case Node::KNameType:
            return isSourceText(static_cast<const NameType *>(node)->getName());
        default:
            return false;
        }
    }

    /// Whether types inside `node` are used as types — a pointer's pointee,
    /// a function type's parameters, a template argument list — so the walk
    /// goes on into it. An expression stops the walk: a name inside it may
    /// be a variable or a function.
    static bool isTypeConstructor(const Node *node) {
        switch (node->getKind()) {
        case Node::KPointerType:
        case Node::KReferenceType:
        case Node::KQualType:
        case Node::KArrayType:
        case Node::KFunctionType:
        case Node::KPointerToMemberType:
        case Node::KTemplateArgs:
        case Node::KTemplateArgumentPack:
        case Node::KParameterPackExpansion:
        case Node::KParameterPack:
        case Node::KElaboratedTypeSpefType:
        case Node::KVendorExtQualType:
        case Node::KPostfixQualifiedType:
        case Node::KVectorType:
        case Node::KPixelVectorType:
        case Node::KTransformedType:
        case Node::KNodeArrayNode:
        case Node::KForwardTemplateReference:
            return true;
        default:
            return false;
        }
    }

    template <typename Field>
    static void appendChild(const Field &field, std::vector<const Node *> &children) {
        if constexpr (std::is_convertible_v<Field, const Node *>) {
            if (field != nullptr) {
                children.push_back(field);
            }
        } else if constexpr (std::is_same_v<Field, NodeArray>) {
            for (Node *child : field) {
                if (child != nullptr) {
                    children.push_back(child);
                }
            }
        }
    }

    template <typename NodeType>
    static void appendChildren(const NodeType *node, std::vector<const Node *> &children) {
        node->match([&](const auto &... fields) {
            (appendChild(fields, children), ...);
        });
    }

    static void appendChildren(const ForwardTemplateReference *node, std::vector<const Node *> &children) {
        if (node->Ref != nullptr) {
            children.push_back(node->Ref);
        }
    }

    static std::vector<const Node *> childrenOf(const Node *node) {
        std::vector<const Node *> children;
        node->visit([&](const auto *concreteNode) {
            appendChildren(concreteNode, children);
        });
        return children;
    }

    /// Records every named type `node` uses as a type.
    void collectTypes(const Node *node, int depth) {
        if (node == nullptr || depth > maximumTypeDepth) {
            return;
        }
        if (isNamedType(node)) {
            ScopePath path;
            appendPath(node, nullptr, path);
            for (const ScopeComponent &component : path) {
                collectTypes(component.templateArguments, depth + 1);
            }
            if (!path.empty()) {
                referencedTypes.push_back(std::move(path));
            }
            return;
        }
        if (!isTypeConstructor(node)) {
            return;
        }
        for (const Node *child : childrenOf(node)) {
            collectTypes(child, depth + 1);
        }
    }

    void collectTemplateArgumentTypes(const ScopePath &path) {
        for (const ScopeComponent &component : path) {
            collectTypes(component.templateArguments, 0);
            if (component.function != nullptr) {
                collectFunctionSignatureTypes(component.function);
            }
        }
    }

    void collectFunctionSignatureTypes(const FunctionEncoding *encoding) {
        for (Node *parameter : encoding->getParams()) {
            collectTypes(parameter, 0);
        }
        collectTypes(encoding->getReturnType(), 0);
    }

    // ===== Analysis =====

    bool analyzeFunction(const FunctionEncoding *encoding) {
        if (!takeName(encoding->getName())) {
            return false;
        }
        function = encoding;
        kind = CPlusPlusDemanglerSymbolKindFunction;
        const Node *entityName = entity.name == nullptr ? nullptr : withoutAbiTags(entity.name);
        if (entityName != nullptr && entityName->getKind() == Node::KCtorDtorName) {
            static_cast<const CtorDtorName *>(entityName)->match([&](const Node *, bool isDestructor, int variant) {
                kind = isDestructor ? CPlusPlusDemanglerSymbolKindDestructor : CPlusPlusDemanglerSymbolKindConstructor;
                constructorOrDestructorVariant = variant;
            });
        }
        Qualifiers cvQualifiers = encoding->getCVQuals();
        if (cvQualifiers & QualConst) {
            qualifiers |= CPlusPlusDemanglerQualifierConst;
        }
        if (cvQualifiers & QualVolatile) {
            qualifiers |= CPlusPlusDemanglerQualifierVolatile;
        }
        if (cvQualifiers & QualRestrict) {
            qualifiers |= CPlusPlusDemanglerQualifierRestrict;
        }
        if (encoding->getRefQual() == FrefQualLValue) {
            qualifiers |= CPlusPlusDemanglerQualifierLValueReference;
        } else if (encoding->getRefQual() == FrefQualRValue) {
            qualifiers |= CPlusPlusDemanglerQualifierRValueReference;
        }
        collectFunctionSignatureTypes(encoding);
        collectTemplateArgumentTypes(scope);
        collectTypes(entity.templateArguments, 0);
        return true;
    }

    /// A function, or else a variable.
    bool analyzeEncoding(const Node *encoding) {
        if (encoding->getKind() == Node::KFunctionEncoding) {
            return analyzeFunction(static_cast<const FunctionEncoding *>(encoding));
        }
        if (!takeName(encoding)) {
            return false;
        }
        kind = CPlusPlusDemanglerSymbolKindVariable;
        collectTemplateArgumentTypes(scope);
        collectTypes(entity.templateArguments, 0);
        return true;
    }

    /// A name about a type: filed under the type when it has a name, at
    /// global scope otherwise.
    bool analyzeTypeTarget(const Node *type) {
        if (!isNamedType(type)) {
            unnamedEntity = type;
            collectTypes(type, 0);
            return true;
        }
        appendPath(type, nullptr, scope);
        if (scope.empty()) {
            return false;
        }
        entity = scope.back();
        entity.templateArguments = nullptr;
        entity.printedName.clear();
        entity.printedBaseName.clear();
        collectTemplateArgumentTypes(scope);
        return true;
    }

    bool analyzeSpecialName(std::string_view special, const Node *child) {
        struct SpecialKind {
            std::string_view prefix;
            CPlusPlusDemanglerSymbolKind kind;
        };
        static constexpr SpecialKind aboutAType[] = {
            {"vtable for ", CPlusPlusDemanglerSymbolKindVirtualTable},
            {"VTT for ", CPlusPlusDemanglerSymbolKindVirtualTableTable},
            {"typeinfo for ", CPlusPlusDemanglerSymbolKindTypeInfo},
            {"typeinfo name for ", CPlusPlusDemanglerSymbolKindTypeInfoName},
        };
        static constexpr SpecialKind aboutAFunction[] = {
            {"non-virtual thunk to ", CPlusPlusDemanglerSymbolKindNonVirtualThunk},
            {"virtual thunk to ", CPlusPlusDemanglerSymbolKindVirtualThunk},
            {"covariant return thunk to ", CPlusPlusDemanglerSymbolKindCovariantReturnThunk},
        };
        static constexpr SpecialKind aboutAVariable[] = {
            {"guard variable for ", CPlusPlusDemanglerSymbolKindGuardVariable},
            {"reference temporary for ", CPlusPlusDemanglerSymbolKindReferenceTemporary},
            {"thread-local wrapper routine for ", CPlusPlusDemanglerSymbolKindThreadLocalWrapper},
            {"thread-local initialization routine for ", CPlusPlusDemanglerSymbolKindThreadLocalInitializer},
        };
        static constexpr SpecialKind aboutSomethingUnnamed[] = {
            {"template parameter object for ", CPlusPlusDemanglerSymbolKindTemplateParameterObject},
            {"initializer for module ", CPlusPlusDemanglerSymbolKindModuleInitializer},
        };
        for (const SpecialKind &candidate : aboutAType) {
            if (special == candidate.prefix) {
                kind = candidate.kind;
                return analyzeTypeTarget(child);
            }
        }
        for (const SpecialKind &candidate : aboutAFunction) {
            if (special == candidate.prefix) {
                if (!analyzeEncoding(child)) {
                    return false;
                }
                kind = candidate.kind;
                return true;
            }
        }
        for (const SpecialKind &candidate : aboutAVariable) {
            if (special == candidate.prefix) {
                if (!analyzeEncoding(child)) {
                    return false;
                }
                kind = candidate.kind;
                function = nullptr;
                qualifiers = 0;
                constructorOrDestructorVariant = -1;
                return true;
            }
        }
        for (const SpecialKind &candidate : aboutSomethingUnnamed) {
            if (special == candidate.prefix) {
                kind = candidate.kind;
                unnamedEntity = child;
                return true;
            }
        }
        if (special == "invocation function for block in ") {
            // The block takes the scope and name of the function it sits in,
            // but none of that function's signature.
            if (!analyzeEncoding(child)) {
                return false;
            }
            kind = CPlusPlusDemanglerSymbolKindBlockInvocation;
            function = nullptr;
            qualifiers = 0;
            constructorOrDestructorVariant = -1;
            return true;
        }
        return false;
    }

    bool analyze() {
        const Node *node = root;
        if (node->getKind() == Node::KDotSuffix) {
            static_cast<const DotSuffix *>(node)->match([&](const Node *prefix, std::string_view dotSuffix) {
                node = prefix;
                suffix = dotSuffix;
                hasSuffix = true;
            });
        }
        switch (node->getKind()) {
        case Node::KFunctionEncoding:
            return analyzeFunction(static_cast<const FunctionEncoding *>(node));
        case Node::KSpecialName: {
            bool isAnalyzed = false;
            static_cast<const SpecialName *>(node)->match([&](std::string_view special, const Node *child) {
                isAnalyzed = analyzeSpecialName(special, child);
            });
            return isAnalyzed;
        }
        case Node::KCtorVtableSpecialName: {
            // "construction vtable for First-in-Second": filed under Second,
            // the complete class being constructed.
            bool isAnalyzed = false;
            static_cast<const CtorVtableSpecialName *>(node)->match([&](const Node *firstType, const Node *secondType) {
                kind = CPlusPlusDemanglerSymbolKindConstructionVirtualTable;
                isAnalyzed = analyzeTypeTarget(secondType);
                collectTypes(firstType, 0);
            });
            return isAnalyzed;
        }
        default:
            return analyzeEncoding(node);
        }
    }

    // ===== Texts =====

    CPlusPlusDemanglerText baseNameText() {
        if (unnamedEntity != nullptr) {
            return baseName.get([this](std::string &text) {
                text = printedText(unnamedEntity);
                return true;
            });
        }
        return entity.baseNameText();
    }
};

namespace {

bool hasItaniumPrefix(const char *name, size_t length) {
    std::string_view text(name, length);
    return text.compare(0, 2, "_Z") == 0 || text.compare(0, 3, "__Z") == 0 || text.compare(0, 4, "___Z") == 0 || text.compare(0, 5, "____Z") == 0;
}

} // namespace

extern "C" {

CPlusPlusDemangler *CPlusPlusDemanglerCreate(void) {
    return new (std::nothrow) CPlusPlusDemangler();
}

void CPlusPlusDemanglerDestroy(CPlusPlusDemangler *demangler) {
    delete demangler;
}

bool CPlusPlusDemanglerParse(CPlusPlusDemangler *demangler, const char *mangledName, size_t length) {
    demangler->clear();
    if (mangledName == nullptr || !hasItaniumPrefix(mangledName, length)) {
        return false;
    }
    demangler->input.assign(mangledName, length);
    demangler->parser.reset(demangler->input.data(), demangler->input.data() + demangler->input.size());
    const Node *root = demangler->parser.parse();
    if (root == nullptr) {
        return false;
    }
    demangler->root = root;
    if (!demangler->analyze()) {
        demangler->clear();
        return false;
    }
    return true;
}

CPlusPlusDemanglerSymbolKind CPlusPlusDemanglerGetKind(const CPlusPlusDemangler *demangler) {
    return demangler->kind;
}

CPlusPlusDemanglerText CPlusPlusDemanglerGetDemangledName(CPlusPlusDemangler *demangler) {
    return demangler->demangledName.get([demangler](std::string &text) {
        if (demangler->root == nullptr) {
            return false;
        }
        text = printedText(demangler->root);
        return true;
    });
}

size_t CPlusPlusDemanglerGetScopeComponentCount(const CPlusPlusDemangler *demangler) {
    return demangler->scope.size();
}

CPlusPlusDemanglerText CPlusPlusDemanglerGetScopeComponentName(CPlusPlusDemangler *demangler, size_t componentIndex) {
    if (componentIndex >= demangler->scope.size()) {
        return CPlusPlusDemanglerText{nullptr, 0};
    }
    return demangler->scope[componentIndex].nameText();
}

CPlusPlusDemanglerText CPlusPlusDemanglerGetScopeComponentBaseName(CPlusPlusDemangler *demangler, size_t componentIndex) {
    if (componentIndex >= demangler->scope.size()) {
        return CPlusPlusDemanglerText{nullptr, 0};
    }
    return demangler->scope[componentIndex].baseNameText();
}

CPlusPlusDemanglerScopeHint CPlusPlusDemanglerGetScopeComponentHint(const CPlusPlusDemangler *demangler, size_t componentIndex) {
    if (componentIndex >= demangler->scope.size()) {
        return CPlusPlusDemanglerScopeHintNone;
    }
    return demangler->scope[componentIndex].hint;
}

CPlusPlusDemanglerText CPlusPlusDemanglerGetBaseName(CPlusPlusDemangler *demangler) {
    if (demangler->root == nullptr) {
        return CPlusPlusDemanglerText{nullptr, 0};
    }
    return demangler->baseNameText();
}

CPlusPlusDemanglerText CPlusPlusDemanglerGetTemplateArguments(CPlusPlusDemangler *demangler) {
    return demangler->templateArguments.get([demangler](std::string &text) {
        if (demangler->unnamedEntity != nullptr || demangler->entity.templateArguments == nullptr) {
            return false;
        }
        text = printedText(demangler->entity.templateArguments);
        return true;
    });
}

CPlusPlusDemanglerText CPlusPlusDemanglerGetParameters(CPlusPlusDemangler *demangler) {
    return demangler->parameters.get([demangler](std::string &text) {
        if (demangler->function == nullptr) {
            return false;
        }
        OutputBuffer buffer;
        buffer += "(";
        demangler->function->getParams().printWithComma(buffer);
        buffer += ")";
        text.assign(buffer.getBuffer() == nullptr ? "" : buffer.getBuffer(), buffer.getCurrentPosition());
        std::free(buffer.getBuffer());
        return true;
    });
}

CPlusPlusDemanglerText CPlusPlusDemanglerGetReturnType(CPlusPlusDemangler *demangler) {
    return demangler->returnType.get([demangler](std::string &text) {
        if (demangler->function == nullptr || demangler->function->getReturnType() == nullptr) {
            return false;
        }
        text = printedText(demangler->function->getReturnType());
        return true;
    });
}

CPlusPlusDemanglerText CPlusPlusDemanglerGetSuffix(CPlusPlusDemangler *demangler) {
    if (!demangler->hasSuffix) {
        return CPlusPlusDemanglerText{nullptr, 0};
    }
    return CPlusPlusDemanglerText{demangler->suffix.data(), demangler->suffix.size()};
}

uint32_t CPlusPlusDemanglerGetFunctionQualifiers(const CPlusPlusDemangler *demangler) {
    return demangler->qualifiers;
}

int32_t CPlusPlusDemanglerGetConstructorOrDestructorVariant(const CPlusPlusDemangler *demangler) {
    return demangler->constructorOrDestructorVariant;
}

size_t CPlusPlusDemanglerGetReferencedTypeCount(const CPlusPlusDemangler *demangler) {
    return demangler->referencedTypes.size();
}

size_t CPlusPlusDemanglerGetReferencedTypeComponentCount(const CPlusPlusDemangler *demangler, size_t typeIndex) {
    if (typeIndex >= demangler->referencedTypes.size()) {
        return 0;
    }
    return demangler->referencedTypes[typeIndex].size();
}

CPlusPlusDemanglerText CPlusPlusDemanglerGetReferencedTypeComponentName(CPlusPlusDemangler *demangler, size_t typeIndex, size_t componentIndex) {
    if (typeIndex >= demangler->referencedTypes.size() || componentIndex >= demangler->referencedTypes[typeIndex].size()) {
        return CPlusPlusDemanglerText{nullptr, 0};
    }
    return demangler->referencedTypes[typeIndex][componentIndex].nameText();
}

} // extern "C"
