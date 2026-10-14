import MachOKit
import MachOKitExtensions

/// Whether a ``ForwardingReader`` tells the package what it wraps.
protocol ForwardingReaderDeclaration: Sendable {}

/// The reader declares the reader it forwards to.
enum DeclaredWrapper: ForwardingReaderDeclaration {}

/// The reader forwards every read and says nothing about it.
enum UndeclaredWrapper: ForwardingReaderDeclaration {}

/// A reader that forwards every requirement to `base` and adds nothing — the
/// shape of a host's wrapper type, which holds a `MachOFile` or `MachOImage`
/// for its UI and forwards the reading protocols to it.
struct ForwardingReader<Base: MachORepresentableWithCache, Declaration: ForwardingReaderDeclaration>: MachORepresentableWithCache {
    let base: Base

    init(_ base: Base) {
        self.base = base
    }

    typealias LoadCommands = Base.LoadCommands
    typealias Symbol = Base.Symbol
    typealias Symbols64 = Base.Symbols64
    typealias Symbols = Base.Symbols
    typealias IndirectSymbols = Base.IndirectSymbols
    typealias CFStrings32 = Base.CFStrings32
    typealias CFStrings64 = Base.CFStrings64
    typealias RebaseOperations = Base.RebaseOperations
    typealias BindOperations = Base.BindOperations
    typealias ExportTrie = Base.ExportTrie
    typealias Strings = Base.Strings
    typealias UTF16Strings = Base.UTF16Strings
    typealias FunctionStarts = Base.FunctionStarts
    typealias DataInCode = Base.DataInCode
    typealias DyldChainedFixups = Base.DyldChainedFixups
    typealias ExternalRelocations = Base.ExternalRelocations
    typealias CodeSign = Base.CodeSign
    typealias Cache = Base.Cache
    typealias Identifier = Base.Identifier

    var is64Bit: Bool { base.is64Bit }
    var headerSize: Int { base.headerSize }
    var header: MachHeader { base.header }
    var loadCommands: LoadCommands { base.loadCommands }
    var endian: Endian { base.endian }
    var rpaths: [String] { base.rpaths }
    var dependencies: [DependedDylib] { base.dependencies }
    var segments: [any SegmentCommandProtocol] { base.segments }
    var segments64: AnySequence<SegmentCommand64> { base.segments64 }
    var segments32: AnySequence<SegmentCommand> { base.segments32 }
    var preferredLoadAddress: UInt64? { base.preferredLoadAddress }
    var sections: [any SectionProtocol] { base.sections }
    var sections64: [Section64] { base.sections64 }
    var sections32: [Section] { base.sections32 }
    var symbols: AnyRandomAccessCollection<Symbol> { base.symbols }
    var symbols64: Symbols64? { base.symbols64 }
    var symbols32: Symbols? { base.symbols32 }
    var indirectSymbols: IndirectSymbols? { base.indirectSymbols }
    var symbolStrings: Strings? { base.symbolStrings }
    var cStrings: Strings? { base.cStrings }
    var allCStringTables: [Strings] { base.allCStringTables }
    var allCStrings: [String] { base.allCStrings }
    var uStrings: UTF16Strings? { base.uStrings }
    var cfStrings: [any CFStringProtocol]? { base.cfStrings }
    var cfStrings64: CFStrings64? { base.cfStrings64 }
    var cfStrings32: CFStrings32? { base.cfStrings32 }
    var embeddedInfoPlist: [String: Any]? { base.embeddedInfoPlist }
    var rebaseOperations: RebaseOperations? { base.rebaseOperations }
    var bindOperations: BindOperations? { base.bindOperations }
    var weakBindOperations: BindOperations? { base.weakBindOperations }
    var lazyBindOperations: BindOperations? { base.lazyBindOperations }
    var exportTrie: ExportTrie? { base.exportTrie }
    var exportedSymbols: [ExportedSymbol] { base.exportedSymbols }
    var bindingSymbols: [BindingSymbol] { base.bindingSymbols }
    var weakBindingSymbols: [BindingSymbol] { base.weakBindingSymbols }
    var lazyBindingSymbols: [BindingSymbol] { base.lazyBindingSymbols }
    var rebases: [Rebase] { base.rebases }
    var functionStarts: FunctionStarts? { base.functionStarts }
    var dataInCode: DataInCode? { base.dataInCode }
    var dyldChainedFixups: DyldChainedFixups? { base.dyldChainedFixups }
    var externalRelocations: ExternalRelocations? { base.externalRelocations }
    var classicBindingSymbols: [ClassicBindingSymbol]? { base.classicBindingSymbols }
    var classicLazyBindingSymbols: [ClassicBindingSymbol]? { base.classicLazyBindingSymbols }
    var codeSign: CodeSign? { base.codeSign }
    var expectedMachOFileSize: Int? { base.expectedMachOFileSize }

    func closestSymbol(at offset: Int, inSection sectionNumber: Int, isGlobalOnly: Bool) -> Symbol? {
        base.closestSymbol(at: offset, inSection: sectionNumber, isGlobalOnly: isGlobalOnly)
    }

    func closestSymbols(at offset: Int, inSection sectionNumber: Int, isGlobalOnly: Bool) -> [Symbol] {
        base.closestSymbols(at: offset, inSection: sectionNumber, isGlobalOnly: isGlobalOnly)
    }

    func symbol(for offset: Int, inSection sectionNumber: Int, isGlobalOnly: Bool) -> Symbol? {
        base.symbol(for: offset, inSection: sectionNumber, isGlobalOnly: isGlobalOnly)
    }

    func symbols(for offset: Int, inSection sectionNumber: Int, isGlobalOnly: Bool) -> [Symbol] {
        base.symbols(for: offset, inSection: sectionNumber, isGlobalOnly: isGlobalOnly)
    }

    func symbols(named name: String, mangled: Bool) -> [Symbol] {
        base.symbols(named: name, mangled: mangled)
    }

    func symbol(named name: String, mangled: Bool, inSection sectionNumber: Int, isGlobalOnly: Bool) -> Symbol? {
        base.symbol(named: name, mangled: mangled, inSection: sectionNumber, isGlobalOnly: isGlobalOnly)
    }

    func contains(unslidAddress address: UInt64) -> Bool {
        base.contains(unslidAddress: address)
    }

    func stripPointerTags(of rawVMAddr: UInt64) -> UInt64 {
        base.stripPointerTags(of: rawVMAddr)
    }

    var imagePath: String { base.imagePath }
    var identifier: Identifier { base.identifier }
    var cache: Cache? { base.cache }
    var startOffset: Int { base.startOffset }

    func resolveOffset(at address: UInt64) -> Int {
        base.resolveOffset(at: address)
    }
}

extension ForwardingReader: MachOReaderWrapper where Declaration == DeclaredWrapper {}
