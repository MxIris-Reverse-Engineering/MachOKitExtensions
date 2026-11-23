import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import MachOReading
import MachOFixtureSupport

/// A suite that reads one image both from its file and as this process loaded
/// it, and checks that every reader gives the same answer.
///
/// Subclasses say where the image comes from by overriding ``fixture``. The
/// suite then holds the file (``machOFile``, the slice of this process's
/// CPU), the loaded image (``machOImage``) and a reading context over each,
/// plus the in-process context. ``acrossAllReaders(file:image:inProcess:sourceLocation:)``
/// and its siblings run the same read through each and record an issue
/// naming the reader that diverged.
@MainActor
open class MachOFixtureTests: Sendable {
    public let machOFile: MachOFile
    public let machOImage: MachOImage

    public let fileContext: MachOContext<MachOFile>
    public let imageContext: MachOContext<MachOImage>
    public let inProcessContext: InProcessContext

    /// Where the suite's image comes from. Every subclass overrides it.
    open class var fixture: MachOFixture {
        fatalError("\(self) inherits MachOFixtureTests without overriding `fixture`")
    }

    public init() async throws {
        let (file, image) = try Self.fixture.readers()
        self.machOFile = file
        self.machOImage = image
        self.fileContext = MachOContext(file)
        self.imageContext = MachOContext(image)
        self.inProcessContext = InProcessContext()
    }
}

extension MachOFixtureTests {
    /// Runs the same read through the file and the image — and through this
    /// process's memory when `inProcess` is given — and expects every result to
    /// equal the file's, which it returns.
    public func acrossAllReaders<Value: Equatable>(
        file fileWork: () throws -> Value,
        image imageWork: () throws -> Value,
        inProcess inProcessWork: (() throws -> Value)? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Value {
        let fromFile = try fileWork()
        let fromImage = try imageWork()
        #expect(fromFile == fromImage, "MachOFile vs MachOImage diverged", sourceLocation: sourceLocation)
        if let inProcessWork {
            let fromInProcess = try inProcessWork()
            #expect(fromFile == fromInProcess, "MachOFile vs InProcess diverged", sourceLocation: sourceLocation)
        }
        return fromFile
    }

    /// Runs the same read through each reading context — the file's, the
    /// image's, and this process's when `inProcess` is given — and expects every
    /// result to equal the file context's, which it returns.
    public func acrossAllContexts<Value: Equatable>(
        file fileWork: () throws -> Value,
        image imageWork: () throws -> Value,
        inProcess inProcessWork: (() throws -> Value)? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Value {
        let fromFileContext = try fileWork()
        let fromImageContext = try imageWork()
        #expect(fromFileContext == fromImageContext, "fileContext vs imageContext diverged", sourceLocation: sourceLocation)
        if let inProcessWork {
            let fromInProcessContext = try inProcessWork()
            #expect(fromFileContext == fromInProcessContext, "fileContext vs inProcessContext diverged", sourceLocation: sourceLocation)
        }
        return fromFileContext
    }

    /// Runs `work` in this process's memory only, for what the runtime builds
    /// as it runs and no file or image holds — metatype, tuple and function
    /// type metadata, say.
    public func usingInProcessOnly<Value: Equatable>(
        _ work: (InProcessContext) throws -> Value,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Value {
        try work(inProcessContext)
    }

    /// The same work on the subject each reader gives: `work` runs on
    /// `fileSubject`, then on `imageSubject`, and the results must agree.
    ///
    ///     try acrossAllReaders(fileDescriptor, imageDescriptor) { $0.offset }
    public func acrossAllReaders<Subject, Value: Equatable>(
        _ fileSubject: Subject,
        _ imageSubject: Subject,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ work: (Subject) throws -> Value
    ) throws -> Value {
        try acrossAllReaders(
            file: { try work(fileSubject) },
            image: { try work(imageSubject) },
            sourceLocation: sourceLocation
        )
    }

    /// The same, reading through each subject's context: ``fileContext`` for
    /// `fileSubject`, ``imageContext`` for `imageSubject`. An API that takes
    /// `some ReadingContext` accepts the `any ReadingContext` the closure gets.
    ///
    ///     try acrossAllContexts(fileDescriptor, imageDescriptor) { descriptor, context in
    ///         try descriptor.name(in: context)
    ///     }
    public func acrossAllContexts<Subject, Value: Equatable>(
        _ fileSubject: Subject,
        _ imageSubject: Subject,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ work: (Subject, any ReadingContext) throws -> Value
    ) throws -> Value {
        try acrossAllContexts(
            file: { try work(fileSubject, fileContext) },
            image: { try work(imageSubject, imageContext) },
            sourceLocation: sourceLocation
        )
    }

    /// The same work on each reader itself: `work` reads ``machOFile``, then
    /// ``machOImage``, and the results must agree. An API that takes
    /// `some MachORepresentableWithCache` accepts the reader the closure gets.
    ///
    ///     let names = try acrossAllReaders { machO in store.classes(in: machO).map(\.qualifiedName) }
    public func acrossAllReaders<Value: Equatable>(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ work: (any MachORepresentableWithCache) throws -> Value
    ) throws -> Value {
        try acrossAllReaders(
            machOFile as any MachORepresentableWithCache,
            machOImage as any MachORepresentableWithCache,
            sourceLocation: sourceLocation,
            work
        )
    }
}
