import Foundation
import Testing

/// What `MachOCodeReferences` may and may not spell, checked on its source:
/// the core knows no language, reads image memory only through
/// `CrossReferenceMemory`, and strips pointers with the platform's mask. The
/// language layers that plug into it (MachOObjCSection's
/// `ObjCCodeReferences`, MachOSwiftSection's `CrossReferenceAnalysis`) keep
/// scans of their own.
@Suite
struct SourceScanTests {
    // MARK: - No runtime names

    /// The runtime's names belong to the language layers: a recognition the
    /// core spelled would make it know a language.
    @Test func coreSpellsNoRuntimeSymbolName() throws {
        var offendingLines: [String] = []
        for fileURL in try Self.moduleSourceFiles() {
            for (lineNumber, line) in try Self.lines(of: fileURL) where Self.spellsARuntimeSymbolName(line) {
                offendingLines.append("\(fileURL.lastPathComponent):\(lineNumber): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offendingLines.isEmpty, "the runtime's names belong to the language layers:\n\(offendingLines.joined(separator: "\n"))")
    }

    // MARK: - Memory access

    /// The one file allowed to turn an address into a pointer.
    static let inProcessMemoryFileName = "InProcessCrossReferenceMemory.swift"

    /// An address turned into a pointer anywhere else reads the process's
    /// memory whatever the image set was made from.
    @Test func onlyInProcessMemoryTurnsAddressesIntoPointers() throws {
        var offendingLines: [String] = []
        let files = try Self.moduleSourceFiles()
        #expect(files.contains { $0.lastPathComponent == Self.inProcessMemoryFileName }, "the scan does not see \(Self.inProcessMemoryFileName)")
        for fileURL in files where fileURL.lastPathComponent != Self.inProcessMemoryFileName {
            for (lineNumber, line) in try Self.lines(of: fileURL) {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), Self.turnsAnAddressIntoAPointer(code) else { continue }
                offendingLines.append("\(fileURL.lastPathComponent):\(lineNumber): \(code)")
            }
        }
        #expect(offendingLines.isEmpty, "read through `CrossReferenceMemory`:\n\(offendingLines.joined(separator: "\n"))")
    }

    // MARK: - Address masks

    /// Fields of a fixup format that look like an address mask and are none:
    /// decoding a file reads them, and no process pointer is stripped with
    /// them. Shrink-only; each entry says which field it is.
    private static let fixupFormatFields: [String: [String]] = [
        // `dyld_cache_slide_pointer5.runtimeOffset`, 34 bits (slide info v5).
        "FileCrossReferenceMemory.swift": ["raw & 0x3_FFFF_FFFF"],
    ]

    /// A pointer read out of the process's memory is stripped with
    /// `InProcessContext.addressMask`, never a constant: a Mac's user
    /// addresses fit in 47 bits and an iPhone's in 36, with an arm64e
    /// signature starting right above them.
    @Test func coreDefinesNoAddressMaskConstant() throws {
        var offendingLines: [String] = []
        for fileURL in try Self.moduleSourceFiles() {
            let allowedFields = Self.fixupFormatFields[fileURL.lastPathComponent] ?? []
            for (lineNumber, line) in try Self.lines(of: fileURL) {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), Self.containsAnAddressMask(code), !allowedFields.contains(where: code.contains) else { continue }
                offendingLines.append("\(fileURL.lastPathComponent):\(lineNumber): \(code)")
            }
        }
        #expect(offendingLines.isEmpty, "strip with `InProcessContext.addressMask`:\n\(offendingLines.joined(separator: "\n"))")
    }

    // MARK: - The scans themselves

    /// The scans must see what they look for, and nothing else — their
    /// silence proves nothing otherwise.
    @Test func theScansDiscriminate() {
        #expect(Self.spellsARuntimeSymbolName(#"if strcmp(name, "_objc_msgSend") == 0 {"#))
        #expect(Self.spellsARuntimeSymbolName(#"strncmp(name, "_swift_getTypeByMangledNameIn", 29)"#))
        #expect(!Self.spellsARuntimeSymbolName("/// `objc_msgSend` copies in the cache"))
        #expect(!Self.spellsARuntimeSymbolName(#"sectionName == "__got""#))

        #expect(Self.turnsAnAddressIntoAPointer("guard let slot = UnsafeRawPointer(bitPattern: address) else {"))
        #expect(Self.turnsAnAddressIntoAPointer("let name = UnsafePointer<CChar>(bitPattern: string)"))
        #expect(Self.turnsAnAddressIntoAPointer("UnsafeMutableRawPointer(bitPattern: 0x1000)"))
        #expect(!Self.turnsAnAddressIntoAPointer("let key = UInt(bitPattern: pointer)"))
        #expect(!Self.turnsAnAddressIntoAPointer("let raw = UnsafeRawPointer(bytes + index)"))

        #expect(Self.containsAnAddressMask("let target = UInt(value & 0x0000_7FFF_FFFF_FFFF)"))
        #expect(Self.containsAnAddressMask("value & 0x0000_000F_FFFF_FFFF"))
        #expect(!Self.containsAnAddressMask("value & 0xFFFF_FFFF"))
        #expect(!Self.containsAnAddressMask("value == 0x7FFF_FFFF_FFFF_FFFF"))
        #expect(!Self.containsAnAddressMask("value & 0x0000_7FFF_FFFF_F000"))
    }

    // MARK: - Helpers

    private static let runtimeSymbolLiteral = try! NSRegularExpression(pattern: #""[^"]*(objc_|swift_)[^"]*""#)

    static func spellsARuntimeSymbolName(_ line: String) -> Bool {
        let code = line.trimmingCharacters(in: .whitespaces)
        guard !code.hasPrefix("//") else { return false }
        return runtimeSymbolLiteral.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }

    private static let pointerFromAddress = try! NSRegularExpression(pattern: #"Unsafe(Mutable)?(Raw)?Pointer(<[^>]*>)?\(bitPattern:"#)

    static func turnsAnAddressIntoAPointer(_ code: String) -> Bool {
        pointerFromAddress.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }

    private static let hexadecimalLiteral = try! NSRegularExpression(pattern: #"\b0x[0-9A-Fa-f_]+\b"#)

    /// A hexadecimal literal that is a run of 33 to 62 one bits from bit 0:
    /// the width of a user address on some platform.
    static func containsAnAddressMask(_ code: String) -> Bool {
        hexadecimalLiteral.matches(in: code, range: NSRange(code.startIndex..., in: code)).contains { match in
            guard let range = Range(match.range, in: code),
                  let value = UInt64(code[range].dropFirst(2).filter { $0 != "_" }, radix: 16)
            else { return false }
            return value & (value &+ 1) == 0 && (33 ... 62).contains(value.nonzeroBitCount)
        }
    }

    private static func lines(of fileURL: URL) throws -> [(Int, String)] {
        try String(contentsOf: fileURL, encoding: .utf8).components(separatedBy: .newlines).enumerated().map { ($0.offset + 1, $0.element) }
    }

    /// Every Swift file of `Sources/MachOCodeReferences`.
    private static func moduleSourceFiles() throws -> [URL] {
        let moduleDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MachOCodeReferencesTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/MachOCodeReferences")
        let enumerator = try #require(FileManager.default.enumerator(at: moduleDirectory, includingPropertiesForKeys: nil))
        var files: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            files.append(fileURL)
        }
        #expect(files.count >= 15, "found only \(files.count) sources under \(moduleDirectory.path)")
        return files
    }
}
