import Foundation
import Testing
import MachOKit
import MachOKitExtensions

/// Memos a `MachOFile` fills on first read, read by many threads at once.
///
/// `identifier` and the LC_DYLD_INFO bind index used to be stored in
/// non-atomic associated objects, checked and written without a lock. Threads
/// that read a fresh file together each found nothing, each computed a value
/// and each stored it; objc's non-atomic getter hands a value back without
/// retaining it, so a reader could still be holding the value another thread's
/// store had just released. The process then stopped in `objc_retain` or, on
/// arm64e, on the isa check of `swift_getObjectType`.
///
/// Each test runs in a child process, because the failure is a crash: many
/// rounds, each on a fresh `MachOFile`, with every racing thread released onto
/// the file's first reads together.
@Suite("Concurrent first reads of a file's memos")
struct ConcurrentFirstReadTests {
    /// Rounds per test; each takes a fresh `MachOFile`.
    private static let roundCount = 2_000
    /// Reads each thread makes per round, so that later reads overlap the
    /// stores of the threads that finished computing first.
    private static let readsPerThread = 50
    private static let threadCount = max(4, min(16, ProcessInfo.processInfo.activeProcessorCount))

    @Test("Threads reading a fresh file's identifier together all get one identifier")
    func concurrentIdentifierReadsAgree() async {
        await #expect(processExitsWith: .success) {
            exit(ConcurrentFirstReadTests.concurrentIdentifierReadsAgree() ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    @Test("Threads looking up a fresh legacy file's binds together all find the bind")
    func concurrentDyldInfoBindReadsAgree() async {
        await #expect(processExitsWith: .success) {
            exit(ConcurrentFirstReadTests.concurrentDyldInfoBindReadsAgree() ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    // MARK: - Exit test bodies

    /// Whether every thread of every round read one identifier, the one a
    /// lone reader of the same file reads.
    static func concurrentIdentifierReadsAgree() -> Bool {
        guard let loneReaderIdentifier = try? SelfBindLibrary.machOFile(format: .chainedFixups).identifier else {
            return false
        }
        // `MachOTargetIdentifier` is not `Sendable` because one case holds a
        // pointer; this one holds a path and a UUID and is only read.
        nonisolated(unsafe) let expectedIdentifier = loneReaderIdentifier
        let race = ThreadRace<MachOFile, Bool>(threadCount: threadCount) { machO in
            var everyReadAgrees = true
            for _ in 0 ..< readsPerThread {
                everyReadAgrees = machO.identifier == expectedIdentifier && everyReadAgrees
            }
            return everyReadAgrees
        }
        defer { race.stop() }
        for _ in 0 ..< roundCount {
            guard let machO = try? SelfBindLibrary.machOFile(format: .chainedFixups) else {
                return false
            }
            guard race.run(on: machO).allSatisfy({ $0 }) else {
                return false
            }
        }
        return true
    }

    /// Whether every thread of every round found the fixture's bind slot
    /// through the LC_DYLD_INFO bind index, as a lone reader does.
    static func concurrentDyldInfoBindReadsAgree() -> Bool {
        guard let referenceMachO = try? SelfBindLibrary.machOFile(format: .dyldInfo),
              let slotOffset = try? SelfBindLibrary.slotFileOffset(of: "_externalPointer", in: referenceMachO),
              referenceMachO.isBind(fileOffset: slotOffset) else {
            return false
        }
        // `isBind(fileOffset:)` keeps no memo of its own and does little else:
        // every call reads the bind index.
        let race = ThreadRace<MachOFile, Bool>(threadCount: threadCount) { machO in
            var everyReadAgrees = true
            for _ in 0 ..< readsPerThread {
                everyReadAgrees = machO.isBind(fileOffset: slotOffset) && everyReadAgrees
            }
            return everyReadAgrees
        }
        defer { race.stop() }
        for _ in 0 ..< roundCount {
            guard let machO = try? SelfBindLibrary.machOFile(format: .dyldInfo) else {
                return false
            }
            guard race.run(on: machO).allSatisfy({ $0 }) else {
                return false
            }
        }
        return true
    }
}

/// A fixed set of threads that run one body on one subject together, round
/// after round.
///
/// The threads are `Thread`s, not tasks of the cooperative pool, which has
/// only as many threads as the machine has cores and runs a task when one
/// frees up instead of all of them at once. Each round wakes every thread,
/// then waits until each has returned what the body observed.
final class ThreadRace<Subject: Sendable, Observation: Sendable>: @unchecked Sendable {
    private let threadCount: Int
    private let body: @Sendable (Subject) -> Observation
    private let startSemaphores: [DispatchSemaphore]
    private let finishSemaphore = DispatchSemaphore(value: 0)
    // Written before the start semaphores are signalled and read after they
    // are waited on (or the other way round for the observations), which
    // orders every access.
    private var subject: Subject?
    private var isStopping = false
    /// One per thread, so no two threads write to the same storage.
    private let observationSlots: [ObservationSlot]

    private final class ObservationSlot {
        var observation: Observation?
    }

    init(threadCount: Int, body: @escaping @Sendable (Subject) -> Observation) {
        self.threadCount = threadCount
        self.body = body
        self.startSemaphores = (0 ..< threadCount).map { _ in DispatchSemaphore(value: 0) }
        self.observationSlots = (0 ..< threadCount).map { _ in ObservationSlot() }
        for threadIndex in 0 ..< threadCount {
            let thread = Thread { [self] in
                runThread(at: threadIndex)
            }
            thread.start()
        }
    }

    /// Runs the body on every thread on `subject` and returns what each one
    /// observed.
    func run(on subject: Subject) -> [Observation] {
        self.subject = subject
        for startSemaphore in startSemaphores {
            startSemaphore.signal()
        }
        for _ in 0 ..< threadCount {
            finishSemaphore.wait()
        }
        self.subject = nil
        return observationSlots.compactMap { observationSlot in
            defer { observationSlot.observation = nil }
            return observationSlot.observation
        }
    }

    /// Ends every thread once it has finished its current round.
    func stop() {
        isStopping = true
        for startSemaphore in startSemaphores {
            startSemaphore.signal()
        }
    }

    private func runThread(at threadIndex: Int) {
        while true {
            startSemaphores[threadIndex].wait()
            if isStopping {
                return
            }
            guard let subject else { return }
            observationSlots[threadIndex].observation = body(subject)
            finishSemaphore.signal()
        }
    }
}
