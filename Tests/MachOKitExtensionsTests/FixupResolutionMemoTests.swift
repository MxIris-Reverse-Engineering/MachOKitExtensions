import Foundation
import Testing
import MachOKit
import MachOKitExtensions

/// `resolveRebase(fileOffset:)` and `resolveBind(fileOffset:)` remember every
/// slot they resolve. The memo used to be a dictionary held in an associated
/// object: reading it out and storing it back copied the whole dictionary on
/// every new entry, so resolving a file's slots one after another took time
/// quadratic in their number.
///
/// Each test resolves every slot of one kind in a fresh `MachOFile`, timing
/// the first batch, when the memo is nearly empty, and the last batch, when it
/// holds nearly every slot. A memo that grows in place takes about as long for
/// both; one that copies itself takes many times longer for the last. The
/// shortest of a few runs is compared, so a run the scheduler interrupted does
/// not decide the outcome.
///
/// The rebase test only shows the copying with a MachOKit whose `cache` does
/// not reopen a standalone file: with one that does, two reopenings per slot
/// cost far more than the copy.
@Suite("Fixup resolution memo")
struct FixupResolutionMemoTests {
    private static let batchSize = 2_000
    private static let runCount = 3
    /// Measured on an M3 Ultra: the copying memo took about 50 times as long
    /// for the last batch, the memo that grows in place 1.2 to 1.3 times.
    private static let maximumSlowdown = 8.0

    @Test("Resolving the last rebase slots takes about as long as the first ones")
    func rebaseMemoGrowsInPlace() throws {
        let measurement = try lastBatchSlowdown(slotSymbolName: "_rebaseSlots", slotCount: FixupSlotsLibrary.rebaseSlotCount) { machO, slotOffset in
            machO.resolveRebase(fileOffset: slotOffset) != nil
        }
        #expect(measurement.everySlotResolved)
        #expect(measurement.slowdown < Self.maximumSlowdown)
    }

    @Test("Resolving the last bind slots takes about as long as the first ones")
    func bindMemoGrowsInPlace() throws {
        let measurement = try lastBatchSlowdown(slotSymbolName: "_bindSlots", slotCount: FixupSlotsLibrary.bindSlotCount) { machO, slotOffset in
            machO.resolveBind(fileOffset: slotOffset) == "_malloc"
        }
        #expect(measurement.everySlotResolved)
        #expect(measurement.slowdown < Self.maximumSlowdown)
    }

    @Test("A memoized slot resolves to what it resolved to the first time")
    func memoizedSlotsResolveAsBefore() throws {
        let machO = try FixupSlotsLibrary.machOFile()
        let rebaseSlotOffset = try FixupSlotsLibrary.slotFileOffset(of: "_rebaseSlots", in: machO)
        let bindSlotOffset = try FixupSlotsLibrary.slotFileOffset(of: "_bindSlots", in: machO)

        let firstRebase = try #require(machO.resolveRebase(fileOffset: rebaseSlotOffset))
        let firstBind = try #require(machO.resolveBind(fileOffset: bindSlotOffset))

        #expect(machO.resolveRebase(fileOffset: rebaseSlotOffset) == firstRebase)
        #expect(machO.resolveBind(fileOffset: bindSlotOffset) == firstBind)
        #expect(firstRebase == (try FixupSlotsLibrary.symbolValue(of: "_rebaseTarget", in: machO)))
    }

    private struct BatchMeasurement {
        /// The shortest last batch over the shortest first batch.
        let slowdown: Double
        let everySlotResolved: Bool
    }

    /// How many times longer the last batch of slots takes to resolve than the
    /// first, taking the shortest of `runCount` runs for each. `resolve`
    /// answers whether the slot resolved to what the fixture put there; it is
    /// checked after timing, so no expectation runs inside a timed batch.
    private func lastBatchSlowdown(
        slotSymbolName: String,
        slotCount: Int,
        resolve: (MachOFile, Int) -> Bool
    ) throws -> BatchMeasurement {
        var shortestFirstBatchNanoseconds = UInt64.max
        var shortestLastBatchNanoseconds = UInt64.max
        var everySlotResolved = true
        for _ in 0 ..< Self.runCount {
            let machO = try FixupSlotsLibrary.machOFile()
            let firstSlotOffset = try FixupSlotsLibrary.slotFileOffset(of: slotSymbolName, in: machO)
            let slotOffsets = (0 ..< slotCount).map { firstSlotOffset + $0 * MemoryLayout<UInt64>.size }
            // The first lookup builds the file's fixup pointer map; keep it
            // out of the timed batch.
            everySlotResolved = resolve(machO, slotOffsets[0]) && everySlotResolved

            let firstBatch = slotOffsets[1 ... Self.batchSize]
            let middle = slotOffsets[(Self.batchSize + 1) ..< (slotCount - Self.batchSize)]
            let lastBatch = slotOffsets[(slotCount - Self.batchSize)...]
            let firstBatchNanoseconds = Self.nanoseconds {
                for slotOffset in firstBatch {
                    everySlotResolved = resolve(machO, slotOffset) && everySlotResolved
                }
            }
            for slotOffset in middle {
                everySlotResolved = resolve(machO, slotOffset) && everySlotResolved
            }
            let lastBatchNanoseconds = Self.nanoseconds {
                for slotOffset in lastBatch {
                    everySlotResolved = resolve(machO, slotOffset) && everySlotResolved
                }
            }
            shortestFirstBatchNanoseconds = min(shortestFirstBatchNanoseconds, firstBatchNanoseconds)
            shortestLastBatchNanoseconds = min(shortestLastBatchNanoseconds, lastBatchNanoseconds)
        }
        return BatchMeasurement(
            slowdown: Double(shortestLastBatchNanoseconds) / Double(max(shortestFirstBatchNanoseconds, 1)),
            everySlotResolved: everySlotResolved
        )
    }

    private static func nanoseconds(of body: () -> Void) -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return DispatchTime.now().uptimeNanoseconds - start
    }
}

/// A dylib with `rebaseSlotCount` pointers to its own data, each a rebase,
/// and `bindSlotCount` pointers to `malloc`, each a bind.
enum FixupSlotsLibrary {
    static let rebaseSlotCount = 100_000
    static let bindSlotCount = 50_000

    static let source = """
    #include <stdlib.h>

    #define REPEAT_10(value) value, value, value, value, value, value, value, value, value, value
    #define REPEAT_100(value) REPEAT_10(value), REPEAT_10(value), REPEAT_10(value), REPEAT_10(value), REPEAT_10(value), \
        REPEAT_10(value), REPEAT_10(value), REPEAT_10(value), REPEAT_10(value), REPEAT_10(value)
    #define REPEAT_1000(value) REPEAT_100(value), REPEAT_100(value), REPEAT_100(value), REPEAT_100(value), REPEAT_100(value), \
        REPEAT_100(value), REPEAT_100(value), REPEAT_100(value), REPEAT_100(value), REPEAT_100(value)
    #define REPEAT_10000(value) REPEAT_1000(value), REPEAT_1000(value), REPEAT_1000(value), REPEAT_1000(value), REPEAT_1000(value), \
        REPEAT_1000(value), REPEAT_1000(value), REPEAT_1000(value), REPEAT_1000(value), REPEAT_1000(value)
    #define REPEAT_50000(value) REPEAT_10000(value), REPEAT_10000(value), REPEAT_10000(value), REPEAT_10000(value), REPEAT_10000(value)

    __attribute__((visibility("default"))) int rebaseTarget = 1;
    __attribute__((visibility("default"))) int *rebaseSlots[100000] = { REPEAT_50000(&rebaseTarget), REPEAT_50000(&rebaseTarget) };
    __attribute__((visibility("default"))) void *bindSlots[50000] = { REPEAT_50000((void *)malloc) };
    """

    private struct CompilationError: Swift.Error, CustomStringConvertible {
        let diagnostics: String
        var description: String { "fixup slots library compilation failed:\n\(diagnostics)" }
    }

    private static let compilation: Result<URL, Swift.Error> = Result {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixupSlotsLibrary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let sourceURL = workingDirectory.appendingPathComponent("Library.c")
        let libraryURL = workingDirectory.appendingPathComponent("libFixupSlots.dylib")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang", "-dynamiclib", sourceURL.path, "-o", libraryURL.path]
        let standardErrorPipe = Pipe()
        process.standardError = standardErrorPipe
        try process.run()
        // Drain BEFORE waitUntilExit, or a long diagnostic deadlocks both sides.
        let diagnosticsData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CompilationError(diagnostics: String(decoding: diagnosticsData, as: UTF8.self))
        }
        return libraryURL
    }

    /// A fresh `MachOFile` per call, so every run starts with empty memos.
    static func machOFile() throws -> MachOFile {
        guard case .machO(let machOFile) = try MachOKit.loadFromFile(url: try compilation.get()) else {
            throw CompilationError(diagnostics: "expected a thin dylib")
        }
        return machOFile
    }

    /// The symbol's `n_value`: its offset from the load address, in a dylib
    /// whose `__TEXT` starts at zero.
    static func symbolValue(of symbolName: String, in machO: MachOFile) throws -> UInt64 {
        let symbol = try #require(machO.symbols.first { $0.name == symbolName }, "no \(symbolName) in the symbol table")
        return UInt64(symbol.offset)
    }

    /// Where the array `symbolName` starts in the file.
    static func slotFileOffset(of symbolName: String, in machO: MachOFile) throws -> Int {
        let address = try symbolValue(of: symbolName, in: machO)
        return try #require(machO.fileOffset(of: address).map { Int($0) }, "\(symbolName) is not in the file")
    }
}
