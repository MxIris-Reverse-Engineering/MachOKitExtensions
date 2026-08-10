import MachOKit

public protocol LayoutProtocol: Sendable, Equatable {}

public protocol LocatableLayoutWrapper: LayoutWrapper, Sendable, Equatable where Layout: LayoutProtocol {
    var offset: Int { get }

    init(layout: Layout, offset: Int)
}

extension LocatableLayoutWrapper {
    public func offset<T>(of keyPath: KeyPath<Layout, T>) -> Int {
        return offset + MemoryLayout<Layout>.offset(of: keyPath)!
    }

    public func pointer<T>(of keyPath: KeyPath<Layout, T>) throws -> UnsafeRawPointer {
        return try asPointer.advanced(by: MemoryLayout<Layout>.offset(of: keyPath)!)
    }

    public func pointer(in machO: MachOImage) -> UnsafeRawPointer {
        return machO.ptr + UnsafeRawPointer.Stride(offset)
    }

    public var asPointer: UnsafeRawPointer {
        get throws {
            return try .init(bitPattern: offset)
        }
    }

    public func asPointerWrapper(in machO: MachOImage) -> Self {
        let pointer = pointer(in: machO)
        return .init(layout: pointer.assumingMemoryBound(to: Layout.self).pointee, offset: Int(bitPattern: pointer))
    }
}
