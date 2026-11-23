import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import MachODependencies
import MachOFixtureSupport
@testable import CPlusPlusSymbols

/// Shows what the class index recovers from `Tests/ClassIndexDemo/ClassIndexDemo.cpp`:
///
///     swift test --filter ClassIndexDemoTests
///
/// The file is compiled into `libZoo.dylib`, which exports `zoo::Animal`,
/// and `libFarm.dylib`, whose hidden classes derive from it and are
/// stripped of their names. The test prints every class of `libFarm.dylib`
/// with its bases and vtables, each slot named by its own symbol or after
/// the base function it overrides.
@Suite
struct ClassIndexDemoTests {
    private struct Built {
        let libraryURL: URL
        let imageURL: URL
    }

    private static let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ClassIndexDemo/ClassIndexDemo.cpp")

    /// `libZoo.dylib` and `libFarm.dylib`, the second linked without its
    /// local symbols (`-Wl,-x`, as `strip -x` would leave it).
    private static func build() throws -> Built {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let compiler = FixtureCompiler.shared
        let libraryURL = try compiler.dynamicLibrary(named: "Zoo", language: .cPlusPlus, source: source, arguments: ["-DCLASS_INDEX_DEMO_LIBRARY"])
        let imageURL = try compiler.dynamicLibrary(named: "Farm", language: .cPlusPlus, source: source, arguments: ["-L", libraryURL.deletingLastPathComponent().path, "-lZoo", "-Wl,-x"])
        return Built(libraryURL: libraryURL, imageURL: imageURL)
    }

    @Test func printWhatTheClassIndexRecoversFromTheDemo() throws {
        let built = try Self.build()
        let image = try HostSlice.machOFile(at: built.imageURL)
        let searchPaths: [DependencySearchPath] = [.machOFile(path: built.libraryURL.path), .systemDyldSharedCache]
        let store = CPlusPlusClassIndexStore.shared
        let classes = store.classes(in: image)
        var lines = ["\(built.imageURL.lastPathComponent): \(classes.count) classes, \(classes.count(where: { !$0.hasTypeInfoSymbol })) of them without a typeinfo symbol", ""]
        for polymorphicClass in classes {
            lines.append(contentsOf: Self.describe(polymorphicClass, tables: store.virtualTables(of: polymorphicClass, in: image, dependencySearchPaths: searchPaths)))
            lines.append("")
        }
        print(lines.joined(separator: "\n"))
        #expect(classes.contains { $0.qualifiedName == "farm::Dog" })
    }

    private static func describe(_ polymorphicClass: CPlusPlusClass, tables: [CPlusPlusVirtualTable]) -> [String] {
        let bases = polymorphicClass.bases.map { base in
            let place = switch base.location {
            case .sameImage: "this image"
            case .otherImage(let installName): installName ?? "another image"
            }
            return (base.isPublic ? "public " : "") + (base.isVirtual ? "virtual " : "") + "\(base.qualifiedName) (offset \(base.offset), \(place))"
        }
        var facts = ["typeinfo at 0x" + String(polymorphicClass.typeInfoOffset, radix: 16)]
        facts.append(polymorphicClass.hasTypeInfoSymbol ? "typeinfo symbol kept" : "no typeinfo symbol: found through its typeinfo")
        if !polymorphicClass.hasUniqueTypeInfo {
            facts.append("typeinfo not unique")
        }
        if !polymorphicClass.inheritanceShape.isEmpty {
            facts.append("inheritance shape \(polymorphicClass.inheritanceShape.rawValue)")
        }
        var lines = ["class \(polymorphicClass.qualifiedName)" + (bases.isEmpty ? "" : " : " + bases.joined(separator: ", ")) + "  // " + facts.joined(separator: "; ")]
        if tables.isEmpty {
            lines.append("    (no vtable)")
        }
        for table in tables {
            let heading = table.isPrimary ? "primary vtable" : "secondary vtable of \(table.subobjectClassName ?? "an unknown base") at offset \(-table.offsetToTop)"
            lines.append("    \(heading), address point 0x\(String(table.addressPointOffset, radix: 16))")
            for function in table.functions {
                lines.append("      [\(function.slotIndex)] " + describe(function))
            }
        }
        return lines
    }

    private static func describe(_ function: CPlusPlusVirtualFunction) -> String {
        let name: String
        if let symbolName = function.symbolName {
            name = symbolName.demangledName
        } else if let baseName = function.baseFunction?.name {
            name = "\(baseName.demangledName)  (stripped; named after the base)"
        } else {
            name = "<no name>"
        }
        let relation = function.baseFunction.map { ($0.isInherited ? "inherits from " : "overrides ") + $0.className } ?? "introduced here"
        let implementation = switch function.implementation {
        case .function(let offset): "at 0x" + String(offset, radix: 16)
        case .imported(_, let installName): "bound from \(installName ?? "a flat lookup")"
        case .otherImage(let address): "in another image at 0x" + String(address, radix: 16)
        case .pureVirtual: "pure virtual"
        case .deletedVirtual: "deleted"
        }
        return "\(name)  // \(relation); \(implementation)"
    }
}
