import Foundation
import Testing
import MachOKit
import CPlusPlusDemangling

/// The C interface over the vendored Itanium demangler.
@Suite
struct CPlusPlusDemanglingTests {
    private final class Demangler {
        let pointer: OpaquePointer

        init() throws {
            pointer = try #require(CPlusPlusDemanglerCreate())
        }

        deinit {
            CPlusPlusDemanglerDestroy(pointer)
        }

        func parse(_ mangledName: String) -> Bool {
            var mangledName = mangledName
            return mangledName.withUTF8 { bytes in
                bytes.withMemoryRebound(to: CChar.self) { characters in
                    CPlusPlusDemanglerParse(pointer, characters.baseAddress, characters.count)
                }
            }
        }

        var demangledName: String? {
            Self.string(CPlusPlusDemanglerGetDemangledName(pointer))
        }

        var scopeComponentCount: Int {
            CPlusPlusDemanglerGetScopeComponentCount(pointer)
        }

        static func string(_ text: CPlusPlusDemanglerText) -> String? {
            guard let bytes = text.bytes else { return nil }
            return String(decoding: UnsafeRawBufferPointer(start: bytes, count: text.length), as: UTF8.self)
        }
    }

    @Test func demanglerParsesTheSymbolTableSpellingOfAnItaniumName() throws {
        let demangler = try Demangler()
        #expect(demangler.parse("__ZNK4llvm5Value4dumpEv"))
        #expect(demangler.demangledName == "llvm::Value::dump() const")
        #expect(demangler.scopeComponentCount == 2)
    }

    @Test(arguments: ["_malloc", "__Zgarbage", "", "_Z", "$s7SwiftUI4TextVMn", "_OBJC_CLASS_$_NSObject"])
    func demanglerRejectsANameThatIsNotItaniumMangled(name: String) throws {
        let demangler = try Demangler()
        #expect(!demangler.parse(name))
    }

    @Test func demanglerReadsNothingAfterAFailedParse() throws {
        let demangler = try Demangler()
        try #require(demangler.parse("__ZN4llvm5Value4dumpEv"))
        #expect(!demangler.parse("__Zgarbage"))
        #expect(demangler.demangledName == nil)
        #expect(demangler.scopeComponentCount == 0)
        #expect(CPlusPlusDemanglerGetBaseName(demangler.pointer).bytes == nil)
    }
}

extension CPlusPlusDemanglingTests {
    private typealias SystemDemangle = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>?

    /// libc++abi's `__cxa_demangle`, which runs the same demangler.
    private static func systemDemangledName(of mangledName: String) throws -> String? {
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__cxa_demangle"), "__cxa_demangle is not loaded")
        let systemDemangle = unsafeBitCast(symbol, to: SystemDemangle.self)
        var status: Int32 = 0
        guard let demangled = mangledName.withCString({ systemDemangle($0, nil, nil, &status) }) else { return nil }
        defer { free(demangled) }
        return String(cString: demangled)
    }

    /// Every C++ name libc++ defines demangles to the same text here as with
    /// the system demangler, and fails where it fails.
    @Test func demangledNameMatchesSystemCxaDemangleForEveryCPlusPlusNameOfLibCPlusPlus() throws {
        let libCPlusPlus = try #require(MachOImage(name: "libc++"), "libc++ is not loaded")
        let names = Set(libCPlusPlus.symbols.map(\.name).filter { $0.hasPrefix("__Z") || $0.hasPrefix("___Z") })
        try #require(names.count > 1000, "libc++ should define thousands of C++ names")
        let demangler = try Demangler()
        var mismatches: [String] = []
        for name in names.sorted() {
            let ours = demangler.parse(name) ? demangler.demangledName : nil
            let system = try Self.systemDemangledName(of: name)
            if ours != system {
                mismatches.append("\(name): ours \(ours ?? "nil"), system \(system ?? "nil")")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(names.count) differ; first: \(mismatches.prefix(5).joined(separator: "; "))")
    }
}
