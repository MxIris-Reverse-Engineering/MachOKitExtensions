import Foundation

/// A Mach-O file, or a bundle holding one, that tests read from disk.
///
/// A struct with static members rather than an enum, so that a package adds
/// its own files with an extension. A file inside the package that adds it —
/// a fixture built into the package's tree — is named by a path relative to
/// an anchor the package passes in, usually its own `#filePath`: this module
/// cannot know where another package's sources sit.
public struct MachOFileName: Hashable, Sendable, CustomStringConvertible {
    public let url: URL

    /// A file at `path`. An absolute path stands on its own; a relative one
    /// resolves against `anchor` the way `URL(fileURLWithPath:relativeTo:)`
    /// resolves it — against the directory of a file URL such as
    /// `URL(fileURLWithPath: #filePath)`.
    public init(path: String, relativeTo anchor: URL? = nil) {
        if path.hasPrefix("/") || anchor == nil {
            self.url = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            self.url = URL(fileURLWithPath: path, relativeTo: anchor).standardizedFileURL
        }
    }

    public var path: String {
        url.path
    }

    public var description: String {
        path
    }
}

extension MachOFileName {
    public static let iOS_18_5_Simulator_SwiftUI = MachOFileName(path: "/Library/Developer/CoreSimulator/Volumes/iOS_22F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 18.5.simruntime/Contents/Resources/RuntimeRoot/System/Library/Frameworks/SwiftUI.framework/SwiftUI")
    public static let iOS_18_5_Simulator_SwiftUICore = MachOFileName(path: "/Library/Developer/CoreSimulator/Volumes/iOS_22F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 18.5.simruntime/Contents/Resources/RuntimeRoot/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore")
    public static let iOS_26_5_Simulator_SwiftUI = MachOFileName(path: "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/System/Library/Frameworks/SwiftUI.framework/SwiftUI")
    public static let iOS_26_5_Simulator_SwiftUICore = MachOFileName(path: "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore")

    public static let SourceEdit = MachOFileName(path: "/Applications/SourceEdit.app")
    public static let SourceEditorFromSourceEdit = MachOFileName(path: "/Applications/SourceEdit.app/Contents/Frameworks/SourceEditor.framework")
    public static let SourceEditorFromXcode = MachOFileName(path: "/Applications/Xcode.app/Contents/SharedFrameworks/SourceEditor.framework")

    public static let Finder = MachOFileName(path: "/System/Library/CoreServices/Finder.app")
    public static let Dock = MachOFileName(path: "/System/Library/CoreServices/Dock.app")
    public static let iPhoneMirroring = MachOFileName(path: "/System/Applications/iPhone Mirroring.app")
    public static let ScreenContinuityUI = MachOFileName(path: "/System/Applications/iPhone Mirroring.app/Contents/Frameworks/ScreenContinuityUI.framework")
    public static let ControlCenter = MachOFileName(path: "/System/Library/CoreServices/ControlCenter.app")
    public static let Freeform = MachOFileName(path: "/System/Applications/Freeform.app")
}
