import Foundation
import Testing
import MachOKit
import MachOFixtureSupport
import MachOTestingSupport
import CPlusPlusSymbolsFixture
@testable import CPlusPlusSymbols

/// A suite that reads the image the C++ fixture is linked into — this test
/// bundle — both from its file and as this process loaded it.
class ClassIndexFixtureTests: MachOFixtureTests {
    override class var fixture: MachOFixture {
        // Calling into the fixture keeps every one of its classes in the image.
        _ = CPlusPlusSymbolsFixtureTouchEverything()
        return MachOFixture(imageContaining: CPlusPlusSymbolsFixtureAnchor())
    }
}

/// Two small C++ libraries compiled when a test first needs them: `Base`
/// exports a class, `Derived` derives from it through `@rpath` and is linked
/// without its local symbols, so its hidden overrides have no names. A second
/// `Derived` is linked with opcode fixups instead of chained ones.
enum ClassHierarchyLibraries {
    static let baseSource = """
    namespace library {
    class __attribute__((visibility("default"))) Base {
    public:
        virtual ~Base();
        virtual int first();
        virtual int second() const;
        virtual int third(int value);
    };
    Base::~Base() {}
    int Base::first() { return 1; }
    int Base::second() const { return 2; }
    int Base::third(int value) { return value; }
    }
    """

    static let derivedSource = """
    namespace library {
    class __attribute__((visibility("default"))) Base {
    public:
        virtual ~Base();
        virtual int first();
        virtual int second() const;
        virtual int third(int value);
    };
    }
    namespace application {
    class __attribute__((visibility("hidden"))) Derived : public library::Base {
    public:
        ~Derived() override;
        int first() override;
        int third(int value) override;
        virtual int fourth();
    };
    Derived::~Derived() {}
    int Derived::first() { return 10; }
    int Derived::third(int value) { return value * 3; }
    int Derived::fourth() { return 4; }
    }
    extern "C" __attribute__((visibility("default"))) void *makeDerived(void) { return new application::Derived(); }
    """

    struct Built: Sendable {
        let baseURL: URL
        let derivedURL: URL
        let legacyDerivedURL: URL
    }

    static func built() throws -> Built {
        let compiler = FixtureCompiler.shared
        let baseURL = try compiler.dynamicLibrary(named: "ClassHierarchyBase", language: .cPlusPlus, source: baseSource)
        // `-Wl,-x` leaves the local symbols out, as `strip -x` would.
        let linkingBase = ["-L", baseURL.deletingLastPathComponent().path, "-lClassHierarchyBase", "-Wl,-x"]
        let derivedURL = try compiler.dynamicLibrary(named: "ClassHierarchyDerived", language: .cPlusPlus, source: derivedSource, arguments: linkingBase)
        let legacyDerivedURL = try compiler.dynamicLibrary(named: "ClassHierarchyDerivedLegacy", language: .cPlusPlus, source: derivedSource, arguments: linkingBase + ["-Wl,-no_fixup_chains"])
        return Built(baseURL: baseURL, derivedURL: derivedURL, legacyDerivedURL: legacyDerivedURL)
    }
}

// MARK: - What every reader reads alike

// A file and the image loaded from it place the same data at different
// offsets, so what a test compares across readers leaves the offsets out.

/// A class without its typeinfo's offset.
struct ClassShape: Equatable, CustomStringConvertible {
    struct Base: Equatable {
        /// Where the base's typeinfo is, without the library's name: for a
        /// base in another image the file names the library it binds from,
        /// the loaded image the library dyld found the typeinfo in, and the
        /// two differ when one re-exports the other (`std::exception` is bound
        /// from libc++, which re-exports libc++abi, where it is defined).
        enum Location: Equatable {
            case sameImage
            case otherImage
        }

        let qualifiedName: String
        let mangledTypeName: String
        let isVirtual: Bool
        let isPublic: Bool
        let offset: Int
        let location: Location

        init(_ base: CPlusPlusClass.Base) {
            self.qualifiedName = base.qualifiedName
            self.mangledTypeName = base.mangledTypeName
            self.isVirtual = base.isVirtual
            self.isPublic = base.isPublic
            self.offset = base.offset
            self.location = switch base.location {
            case .sameImage: .sameImage
            case .otherImage: .otherImage
            }
        }
    }

    let qualifiedName: String
    let scopePath: [String]
    let baseName: String
    let mangledTypeName: String
    let bases: [Base]
    let inheritanceShape: CPlusPlusClass.InheritanceShape
    let hasVirtualTable: Bool
    let hasTypeInfoSymbol: Bool
    let hasUniqueTypeInfo: Bool

    init(_ polymorphicClass: CPlusPlusClass) {
        self.qualifiedName = polymorphicClass.qualifiedName
        self.scopePath = polymorphicClass.scopePath
        self.baseName = polymorphicClass.baseName
        self.mangledTypeName = polymorphicClass.mangledTypeName
        self.bases = polymorphicClass.bases.map(Base.init)
        self.inheritanceShape = polymorphicClass.inheritanceShape
        self.hasVirtualTable = polymorphicClass.hasVirtualTable
        self.hasTypeInfoSymbol = polymorphicClass.hasTypeInfoSymbol
        self.hasUniqueTypeInfo = polymorphicClass.hasUniqueTypeInfo
    }

    var description: String {
        qualifiedName
    }
}

/// A vtable without its address point's offset, and its slots without the
/// offsets of the functions they hold.
struct VirtualTableShape: Equatable {
    struct Function: Equatable {
        enum Implementation: Equatable {
            case function
            case imported(symbolName: String, installName: String?)
            case otherImage
            case pureVirtual
            case deletedVirtual
        }

        let slotIndex: Int
        let implementation: Implementation
        let symbolName: CPlusPlusSymbolName?
        let baseFunction: CPlusPlusVirtualFunction.BaseFunction?
        let name: CPlusPlusSymbolName?

        init(_ function: CPlusPlusVirtualFunction) {
            self.slotIndex = function.slotIndex
            self.implementation = switch function.implementation {
            case .function: .function
            case .imported(let symbolName, let installName): .imported(symbolName: symbolName, installName: installName)
            case .otherImage: .otherImage
            case .pureVirtual: .pureVirtual
            case .deletedVirtual: .deletedVirtual
            }
            self.symbolName = function.symbolName
            self.baseFunction = function.baseFunction
            self.name = function.name
        }
    }

    let offsetToTop: Int
    let subobjectClassName: String?
    let isPrimary: Bool
    let functions: [Function]

    init(_ table: CPlusPlusVirtualTable) {
        self.offsetToTop = table.offsetToTop
        self.subobjectClassName = table.subobjectClassName
        self.isPrimary = table.isPrimary
        self.functions = table.functions.map(Function.init)
    }

    /// Each slot's name without its scope, `nil` for a slot without one.
    var baseNames: [String?] {
        functions.map { $0.name?.baseName }
    }
}
