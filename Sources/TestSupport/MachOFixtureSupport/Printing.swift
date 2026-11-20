import Foundation

/// Whether ``Swift/CustomStringConvertible/print()`` stays quiet: set
/// `MACHO_TESTING_SILENT=1` in the environment of the test process, as CI does
/// to keep its logs short.
///
/// Read at run time rather than as a compilation condition, so that a package
/// using this module silences it without rebuilding it with its own flags.
public enum TestOutput {
    public static let isSilent: Bool = ProcessInfo.processInfo.environment["MACHO_TESTING_SILENT"] == "1"
}

extension CustomStringConvertible {
    /// Prints the value, unless ``TestOutput/isSilent``.
    public func print() {
        guard !TestOutput.isSilent else { return }
        Swift.print(self)
    }
}

extension Error {
    /// Prints the error, unless ``TestOutput/isSilent``.
    public func print() {
        guard !TestOutput.isSilent else { return }
        Swift.print(self)
    }
}
