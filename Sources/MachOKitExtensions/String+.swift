import Foundation

extension String {
    public typealias CCharTuple16 = (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)

    public init(tuple: CCharTuple16) {
        self = withUnsafePointer(to: tuple) {
            let size = MemoryLayout<CCharTuple16>.size
            let data = Data(bytes: $0, count: size) + [0]
            return String(cString: data) ?? ""
        }
    }
}

extension String {
    public typealias CCharTuple32 = (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)

    public init(tuple: CCharTuple32) {
        self = withUnsafePointer(to: tuple) {
            let size = MemoryLayout<CCharTuple32>.size
            let data = Data(bytes: $0, count: size) + [0]
            return String(cString: data) ?? ""
        }
    }
}


extension String {
    @inline(__always)
    public func isEqual(to tuple: CCharTuple16) -> Bool {
        withUnsafePointer(to: tuple) { tuple in
            withCString { str in
                strcmp(str, tuple) == 0
            }
        }
    }

    @inline(__always)
    public func isEqual(to tuple: CCharTuple32) -> Bool {
        withUnsafePointer(to: tuple) { tuple in
            withCString { str in
                strcmp(str, tuple) == 0
            }
        }
    }
}

public func == (string: String, tuple: String.CCharTuple16) -> Bool {
    string.isEqual(to: tuple)
}

public func == (tuple: String.CCharTuple16, string: String) -> Bool {
    string.isEqual(to: tuple)
}

public func == (string: String, tuple: String.CCharTuple32) -> Bool {
    string.isEqual(to: tuple)
}

public func == (tuple: String.CCharTuple32, string: String) -> Bool {
    string.isEqual(to: tuple)
}
