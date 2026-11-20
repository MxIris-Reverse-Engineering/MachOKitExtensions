import MachOKit
import MachOKitExtensions

/// Whether a ``ForwardingReader`` tells the package what it wraps.
public protocol ForwardingReaderDeclaration: Sendable {}

/// The reader declares the reader it forwards to: it conforms to
/// `MachOReaderWrapper`.
public enum DeclaredWrapper: ForwardingReaderDeclaration {}

/// The reader forwards every read and says nothing about it.
public enum UndeclaredWrapper: ForwardingReaderDeclaration {}

/// A reader that forwards every requirement to `base` and adds nothing — the
/// shape of a host's wrapper type, which holds a `MachOFile` or `MachOImage`
/// for its UI and forwards the reading protocols to it. Tests read through it
/// to check that a wrapper reads like what it wraps.
public struct ForwardingReader<Base: MachORepresentableWithCache, Declaration: ForwardingReaderDeclaration>: MachORepresentableWithCache {
    public let base: Base

    public init(_ base: Base) {
        self.base = base
    }

    public typealias LoadCommands = Base.LoadCommands
    public typealias Symbol = Base.Symbol
    public typealias Symbols64 = Base.Symbols64
    public typealias Symbols = Base.Symbols
    public typealias IndirectSymbols = Base.IndirectSymbols
    public typealias CFStrings32 = Base.CFStrings32
    public typealias CFStrings64 = Base.CFStrings64
    public typealias RebaseOperations = Base.RebaseOperations
    public typealias BindOperations = Base.BindOperations
    public typealias ExportTrie = Base.ExportTrie
    public typealias Strings = Base.Strings
    public typealias UTF16Strings = Base.UTF16Strings
    public typealias FunctionStarts = Base.FunctionStarts
    public typealias DataInCode = Base.DataInCode
    public typealias DyldChainedFixups = Base.DyldChainedFixups
    public typealias ExternalRelocations = Base.ExternalRelocations
    public typealias CodeSign = Base.CodeSign
    public typealias Cache = Base.Cache
    public typealias Identifier = Base.Identifier

    public var is64Bit: Bool { base.is64Bit }
    public var headerSize: Int { base.headerSize }
    public var header: MachHeader { base.header }
    public var loadCommands: LoadCommands { base.loadCommands }
    public var endian: Endian { base.endian }
    public var rpaths: [String] { base.rpaths }
    public var dependencies: [DependedDylib] { base.dependencies }
    public var segments: [any SegmentCommandProtocol] { base.segments }
    public var segments64: AnySequence<SegmentCommand64> { base.segments64 }
    public var segments32: AnySequence<SegmentCommand> { base.segments32 }
    public var preferredLoadAddress: UInt64? { base.preferredLoadAddress }
    public var sections: [any SectionProtocol] { base.sections }
    public var sections64: [Section64] { base.sections64 }
    public var sections32: [Section] { base.sections32 }
    public var symbols: AnyRandomAccessCollection<Symbol> { base.symbols }
    public var symbols64: Symbols64? { base.symbols64 }
    public var symbols32: Symbols? { base.symbols32 }
    public var indirectSymbols: IndirectSymbols? { base.indirectSymbols }
    public var symbolStrings: Strings? { base.symbolStrings }
    public var cStrings: Strings? { base.cStrings }
    public var allCStringTables: [Strings] { base.allCStringTables }
    public var allCStrings: [String] { base.allCStrings }
    public var uStrings: UTF16Strings? { base.uStrings }
    public var cfStrings: [any CFStringProtocol]? { base.cfStrings }
    public var cfStrings64: CFStrings64? { base.cfStrings64 }
    public var cfStrings32: CFStrings32? { base.cfStrings32 }
    public var embeddedInfoPlist: [String: Any]? { base.embeddedInfoPlist }
    public var rebaseOperations: RebaseOperations? { base.rebaseOperations }
    public var bindOperations: BindOperations? { base.bindOperations }
    public var weakBindOperations: BindOperations? { base.weakBindOperations }
    public var lazyBindOperations: BindOperations? { base.lazyBindOperations }
    public var exportTrie: ExportTrie? { base.exportTrie }
    public var exportedSymbols: [ExportedSymbol] { base.exportedSymbols }
    public var bindingSymbols: [BindingSymbol] { base.bindingSymbols }
    public var weakBindingSymbols: [BindingSymbol] { base.weakBindingSymbols }
    public var lazyBindingSymbols: [BindingSymbol] { base.lazyBindingSymbols }
    public var rebases: [Rebase] { base.rebases }
    public var functionStarts: FunctionStarts? { base.functionStarts }
    public var dataInCode: DataInCode? { base.dataInCode }
    public var dyldChainedFixups: DyldChainedFixups? { base.dyldChainedFixups }
    public var externalRelocations: ExternalRelocations? { base.externalRelocations }
    public var classicBindingSymbols: [ClassicBindingSymbol]? { base.classicBindingSymbols }
    public var classicLazyBindingSymbols: [ClassicBindingSymbol]? { base.classicLazyBindingSymbols }
    public var codeSign: CodeSign? { base.codeSign }
    public var expectedMachOFileSize: Int? { base.expectedMachOFileSize }

    public func closestSymbol(at offset: Int, inSection sectionNumber: Int, isGlobalOnly: Bool) -> Symbol? {
        base.closestSymbol(at: offset, inSection: sectionNumber, isGlobalOnly: isGlobalOnly)
    }

    public func closestSymbols(at offset: Int, inSection sectionNumber: Int, isGlobalOnly: Bool) -> [Symbol] {
        base.closestSymbols(at: offset, inSection: sectionNumber, isGlobalOnly: isGlobalOnly)
    }

    public func symbol(for offset: Int, inSection sectionNumber: Int, isGlobalOnly: Bool) -> Symbol? {
        base.symbol(for: offset, inSection: sectionNumber, isGlobalOnly: isGlobalOnly)
    }

    public func symbols(for offset: Int, inSection sectionNumber: Int, isGlobalOnly: Bool) -> [Symbol] {
        base.symbols(for: offset, inSection: sectionNumber, isGlobalOnly: isGlobalOnly)
    }

    public func symbols(named name: String, mangled: Bool) -> [Symbol] {
        base.symbols(named: name, mangled: mangled)
    }

    public func symbol(named name: String, mangled: Bool, inSection sectionNumber: Int, isGlobalOnly: Bool) -> Symbol? {
        base.symbol(named: name, mangled: mangled, inSection: sectionNumber, isGlobalOnly: isGlobalOnly)
    }

    public func contains(unslidAddress address: UInt64) -> Bool {
        base.contains(unslidAddress: address)
    }

    public func stripPointerTags(of rawVMAddr: UInt64) -> UInt64 {
        base.stripPointerTags(of: rawVMAddr)
    }

    public var imagePath: String { base.imagePath }
    public var identifier: Identifier { base.identifier }
    public var cache: Cache? { base.cache }
    public var startOffset: Int { base.startOffset }

    public func resolveOffset(at address: UInt64) -> Int {
        base.resolveOffset(at: address)
    }
}

extension ForwardingReader: MachOReaderWrapper where Declaration == DeclaredWrapper {}
