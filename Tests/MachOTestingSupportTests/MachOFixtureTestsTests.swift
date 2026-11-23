import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import MachOReading
import MachOFixtureSupport
import MachOTestingSupport

/// A library built for these suites: a function and a global with known names.
private enum FixtureLibrary {
    static let name = "MachOFixtureTestsLibrary"

    static let url: URL = {
        let source = """
        int machOFixtureTestsValue = 7;
        int machOFixtureTestsFunction(void) { return machOFixtureTestsValue; }
        """
        // A failed build leaves a path that does not exist; the suite's
        // initializer then fails with the fixture's error.
        return (try? FixtureCompiler.shared.dynamicLibrary(named: name, language: .c, source: source))
            ?? URL(fileURLWithPath: "/nonexistent/lib\(name).dylib")
    }()
}

/// Reads one ReadingContext value: the Mach-O magic at the start of the image.
private func magic(in context: some ReadingContext) throws -> UInt32 {
    try context.readElement(at: context.addressFromOffset(0))
}

/// A fixture given as a file on disk, loaded on demand.
@Suite
final class FileFixtureTests: MachOFixtureTests {
    override class var fixture: MachOFixture {
        MachOFixture(fileURL: FixtureLibrary.url, imageName: "lib\(FixtureLibrary.name)", loadsIntoProcess: true)
    }

    @Test("A file fixture gives the file, the image it loads as, and a context over each")
    func fixtureTestsBuildBothReadersAndAllContextsFromAFile() throws {
        #expect(machOFile.exportedSymbols.contains { $0.name == "_machOFixtureTestsFunction" })
        let loadedPath = try #require(ProcessImages.path(ofImageContaining: machOImage.ptr))
        #expect(URL(fileURLWithPath: loadedPath).resolvingSymlinksInPath() == FixtureLibrary.url.resolvingSymlinksInPath())
        #expect(machOImage.exportedSymbols.contains { $0.name == "_machOFixtureTestsValue" })
        let magicOfEachContext = try acrossAllContexts(
            file: { try magic(in: fileContext) },
            image: { try magic(in: imageContext) }
        )
        #expect(magicOfEachContext == MH_MAGIC_64)
    }

    @Test("Diverging readers are reported by the readers that diverged")
    func acrossAllReadersReportsWhichReaderDiverged() throws {
        try withKnownIssue {
            _ = try acrossAllReaders(file: { 1 }, image: { 2 })
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("MachOFile vs MachOImage diverged") }
        }
        try withKnownIssue {
            _ = try acrossAllReaders(file: { 1 }, image: { 1 }, inProcess: { 3 })
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("MachOFile vs InProcess diverged") }
        }
        try withKnownIssue {
            _ = try acrossAllContexts(file: { 1 }, image: { 2 })
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("fileContext vs imageContext diverged") }
        }
        // Agreeing readers return the file's value and record nothing.
        #expect(try acrossAllReaders(file: { 5 }, image: { 5 }, inProcess: { 5 }) == 5)
    }

    @Test("Paired subjects: one closure runs on the file's subject, then on the image's")
    func pairedSubjectsRunOneClosureOnEachReader() throws {
        var seenSubjects: [String] = []
        let value = try acrossAllReaders("file subject", "image subject") { subject in
            seenSubjects.append(subject)
            return subject.count > 0
        }
        #expect(value)
        #expect(seenSubjects == ["file subject", "image subject"])

        var seenContextTypes: [String] = []
        _ = try acrossAllContexts(machOFile.header.magic, machOImage.header.magic) { subject, context in
            seenContextTypes.append(String(describing: type(of: context)))
            return subject
        }
        #expect(seenContextTypes == [String(describing: MachOContext<MachOFile>.self), String(describing: MachOContext<MachOImage>.self)])
    }

    @Test("Paired subjects: an API taking some ReadingContext accepts the context the closure gets")
    func pairedSubjectsOpenTheContextForAnAPITakingSomeReadingContext() throws {
        let magicOfEachContext = try acrossAllContexts(machOFile.header, machOImage.header) { _, context in
            try magic(in: context)
        }
        #expect(magicOfEachContext == MH_MAGIC_64)
    }

    @Test("The readers themselves: one closure reads the file, then the image")
    func readersRunOneClosureOnEachReader() throws {
        var seenPaths: [String] = []
        let exportsFunction = try acrossAllReaders { machO in
            seenPaths.append(machO.imagePath)
            return machO.exportedSymbols.contains { $0.name == "_machOFixtureTestsFunction" }
        }
        #expect(exportsFunction)
        #expect(seenPaths.count == 2)
    }
}

/// A fixture given as an address inside an image this process already holds:
/// this test bundle, through its `#dsohandle`.
@Suite
final class AnchoredFixtureTests: MachOFixtureTests {
    override class var fixture: MachOFixture {
        MachOFixture(imageContaining: #dsohandle)
    }

    @Test("An anchored fixture is the image holding the anchor, and the file dyld loaded it from")
    func fixtureTestsReachAnImageOfThisProcessByAnAnchor() throws {
        #expect(UnsafeRawPointer(machOImage.ptr) == #dsohandle)
        let path = try #require(ProcessImages.path(ofImageContaining: #dsohandle))
        #expect(machOFile.header.fileType == machOImage.header.fileType)
        #expect(machOFile.header.ncmds == machOImage.header.ncmds)
        #expect(ProcessImages.path(ofImageContaining: machOImage.ptr) == path)
    }
}

/// A fixture that cannot be read fails the suite with an error that says why.
@Suite
struct MachOFixtureErrorTests {
    @Test("A missing file and an address in no image are reported as such")
    func unreadableFixturesThrowTheirReason() async throws {
        final class MissingFileTests: MachOFixtureTests {
            override class var fixture: MachOFixture {
                MachOFixture(fileURL: URL(fileURLWithPath: "/nonexistent/libMissing.dylib"), imageName: "libMissing", loadsIntoProcess: true)
            }
        }
        let error = await #expect(throws: MachOFixtureError.self) {
            _ = try await MissingFileTests()
        }
        guard case .fileMissing(let path)? = error else {
            Issue.record("expected fileMissing, got \(String(describing: error))")
            return
        }
        #expect(path == "/nonexistent/libMissing.dylib")
    }
}
