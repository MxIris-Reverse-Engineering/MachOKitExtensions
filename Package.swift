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
        // C++ symbol names taken apart, and an image's C++ symbols arranged
        // by the scopes they sit in. Not part of `MachOFoundation`: it
        // carries a C++ demangler that most clients have no use for.
        .library(
            name: "CPlusPlusSymbols",
            targets: ["CPlusPlusSymbols"]
        ),
        // Test support this package's tests and MachOSwiftSection's share
        // (MachOSwiftSection proposal shared-macho-testing-support). Link them
        // to test targets only. `MachOFixtureSupport` names and opens the
        // images tests read and compiles throwaway libraries without the
        // testing library; `MachOTestingSupport` adds what needs it: test
        // base classes, cross-reader assertions and the per-image exclusion
        // trait.
        .library(
            name: "MachOFixtureSupport",
            targets: ["MachOFixtureSupport"]
        ),
        .library(
            name: "MachOTestingSupport",
            targets: ["MachOTestingSupport"]
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
        // `Mutex` from OSToolbox, the lock of every cache and registry here and
        // of the test support: the standard library's needs macOS 15,
        // OSAllocatedUnfairLock macOS 13, and this package reaches back to
        // macOS 10.15. MachOSwiftSection depends on it as well.
        .package(
            url: "https://github.com/Mx-Iris/FrameworkToolbox",
            from: "0.17.0"
        ),
    ],
    targets: [
        .target(
            name: "MachOKitExtensions",
            dependencies: [
                "MachOKit",
                .product(name: "AssociatedObject", package: "AssociatedObject"),
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ],
            path: "Sources/Core/MachOKitExtensions"
        ),
        .target(
            name: "MachOReading",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                .product(name: "FileIO", package: "swift-fileio"),
            ],
            path: "Sources/Reading/MachOReading"
        ),
        .target(
            name: "MachOResolving",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                "MachOReading",
            ],
            path: "Sources/Reading/MachOResolving"
        ),
        .target(
            name: "MachOPointers",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                "MachOReading",
                "MachOResolving",
            ],
            path: "Sources/Reading/MachOPointers"
        ),
        .target(
            name: "MachOCaches",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ],
            path: "Sources/Images/MachOCaches"
        ),
        .target(
            name: "MachODependencies",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ],
            path: "Sources/Images/MachODependencies"
        ),
        .target(
            name: "MachOSymbols",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                "MachOResolving",
                "MachOCaches",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ],
            path: "Sources/Symbols/MachOSymbols"
        ),
        .target(
            name: "MachOBase",
            dependencies: [
                "MachOKitExtensions",
                "MachOReading",
                "MachOResolving",
                "MachOPointers",
            ],
            path: "Sources/Umbrellas/MachOBase"
        ),
        .target(
            name: "MachOFoundation",
            dependencies: [
                "MachOBase",
                "MachOSymbols",
                "MachODependencies",
            ],
            path: "Sources/Umbrellas/MachOFoundation"
        ),
        // Hand readers for the few A64 encodings the analyses decode, and the
        // trampoline shapes the linker and the dyld cache builder emit.
        .target(
            name: "ARM64InstructionDecoding",
            path: "Sources/Analysis/ARM64InstructionDecoding"
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
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ],
            path: "Sources/Analysis/MachOAddressResolution"
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
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ],
            path: "Sources/Analysis/MachOCodeReferences"
        ),
        // LLVM's Itanium demangler, vendored verbatim from libc++abi under
        // `ItaniumDemangle/` (Apache-2.0 WITH LLVM-exception), behind a plain
        // C interface, so that Swift reads C++ names without C++
        // interoperability.
        .target(
            name: "CPlusPlusDemangling",
            path: "Sources/Symbols/CPlusPlusDemangling",
            exclude: [
                "ItaniumDemangle/ItaniumNodes.def",
                "ItaniumDemangle/LICENSE.TXT",
            ]
        ),
        .target(
            name: "CPlusPlusSymbols",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                "MachOResolving",
                "MachOCaches",
                "MachOSymbols",
                "MachOReading",
                "MachOAddressResolution",
                "MachODependencies",
                "CPlusPlusDemangling",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ],
            path: "Sources/Symbols/CPlusPlusSymbols"
        ),
        .target(
            name: "MachOFixtureSupport",
            dependencies: [
                "MachOKit",
                "MachOKitExtensions",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ],
            path: "Sources/TestSupport/MachOFixtureSupport"
        ),
        .target(
            name: "MachOTestingSupport",
            dependencies: [
                "MachOFixtureSupport",
                "MachOReading",
                "MachOKitExtensions",
                "MachOKit",
            ],
            path: "Sources/TestSupport/MachOTestingSupport"
        ),
        .testTarget(
            name: "MachOTestingSupportTests",
            dependencies: [
                "MachOTestingSupport",
                "MachOFixtureSupport",
                "MachOReading",
                "MachOKitExtensions",
                "MachOKit",
            ]
        ),
        // C++ code with known symbols for the C++ symbol index tests. Not a
        // product.
        .target(
            name: "CPlusPlusSymbolsFixture",
            path: "Tests/CPlusPlusSymbolsFixture"
        ),
        .testTarget(
            name: "CPlusPlusSymbolsTests",
            dependencies: [
                "MachOTestingSupport",
                "MachOFixtureSupport",
                "CPlusPlusSymbols",
                "CPlusPlusDemangling",
                "CPlusPlusSymbolsFixture",
                "MachOSymbols",
                "MachOResolving",
                "MachOReading",
                "MachODependencies",
                "MachOKitExtensions",
                "MachOKit",
            ]
        ),
        .testTarget(
            name: "MachOAddressResolutionTests",
            dependencies: [
                "MachOFixtureSupport",
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
                "MachOFixtureSupport",
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
                "MachOFixtureSupport",
                "MachODependencies",
                "MachOCaches",
                "MachOKitExtensions",
                "MachOKit",
            ]
        ),
        .testTarget(
            name: "MachOSymbolsTests",
            dependencies: [
                "MachOFixtureSupport",
                "MachOSymbols",
                "MachOResolving",
                "MachOKitExtensions",
                "MachOKit",
            ]
        ),
        .testTarget(
            name: "MachOReadingTests",
            dependencies: [
                "MachOFixtureSupport",
                "MachOReading",
                "MachOKitExtensions",
                "MachOKit",
            ]
        ),
    ],
    // `ItaniumDemangle.h` is C++17.
    cxxLanguageStandard: .cxx17
)

// MARK: - Upcoming features

// Every Swift target adopts three upcoming features that Swift 7 turns on:
// ExistentialAny, MemberImportVisibility and InferIsolatedConformances.
// MachOSwiftSection's proposal swift6-mode-and-upcoming-features covers the
// MachO packages together.
let upcomingFeatureSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + upcomingFeatureSettings
}

// MARK: - Tuist development workspace

// MachOSwiftSection's Tuist development workspace (its Documentations/Internal/TuistDevelopment.md)
// maps this package's tests with Tuist, which rejects shapes SwiftPM accepts: a test that depends on
// an executable target or on a macro target (Tuist builds a macro as a plugin, so `@testable import`
// of it finds no module), and a test that depends on a target no product contains. Only while Tuist
// resolves the packages, with TUIST_MAPS_LOCAL_PACKAGE_TESTS=1, the first kinds are left out — the
// macro expansion tests then run under `swift test` only — and the last kind gets a library product
// of its own. Nothing changes without the variable.
if Context.environment["TUIST_MAPS_LOCAL_PACKAGE_TESTS"] == "1" {
    let executableOrMacroTargetNames = Set(package.targets.filter { $0.type == .executable || $0.type == .macro }.map(\.name))
    func dependencyName(_ dependency: Target.Dependency) -> String? {
        switch dependency {
        case .targetItem(let name, _), .byNameItem(let name, _):
            return name
        default:
            return nil
        }
    }
    package.targets.removeAll { target in
        target.type == .test && target.dependencies.contains { dependency in
            dependencyName(dependency).map(executableOrMacroTargetNames.contains) ?? false
        }
    }
    let productTargetNames = Set(package.products.flatMap { product in (product as? Product.Library)?.targets ?? [] })
    let testDependencyNames = Set(package.targets.filter { $0.type == .test }.flatMap { $0.dependencies.compactMap(dependencyName) })
    package.products += package.targets
        .filter { target in target.type == .regular && testDependencyNames.contains(target.name) && !productTargetNames.contains(target.name) }
        .map { target in Product.library(name: target.name, targets: [target.name]) }
}
