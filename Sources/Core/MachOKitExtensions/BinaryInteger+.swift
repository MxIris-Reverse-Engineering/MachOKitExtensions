import Foundation
import MachOKit

extension BinaryInteger {
    public func cast<T: BinaryInteger>() -> T {
        numericCast(self)
    }
}

extension BinaryInteger {
    public mutating func offset<T>(of type: T.Type, numbersOfElements: Int = 1) {
        self += numericCast(MemoryLayout<T>.size * numbersOfElements)
    }

    public mutating func offset<T: LayoutWrapper>(of type: T.Type, numbersOfElements: Int = 1) {
        self += numericCast(T.layoutSize * numbersOfElements)
    }

    public func offseting<T>(of type: T.Type, numbersOfElements: Int = 1) -> Self {
        return self + numericCast(MemoryLayout<T>.size * numbersOfElements)
    }

    public func offseting<T: LayoutWrapper>(of type: T.Type, numbersOfElements: Int = 1) -> Self {
        return self + numericCast(T.layoutSize * numbersOfElements)
    }
}
