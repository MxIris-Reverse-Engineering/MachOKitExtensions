import Foundation
import Testing

/// The reading modules tell readers apart through `asMachOImage` /
/// `asMachOFile` / `underlyingReader` (the MachOKitExtensions module), never
/// through a cast to `MachOImage` / `MachOFile`.
///
/// A cast cannot see through a host's wrapper (MachOKitUI's `MachOImageSource`
/// and `MachOFileSource`), so every one of them treated a wrapper as neither
/// reader: most quietly dropped what they work out, and an in-process read
/// trapped. MachOSwiftSection scans its own modules the same way; this scan
/// covers the two that moved here from it.
@Suite
struct ReaderKindCastScanTests {
    @Test("no reading module tells readers apart with a cast")
    func readingModulesDoNotCastReaders() throws {
        let sourceFiles = try Self.readingModuleSourceFiles()
        try #require(!sourceFiles.isEmpty, "found no source file to scan under Sources/MachOReading or Sources/MachOResolving")
        var offendingLines: [String] = []
        for fileURL in sourceFiles {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            for (lineNumber, line) in contents.components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), Self.castsToAConcreteReader(code) else { continue }
                offendingLines.append("\(fileURL.lastPathComponent):\(lineNumber + 1): \(code)")
            }
        }
        #expect(
            offendingLines.isEmpty,
            """
            ask `asMachOImage` / `asMachOFile` / `underlyingReader` what a reader is, so a wrapper answers \
            for the reader it wraps:
            \(offendingLines.joined(separator: "\n"))
            """
        )
    }

    /// The scan must be able to see a cast, and must not invent one — its
    /// silence proves nothing otherwise.
    @Test("the scan sees a reader cast and nothing else")
    func theScanDiscriminates() {
        #expect(Self.castsToAConcreteReader("if let machOImage = machO as? MachOImage {"))
        #expect(Self.castsToAConcreteReader("if machO is MachOFile {"))
        #expect(Self.castsToAConcreteReader("let machOFile = machO as! MachOFile"))
        #expect(Self.castsToAConcreteReader("if let machOImageContext = context as? MachOContext<MachOImage> {"))
        #expect(Self.castsToAConcreteReader("case let machOFile as MachOFile: machOFile.imagePath"))

        #expect(!Self.castsToAConcreteReader("extension ReadingContext where Self == MachOContext<MachOImage> {"))
        #expect(!Self.castsToAConcreteReader("if let machOImage = machO.asMachOImage {"))
        #expect(!Self.castsToAConcreteReader("let machOFile: MachOFile = fileImage"))
        #expect(!Self.castsToAConcreteReader("if let machOImages = machO as? MachOImageCollection {"))
    }

    private static let readerCastExpression = try! NSRegularExpression(
        pattern: #"\b(as[?!]?|is)\s+(MachOImage|MachOFile|MachOContext<\s*MachO(Image|File)\s*>)(?![A-Za-z0-9_])"#
    )

    private static func castsToAConcreteReader(_ code: String) -> Bool {
        readerCastExpression.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }

    /// Every Swift file of MachOReading and MachOResolving. The
    /// MachOKitExtensions module is left out: `asMachOImage`, `asMachOFile`
    /// and `underlyingReader` are where the casts belong.
    private static func readingModuleSourceFiles() throws -> [URL] {
        let sourcesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MachOReadingTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources")
        var files: [URL] = []
        for moduleName in ["MachOReading", "MachOResolving"] {
            let moduleDirectory = sourcesDirectory.appendingPathComponent(moduleName)
            let enumerator = try #require(FileManager.default.enumerator(at: moduleDirectory, includingPropertiesForKeys: nil))
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                files.append(fileURL)
            }
        }
        return files
    }
}
