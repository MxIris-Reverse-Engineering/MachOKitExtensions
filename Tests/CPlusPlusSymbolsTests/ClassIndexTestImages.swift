import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import CPlusPlusSymbolsFixture

/// The images the class index tests read.
enum ClassIndexTestImages {
    /// How a test reads the fixture image.
    enum Reader: String, CaseIterable, CustomTestStringConvertible, Sendable {
        /// The image as loaded in this process.
        case processImage
        /// The same image's file on disk.
        case file

        var testDescription: String {
            rawValue
        }
    }

    /// The image the C++ fixture is linked into, as this process loaded it.
    static func fixtureImage() throws -> MachOImage {
        #expect(CPlusPlusSymbolsFixtureTouchEverything() != 0)
        var information = Dl_info()
        try #require(dladdr(CPlusPlusSymbolsFixtureAnchor(), &information) != 0)
        let header = try #require(information.dli_fbase)
        return MachOImage(ptr: header.assumingMemoryBound(to: mach_header.self))
    }

    /// The file of the image the C++ fixture is linked into: the slice this
    /// process runs.
    static func fixtureFile() throws -> MachOFile {
        #expect(CPlusPlusSymbolsFixtureTouchEverything() != 0)
        var information = Dl_info()
        try #require(dladdr(CPlusPlusSymbolsFixtureAnchor(), &information) != 0)
        let path = String(cString: try #require(information.dli_fname))
        return try hostSlice(of: URL(fileURLWithPath: path))
    }

    static func fixture(_ reader: Reader) throws -> any MachORepresentableWithCache {
        switch reader {
        case .processImage:
            try fixtureImage()
        case .file:
            try fixtureFile()
        }
    }

    /// The slice of the file at `url` for this process's architecture.
    static func hostSlice(of url: URL) throws -> MachOFile {
        switch try MachOKit.loadFromFile(url: url) {
        case .machO(let file):
            return file
        case .fat(let fatFile):
            let hostCPU = MachOImage.current().header.cpu
            let slices = try fatFile.machOFiles()
            return try #require(
                slices.first { $0.header.cpu.typeRawValue == hostCPU.typeRawValue && $0.header.cpu.subtypeRawValue & 0xFFFFFF == hostCPU.subtypeRawValue & 0xFFFFFF }
                    ?? slices.first { $0.header.cpu.typeRawValue == hostCPU.typeRawValue },
                "no slice of \(url.path) for this process"
            )
        }
    }
}

/// Two small C++ libraries compiled when a test first needs them: `Base`
/// exports a class, `Derived` derives from it through `@rpath` and is
/// stripped of its local symbols, so its hidden overrides have no names. A
/// second `Derived` is linked with opcode fixups instead of chained ones.
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

    private struct CompilationError: Swift.Error, CustomStringConvertible {
        let diagnostics: String
        var description: String { "class hierarchy library build failed:\n\(diagnostics)" }
    }

    private static let compilation: Result<Built, Swift.Error> = Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClassHierarchyLibraries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseSourceURL = directory.appendingPathComponent("Base.cpp")
        let derivedSourceURL = directory.appendingPathComponent("Derived.cpp")
        try baseSource.write(to: baseSourceURL, atomically: true, encoding: .utf8)
        try derivedSource.write(to: derivedSourceURL, atomically: true, encoding: .utf8)
        let baseURL = directory.appendingPathComponent("libClassHierarchyBase.dylib")
        let derivedURL = directory.appendingPathComponent("libClassHierarchyDerived.dylib")
        let legacyDerivedURL = directory.appendingPathComponent("libClassHierarchyDerivedLegacy.dylib")
        try run(["clang++", "-dynamiclib", baseSourceURL.path, "-o", baseURL.path, "-install_name", "@rpath/libClassHierarchyBase.dylib"])
        for (outputURL, extraArguments) in [(derivedURL, [String]()), (legacyDerivedURL, ["-Wl,-no_fixup_chains"])] {
            try run(["clang++", "-dynamiclib", derivedSourceURL.path, "-o", outputURL.path, "-install_name", "@rpath/\(outputURL.lastPathComponent)", "-L", directory.path, "-lClassHierarchyBase"] + extraArguments)
            try run(["strip", "-x", outputURL.path])
        }
        return Built(baseURL: baseURL, derivedURL: derivedURL, legacyDerivedURL: legacyDerivedURL)
    }

    static func built() throws -> Built {
        try compilation.get()
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let standardErrorPipe = Pipe()
        process.standardError = standardErrorPipe
        try process.run()
        // Drain before waiting, or a long diagnostic deadlocks both sides.
        let diagnostics = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CompilationError(diagnostics: arguments.joined(separator: " ") + "\n" + String(decoding: diagnostics, as: UTF8.self))
        }
    }
}
