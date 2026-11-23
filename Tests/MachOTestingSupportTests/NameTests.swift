import Foundation
import Testing
import MachOFixtureSupport

extension MachOImageName {
    fileprivate static let packageOwnImage: MachOImageName = "PackageOwnImage"
}

extension MachOFileName {
    /// Named the way a package names a fixture built into its own tree.
    fileprivate static let packageOwnFixture = MachOFileName(path: "../Fixtures/Built/libFixture.dylib", relativeTo: URL(fileURLWithPath: #filePath))
}

/// The name types are structs so that a package names its own images and
/// files next to the shared ones.
@Suite
struct NameTests {
    @Test("A package adds names of its own, and a relative file resolves against the anchor it passes")
    func imageNamesAndFileNamesTakeExtensions() {
        #expect(MachOImageName.packageOwnImage.name == "PackageOwnImage")
        #expect(MachOImageName.SwiftUI.name == "SwiftUI")

        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let expectedFixture = testsDirectory.deletingLastPathComponent().appendingPathComponent("Fixtures/Built/libFixture.dylib").standardizedFileURL
        #expect(MachOFileName.packageOwnFixture.url == expectedFixture)

        // An absolute path ignores the anchor.
        let absolute = MachOFileName(path: "/usr/lib/dyld", relativeTo: URL(fileURLWithPath: #filePath))
        #expect(absolute.path == "/usr/lib/dyld")
        #expect(MachOFileName.Finder.path == "/System/Library/CoreServices/Finder.app")
    }

    @Test("An Xcode file is named from its list or by hand, and both name the same path")
    func xcodeFileNamesFromTheListAndByHandAgree() {
        let fromList = XcodeMachOFileName.sharedFrameworks(.SourceKitSupport)
        let byHand = XcodeMachOFileName(location: .sharedFrameworks, name: "SourceKitSupport")
        #expect(fromList == byHand)
        #expect(fromList.relativePath == "SharedFrameworks/SourceKitSupport")
        #expect(XcodeMachOFileName.allCases.contains(fromList))
    }
}
