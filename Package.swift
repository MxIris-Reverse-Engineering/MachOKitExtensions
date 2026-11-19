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
        // The rest of MachOSwiftSection's Mach-O layer, none of it Swift
        // specific: relative and indirect pointers, the per-image shared
        // cache and its eviction registry, dependency closures, and the
        // umbrella the ABI model imports.
        .library(
            name: "MachOPointers",
            targets: ["MachOPointers"]
        ),
        .library(
            name: "MachOCaches",
            targets: ["MachOCaches"]
        ),
        .library(
            name: "MachODependencies",
            targets: ["MachODependencies"]
        ),
        .library(
            name: "MachOSymbols",
            targets: ["MachOSymbols"]
        ),
        .library(
            name: "MachOBase",
            targets: ["MachOBase"]
        ),
        .library(
            name: "MachOFoundation",
            targets: ["MachOFoundation"]
        ),
        // The language-free layers of MachOSwiftSection's cross-reference
        // analysis. Their interfaces are `@_spi(Internals)`: they serve
        // MachOSwiftSection's `CrossReferenceAnalysis` and MachOObjCSection's
        // `ObjCCodeReferences`, and promise no stable API (MachOSwiftSection
        // proposal `move-cross-reference-layers`).
        .library(
            name: "ARM64InstructionDecoding",
            targets: ["ARM64InstructionDecoding"]
        ),
        .library(
            name: "MachOAddressResolution",
            targets: ["MachOAddressResolution"]
        ),
        .library(
            name: "MachOCodeReferences",
            targets: ["MachOCodeReferences"]
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
        .target(
            name: "MachOPointers",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                "MachOReading",
                "MachOResolving",
            ]
        ),
        .target(
            name: "MachOCaches",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
            ]
        ),
        .target(
            name: "MachODependencies",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
            ]
        ),
        .target(
            name: "MachOSymbols",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                "MachOResolving",
                "MachOCaches",
            ]
        ),
        .target(
            name: "MachOBase",
            dependencies: [
                "MachOKitExtensions",
                "MachOReading",
                "MachOResolving",
                "MachOPointers",
            ]
        ),
        .target(
            name: "MachOFoundation",
            dependencies: [
                "MachOBase",
                "MachOSymbols",
                "MachODependencies",
            ]
        ),
        // Hand readers for the few A64 encodings the analyses decode, and the
        // trampoline shapes the linker and the dyld cache builder emit.
        .target(
            name: "ARM64InstructionDecoding"
        ),
        // One image's address space and the stubs and pointer slots on the
        // way to a function, read from a Mach-O file.
        .target(
            name: "MachOAddressResolution",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                "MachOReading",
                "ARM64InstructionDecoding",
            ]
        ),
        // The language-free core of the cross-reference analysis: image
        // memory, function tables, the instruction scan and the recognizer
        // extension point. It knows no language; the Objective-C and Swift
        // layers plug in as recognizers.
        .target(
            name: "MachOCodeReferences",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                "MachOReading",
                "MachOAddressResolution",
                "ARM64InstructionDecoding",
            ]
        ),
        .testTarget(
            name: "MachOAddressResolutionTests",
            dependencies: [
                "MachOAddressResolution",
                "MachOReading",
                "ARM64InstructionDecoding",
                "MachOKitExtensions",
                "MachOKit",
            ]
        ),
        .testTarget(
            name: "MachOCodeReferencesTests",
            dependencies: [
                "MachOCodeReferences",
                "MachOAddressResolution",
                "ARM64InstructionDecoding",
                "MachOKitExtensions",
                "MachOKit",
            ]
        ),
        .testTarget(
            name: "MachOKitExtensionsTests",
            dependencies: [
                "MachOKitExtensions",
                "MachOKit",
                "MachOSymbols",
            ]
        ),
        .testTarget(
            name: "MachOPointersTests",
            dependencies: [
                "MachOPointers",
                "MachOReading",
                "MachOResolving",
            ]
        ),
        .testTarget(
            name: "MachOCachesTests",
            dependencies: [
                "MachOCaches",
                "MachOKitExtensions",
                "MachOKit",
            ]
        ),
        .testTarget(
            name: "MachODependenciesTests",
            dependencies: [
                "MachODependencies",
                "MachOCaches",
                "MachOKitExtensions",
                "MachOKit",
            ]
        ),
        .testTarget(
            name: "MachOSymbolsTests",
            dependencies: [
                "MachOSymbols",
                "MachOResolving",
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
