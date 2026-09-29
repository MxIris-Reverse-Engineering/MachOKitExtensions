import Foundation
import MachOKit

// extension UnsafeRawPointer {
//    public var uint: UInt {
//        UInt(bitPattern: self)
//    }
//
//    public var int: Int {
//        Int(bitPattern: self)
//    }
// }

/// Thrown when a pointer is built from an address of zero.
struct NullPointerError: Error {}

// Deliberately internal. A public throwing `init(bitPattern:)` would shadow the
// standard library's failable one in every module that imports this package.
extension UnsafeRawPointer {
    init(nonZeroBitPattern bitPattern: UInt) throws {
        guard let pointer = Self(bitPattern: bitPattern) else {
            throw NullPointerError()
        }
        self = pointer
    }

    init(nonZeroBitPattern bitPattern: Int) throws {
        guard let pointer = Self(bitPattern: bitPattern) else {
            throw NullPointerError()
        }
        self = pointer
    }
}

extension UnsafeRawPointer {
    /*@inlinable*/
    public mutating func offset<T>(of type: T.Type, numbersOfElements: Int = 1) {
        self += numericCast(MemoryLayout<T>.size * numbersOfElements)
    }

    /*@inlinable*/
    public mutating func offset<T: LayoutWrapper>(of type: T.Type, numbersOfElements: Int = 1) {
        self += numericCast(T.layoutSize * numbersOfElements)
    }

    /*@inlinable*/
    public func offseting<T>(of type: T.Type, numbersOfElements: Int = 1) -> Self {
        return self + numericCast(MemoryLayout<T>.size * numbersOfElements)
    }

    /*@inlinable*/
    public func offseting<T: LayoutWrapper>(of type: T.Type, numbersOfElements: Int = 1) -> Self {
        return self + numericCast(T.layoutSize * numbersOfElements)
    }
}
