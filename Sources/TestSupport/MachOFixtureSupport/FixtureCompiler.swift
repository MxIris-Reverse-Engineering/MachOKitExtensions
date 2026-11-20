#if os(macOS)
import Foundation
import OSToolbox

/// Compiles a small library while the tests run, through `xcrun`.
///
/// A test that needs a binary of a precise shape — a fixup format, a stripped
/// symbol table, a language feature — builds it from source here instead of
/// checking a binary in. The same name, language, source and arguments are
/// compiled once per process, and a failure is kept and rethrown the same way;
/// every product sits in a temporary directory the process removes when it
/// exits.
public struct FixtureCompiler: Sendable {
    public enum Language: String, Hashable, Sendable, CaseIterable {
        case c
        case cPlusPlus
        case swift

        fileprivate var sourceFileExtension: String {
            switch self {
            case .c: "c"
            case .cPlusPlus: "cpp"
            case .swift: "swift"
            }
        }
    }

    /// The compiler every test shares, so that two tests asking for the same
    /// library get the same file.
    public static let shared = FixtureCompiler()

    private init() {}

    /// Compiles `source` into `lib<name>.dylib` and returns its URL.
    ///
    /// The library's install name is `@rpath/lib<name>.dylib`. `arguments` go
    /// to the compiler driver after the defaults, so they can link another
    /// library this compiler built (`-L <its directory> -l<its name>`) or ask
    /// the linker for more (`-Wl,-x` drops the local symbols, as `strip -x`
    /// does).
    public func dynamicLibrary(named name: String, language: Language, source: String, arguments: [String] = []) throws -> URL {
        let request = FixtureBuildRequest(name: name, language: language, source: source, arguments: arguments)
        return try FixtureBuilds.product(for: request)
    }

    /// The directory the libraries of this process are written to.
    public var productsDirectory: URL {
        fixtureProductsDirectory
    }
}

/// A compiler run failed. Carries the command and everything it wrote to
/// standard error.
public struct FixtureCompilationError: Error, CustomStringConvertible {
    public let command: [String]
    public let terminationStatus: Int32
    public let diagnostics: String

    public var description: String {
        "xcrun \(command.joined(separator: " ")) exited with \(terminationStatus):\n\(diagnostics)"
    }
}

/// What one build compiles: a request the compiler answers once per process.
private struct FixtureBuildRequest: Hashable, Sendable {
    let name: String
    let language: FixtureCompiler.Language
    let source: String
    let arguments: [String]
}

/// Where this process writes its libraries.
private let fixtureProductsDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MachOFixtureSupport-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")

/// Removes ``fixtureProductsDirectory`` when the process exits; evaluated
/// before the first build.
private let removesProductsAtExit: Void = {
    atexit {
        try? FileManager.default.removeItem(at: fixtureProductsDirectory)
    }
}()

/// The products of this process, each built once.
private enum FixtureBuilds {
    // One lock for every build: the compiles are few, and a request that
    // waits behind the same request's build then finds it done. A failure is
    // kept as well, and thrown again.
    private static let products = Mutex<[FixtureBuildRequest: Result<URL, any Error>]>([:])

    static func product(for request: FixtureBuildRequest) throws -> URL {
        _ = removesProductsAtExit
        return try products.withLock { products in
            if let product = products[request] {
                return try product.get()
            }
            let product = Result { try build(request, index: products.count) }
            products[request] = product
            return try product.get()
        }
    }

    private static func build(_ request: FixtureBuildRequest, index: Int) throws -> URL {
        let directory = fixtureProductsDirectory.appendingPathComponent("\(index)-\(request.name)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("\(request.name).\(request.language.sourceFileExtension)")
        try request.source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let libraryName = "lib\(request.name).dylib"
        let productURL = directory.appendingPathComponent(libraryName)
        let installName = "@rpath/\(libraryName)"
        let command: [String] = switch request.language {
        case .c:
            ["clang", "-dynamiclib", sourceURL.path, "-o", productURL.path, "-install_name", installName]
        case .cPlusPlus:
            ["clang++", "-dynamiclib", sourceURL.path, "-o", productURL.path, "-install_name", installName]
        case .swift:
            ["swiftc", "-emit-library", "-module-name", request.name, sourceURL.path, "-o", productURL.path, "-Xlinker", "-install_name", "-Xlinker", installName]
        }
        try run(command + request.arguments)
        return productURL
    }

    private static func run(_ command: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = command
        let standardErrorPipe = Pipe()
        process.standardError = standardErrorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        // Drain before waiting, or a long diagnostic fills the pipe and both
        // sides wait on each other.
        let diagnostics = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureCompilationError(
                command: command,
                terminationStatus: process.terminationStatus,
                diagnostics: String(decoding: diagnostics, as: UTF8.self)
            )
        }
    }
}
#endif
