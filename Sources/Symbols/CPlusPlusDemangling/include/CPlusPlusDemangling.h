#ifndef CPLUSPLUS_DEMANGLING_H
#define CPLUSPLUS_DEMANGLING_H

// A plain C interface over LLVM's Itanium demangler (libc++abi's
// `src/demangle`, vendored verbatim under `ItaniumDemangle/`), so that Swift
// reads a C++ symbol name taken apart without enabling C++ interoperability.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__has_attribute)
#if __has_attribute(enum_extensibility)
#define CPLUSPLUS_DEMANGLING_CLOSED_ENUM __attribute__((enum_extensibility(closed)))
#endif
#endif
#ifndef CPLUSPLUS_DEMANGLING_CLOSED_ENUM
#define CPLUSPLUS_DEMANGLING_CLOSED_ENUM
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// A reusable demangler. Not thread-safe: one per thread.
typedef struct CPlusPlusDemangler CPlusPlusDemangler;

/// Bytes owned by the demangler, valid until its next parse or its
/// destruction. Not NUL-terminated. `bytes` is NULL when the name has no such
/// part; an empty part has a non-NULL `bytes` and a zero `length`.
typedef struct {
    const char *bytes;
    size_t length;
} CPlusPlusDemanglerText;

/// A range of bytes of a text the demangler returned: `start` up to, not
/// including, `end`.
typedef struct {
    size_t start;
    size_t end;
} CPlusPlusDemanglerByteRange;

/// A part of a function's signature, as its own text.
typedef enum CPLUSPLUS_DEMANGLING_CLOSED_ENUM : int32_t {
    /// The text `CPlusPlusDemanglerGetParameters` returns.
    CPlusPlusDemanglerSignaturePartParameters,
    /// The text `CPlusPlusDemanglerGetReturnType` returns.
    CPlusPlusDemanglerSignaturePartReturnType,
} CPlusPlusDemanglerSignaturePart;

/// What a C++ symbol names.
typedef enum CPLUSPLUS_DEMANGLING_CLOSED_ENUM : int32_t {
    CPlusPlusDemanglerSymbolKindFunction,
    CPlusPlusDemanglerSymbolKindConstructor,
    CPlusPlusDemanglerSymbolKindDestructor,
    CPlusPlusDemanglerSymbolKindVariable,
    CPlusPlusDemanglerSymbolKindVirtualTable,
    CPlusPlusDemanglerSymbolKindVirtualTableTable,
    CPlusPlusDemanglerSymbolKindConstructionVirtualTable,
    CPlusPlusDemanglerSymbolKindTypeInfo,
    CPlusPlusDemanglerSymbolKindTypeInfoName,
    CPlusPlusDemanglerSymbolKindNonVirtualThunk,
    CPlusPlusDemanglerSymbolKindVirtualThunk,
    CPlusPlusDemanglerSymbolKindCovariantReturnThunk,
    CPlusPlusDemanglerSymbolKindGuardVariable,
    CPlusPlusDemanglerSymbolKindReferenceTemporary,
    CPlusPlusDemanglerSymbolKindThreadLocalWrapper,
    CPlusPlusDemanglerSymbolKindThreadLocalInitializer,
    CPlusPlusDemanglerSymbolKindTemplateParameterObject,
    CPlusPlusDemanglerSymbolKindModuleInitializer,
    CPlusPlusDemanglerSymbolKindBlockInvocation,
} CPlusPlusDemanglerSymbolKind;

/// What the mangling itself says a scope component is.
typedef enum CPLUSPLUS_DEMANGLING_CLOSED_ENUM : int32_t {
    /// Nothing: a namespace or a type, the mangling does not say which.
    CPlusPlusDemanglerScopeHintNone,
    /// `std`, or an anonymous namespace.
    CPlusPlusDemanglerScopeHintNamespace,
    /// A closure or unnamed type, or `std::allocator` and the other standard
    /// substitutions.
    CPlusPlusDemanglerScopeHintType,
    /// The function a local entity sits in — an Objective-C method too,
    /// which the mangling spells as a bare name.
    CPlusPlusDemanglerScopeHintFunction,
} CPlusPlusDemanglerScopeHint;

/// The cv and ref qualifiers of a member function, as a bit set.
enum {
    CPlusPlusDemanglerQualifierConst = 1 << 0,
    CPlusPlusDemanglerQualifierVolatile = 1 << 1,
    CPlusPlusDemanglerQualifierRestrict = 1 << 2,
    CPlusPlusDemanglerQualifierLValueReference = 1 << 3,
    CPlusPlusDemanglerQualifierRValueReference = 1 << 4,
};

CPlusPlusDemangler *CPlusPlusDemanglerCreate(void);
void CPlusPlusDemanglerDestroy(CPlusPlusDemangler *demangler);

/// Parses `mangledName`, `length` bytes not counting any terminator: the
/// symbol table's spelling, `__Z…` or `___Z…` for a block (`_Z…` parses too).
/// The bytes are copied. Returns false when it is not a name the demangler
/// parses; nothing may be read then.
bool CPlusPlusDemanglerParse(CPlusPlusDemangler *demangler, const char *mangledName, size_t length);

CPlusPlusDemanglerSymbolKind CPlusPlusDemanglerGetKind(const CPlusPlusDemangler *demangler);

/// The whole name, as `__cxa_demangle` prints it.
CPlusPlusDemanglerText CPlusPlusDemanglerGetDemangledName(CPlusPlusDemangler *demangler);

/// The scopes the entity sits in, outermost first. For a name about a type
/// (its vtable, its typeinfo), the last component is that type.
size_t CPlusPlusDemanglerGetScopeComponentCount(const CPlusPlusDemangler *demangler);
/// A component as C++ prints it: `vector<int, std::__1::allocator<int>>`,
/// or `foo(int)` for a function.
CPlusPlusDemanglerText CPlusPlusDemanglerGetScopeComponentName(CPlusPlusDemangler *demangler, size_t componentIndex);
/// A component without its template arguments or parameters: `vector`, `foo`.
CPlusPlusDemanglerText CPlusPlusDemanglerGetScopeComponentBaseName(CPlusPlusDemangler *demangler, size_t componentIndex);
CPlusPlusDemanglerScopeHint CPlusPlusDemanglerGetScopeComponentHint(const CPlusPlusDemangler *demangler, size_t componentIndex);

/// The entity's own name without template arguments.
CPlusPlusDemanglerText CPlusPlusDemanglerGetBaseName(CPlusPlusDemangler *demangler);
/// The entity's template arguments, `<int>`.
CPlusPlusDemanglerText CPlusPlusDemanglerGetTemplateArguments(CPlusPlusDemangler *demangler);
/// A function's parameters, `(int, char const*)`.
CPlusPlusDemanglerText CPlusPlusDemanglerGetParameters(CPlusPlusDemangler *demangler);
/// A function template specialization's return type.
CPlusPlusDemanglerText CPlusPlusDemanglerGetReturnType(CPlusPlusDemangler *demangler);
/// What follows the name after a dot, `.cold.1`.
CPlusPlusDemanglerText CPlusPlusDemanglerGetSuffix(CPlusPlusDemangler *demangler);

/// The `CPlusPlusDemanglerQualifier…` bits of a member function.
uint32_t CPlusPlusDemanglerGetFunctionQualifiers(const CPlusPlusDemangler *demangler);
/// 0 to 5 for a constructor (C0–C5) or destructor (D0–D5); -1 otherwise.
int32_t CPlusPlusDemanglerGetConstructorOrDestructorVariant(const CPlusPlusDemangler *demangler);

/// Named types the name uses as types: parameters, the return type, type
/// template arguments, the class side of a member pointer, and the base a
/// construction vtable is for. Each is a scope path, read component by
/// component; built-in types are left out.
size_t CPlusPlusDemanglerGetReferencedTypeCount(const CPlusPlusDemangler *demangler);
size_t CPlusPlusDemanglerGetReferencedTypeComponentCount(const CPlusPlusDemangler *demangler, size_t typeIndex);
CPlusPlusDemanglerText CPlusPlusDemanglerGetReferencedTypeComponentName(CPlusPlusDemangler *demangler, size_t typeIndex, size_t componentIndex);

/// Named types a part of the signature spells, ordered by where they start:
/// a template before the types its argument list spells, whose ranges sit
/// inside the template's. A qualifier is part of the name it qualifies,
/// never a type of its own; built-in types are left out. Zero when the name
/// has no such part.
size_t CPlusPlusDemanglerGetSignatureTypeCount(CPlusPlusDemangler *demangler, CPlusPlusDemanglerSignaturePart part);
/// Where the part's text spells the type, template arguments included.
CPlusPlusDemanglerByteRange CPlusPlusDemanglerGetSignatureTypeRange(CPlusPlusDemangler *demangler, CPlusPlusDemanglerSignaturePart part, size_t typeIndex);
/// The type's scope path, read component by component.
size_t CPlusPlusDemanglerGetSignatureTypeComponentCount(CPlusPlusDemangler *demangler, CPlusPlusDemanglerSignaturePart part, size_t typeIndex);
CPlusPlusDemanglerText CPlusPlusDemanglerGetSignatureTypeComponentName(CPlusPlusDemangler *demangler, CPlusPlusDemanglerSignaturePart part, size_t typeIndex, size_t componentIndex);

#ifdef __cplusplus
}
#endif

#endif
