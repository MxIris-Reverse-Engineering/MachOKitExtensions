import Foundation
import Testing
import MachOKit
import MachOFixtureSupport

/// The compiler builds a library once per process for the same request, says
/// why a build failed, and speaks C, C++ and Swift.
@Suite
struct FixtureCompilerTests {
    private static let compiler = FixtureCompiler.shared

    @Test("The same request builds once; a different source builds again")
    func compilerBuildsEachSourceOncePerProcess() throws {
        let source = "int fixtureCompilerOnce(void) { return 1; }"
        let first = try Self.compiler.dynamicLibrary(named: "CompiledOnce", language: .c, source: source)
        let modificationDate = try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let second = try Self.compiler.dynamicLibrary(named: "CompiledOnce", language: .c, source: source)
        #expect(first == second)
        #expect(try second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modificationDate)

        let changed = try Self.compiler.dynamicLibrary(named: "CompiledOnce", language: .c, source: source + "\nint fixtureCompilerAgain(void) { return 2; }")
        #expect(changed != first)
        #expect(first.path.hasPrefix(Self.compiler.productsDirectory.path))
    }

    @Test("A failed build throws the compiler's diagnostics, and throws them again")
    func compilerFailureCarriesTheDiagnostics() throws {
        let source = "int broken(void) { return undeclaredIdentifier; }"
        let error = try #require(throws: FixtureCompilationError.self) {
            try Self.compiler.dynamicLibrary(named: "Broken", language: .c, source: source)
        }
        #expect(error.terminationStatus != 0)
        #expect(error.diagnostics.contains("undeclaredIdentifier"), "\(error.diagnostics)")
        #expect(error.command.first == "clang")
        // Kept, not rebuilt: the same error comes back.
        let again = try #require(throws: FixtureCompilationError.self) {
            try Self.compiler.dynamicLibrary(named: "Broken", language: .c, source: source)
        }
        #expect(again.diagnostics == error.diagnostics)
    }

    @Test("C++ and Swift sources become libraries that export their symbols")
    func compilerBuildsSwiftAndCPlusPlus() throws {
        let cPlusPlus = try Self.compiler.dynamicLibrary(
            named: "CompiledCPlusPlus",
            language: .cPlusPlus,
            source: "namespace compiled { int answer() { return 42; } }"
        )
        let swift = try Self.compiler.dynamicLibrary(
            named: "CompiledSwift",
            language: .swift,
            source: "public func compiledAnswer() -> Int { 42 }",
            arguments: ["-parse-as-library"]
        )
        let cPlusPlusExports = try HostSlice.machOFile(at: cPlusPlus).exportedSymbols.map(\.name)
        #expect(cPlusPlusExports.contains("__ZN8compiled6answerEv"), "\(cPlusPlusExports)")
        let swiftExports = try HostSlice.machOFile(at: swift).exportedSymbols.map(\.name)
        #expect(swiftExports.contains { $0.hasPrefix("_$s13CompiledSwift14compiledAnswer") }, "\(swiftExports)")
        let swiftFile = try HostSlice.machOFile(at: swift)
        var installNames: [String] = []
        for case .idDylib(let command) in swiftFile.loadCommands {
            installNames.append(command.dylib(in: swiftFile).name)
        }
        #expect(installNames == ["@rpath/libCompiledSwift.dylib"])
    }
}
