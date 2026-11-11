// swift-tools-version: 6.2

@preconcurrency import PackageDescription
import Foundation

func envEnable(_ key: String, default defaultValue: Bool = false) -> Bool {
    let value = Context.environment[key]
    guard let value else {
        return defaultValue
    }
    if value == "1" {
        return true
    } else if value == "0" {
        return false
    } else {
        return defaultValue
    }
}

let usingLocalDependencies = envEnable("USING_LOCAL_DEPENDENCIES")

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool = usingLocalDependencies, traits: Set<PackageDescription.Package.Dependency.Trait> = [.defaults])
    }

    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        let currentFilePath = #filePath

        let isClonedDependency = currentFilePath.contains("/checkouts/") ||
            currentFilePath.contains("/SourcePackages/") ||
            currentFilePath.contains("/.build/")

        if isClonedDependency {
            return remote
        }

        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative, let isEnabled, let traits):
                guard isEnabled else { continue }
                let url = if isRelative {
                    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: currentFilePath))
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path, traits: traits)
                }
            }
        }
        return remote
    }
}

let package = Package(
    name: "MachOKitExtensions",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "MachOKitExtensions",
            targets: ["MachOKitExtensions"]
        ),
        // The reading layer MachOSwiftSection used to carry as targets of
        // its own: `Readable` and `ReadingContext` read typed values out of a
        // file, a loaded image or this process's memory; `Resolvable` and
        // `SymbolOrElement` read a value at an address, or name the symbol
        // dyld binds there.
        .library(
            name: "MachOReading",
            targets: ["MachOReading"]
        ),
        .library(
            name: "MachOResolving",
            targets: ["MachOResolving"]
        ),
    ],
    dependencies: [
        .package(
            local: .package(
                path: "../MachOKit",
                isRelative: true
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachOKit",
                // 0.52.0 is the first release with the `_cachedFullCache` SPI,
                // which hands a cache's sub-caches over without opening the
                // whole cache. 0.54.101 is the fork's release over upstream
                // 0.54.0; it reads an image without an export trie as
                // exporting nothing, where 0.53.0 through 0.54.100 trapped.
                // 0.55.102 hands over the bytes it mapped a file into
                // (`fileBytes`, SPI Support), which every MachOReading read of
                // a `MachOFile` goes through. MachOObjCSection and
                // MachOSwiftSection require it as well.
                from: "0.55.102"
            )
        ),
        .package(
            url: "https://github.com/p-x9/AssociatedObject",
            from: "0.13.0"
        ),
        // MachOReading reports a read past the end of a file as FileIO's
        // `offsetOutOfBounds`. MachOKit already depends on it; this lower
        // bound is MachOKit's own.
        .package(
            url: "https://github.com/p-x9/swift-fileio.git",
            from: "0.13.0"
        ),
    ],
    targets: [
        .target(
            name: "MachOKitExtensions",
            dependencies: [
                "MachOKit",
                .product(name: "AssociatedObject", package: "AssociatedObject"),
            ]
        ),
        .target(
            name: "MachOReading",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                .product(name: "FileIO", package: "swift-fileio"),
            ]
        ),
        .target(
            name: "MachOResolving",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                "MachOReading",
            ]
        ),
        .testTarget(
            name: "MachOKitExtensionsTests",
            dependencies: [
                "MachOKitExtensions",
                "MachOKit",
            ]
        ),
        .testTarget(
            name: "MachOReadingTests",
            dependencies: [
                "MachOReading",
                "MachOKitExtensions",
                "MachOKit",
            ]
        ),
    ]
)
