/// The name of an image loaded in this process, the way `MachOImage(name:)`
/// looks it up: the last path component without its extension, such as
/// `SwiftUI` or `libc++abi`.
///
/// A struct with static members rather than an enum, so that a package adds
/// the images only its own tests read with an extension. The members are
/// spelled exactly like the image they name.
public struct MachOImageName: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public init(stringLiteral name: String) {
        self.init(name)
    }

    public var description: String {
        name
    }
}

extension MachOImageName {
    public static let AppKit: MachOImageName = "AppKit"
    public static let UIFoundation: MachOImageName = "UIFoundation"
    public static let CollectionViewCore: MachOImageName = "CollectionViewCore"
    public static let CoreAutoLayout: MachOImageName = "CoreAutoLayout"
    public static let SwiftUI: MachOImageName = "SwiftUI"
    public static let SwiftUICore: MachOImageName = "SwiftUICore"
    public static let AttributeGraph: MachOImageName = "AttributeGraph"
    public static let Foundation: MachOImageName = "Foundation"
    public static let Combine: MachOImageName = "Combine"
    public static let DeveloperToolsSupport: MachOImageName = "DeveloperToolsSupport"
    public static let CodableSwiftUI: MachOImageName = "CodableSwiftUI"
    public static let AAAFoundationSwift: MachOImageName = "AAAFoundationSwift"
    public static let UIKitCore: MachOImageName = "UIKitCore"
    public static let HomeKit: MachOImageName = "HomeKit"
    public static let Network: MachOImageName = "Network"
    public static let ScreenContinuityServices: MachOImageName = "ScreenContinuityServices"
    public static let Sharing: MachOImageName = "Sharing"
    public static let FeatureFlags: MachOImageName = "FeatureFlags"
    public static let ScreenSharingKit: MachOImageName = "ScreenSharingKit"
    public static let DesignLibrary: MachOImageName = "DesignLibrary"
    public static let SFSymbols: MachOImageName = "SFSymbols"
    public static let SnippetUI: MachOImageName = "SnippetUI"
    public static let SiriOntology: MachOImageName = "SiriOntology"
}
