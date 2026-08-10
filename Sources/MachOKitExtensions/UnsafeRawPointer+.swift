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

extension UnsafeRawPointer {
    public enum Error: Swift.Error {
        case initFailed
    }

    /*@inlinable*/
    public init(bitPattern: UInt) throws {
        if let ptr = Self(bitPattern: bitPattern) {
            self = ptr
        } else {
            throw Error.initFailed
        }
    }

    /*@inlinable*/
    public init(bitPattern: Int) throws {
        if let ptr = Self(bitPattern: bitPattern) {
            self = ptr
        } else {
            throw Error.initFailed
        }
    }
}

extension UnsafePointer {
    public enum Error: Swift.Error {
        case initFailed
    }

    /*@inlinable*/
    public init(bitPattern: UInt) throws {
        if let ptr = Self(bitPattern: bitPattern) {
            self = ptr
        } else {
            throw Error.initFailed
        }
    }

    /*@inlinable*/
    public init(bitPattern: Int) throws {
        if let ptr = Self(bitPattern: bitPattern) {
            self = ptr
        } else {
            throw Error.initFailed
        }
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
