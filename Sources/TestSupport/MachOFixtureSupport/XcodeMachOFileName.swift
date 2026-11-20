import Foundation
import Darwin

/// A Mach-O file inside Xcode, named by where it sits under
/// `Xcode.app/Contents` and its name without extension.
///
/// A struct rather than an enum, so that a file the lists below miss is named
/// with `init(location:name:)`; the lists themselves name what an Xcode
/// ships, and `.sharedFrameworks(.SourceKitSupport)` picks from them.
public struct XcodeMachOFileName: Hashable, Sendable, CustomStringConvertible {
    /// The directory under `Xcode.app/Contents` a file sits in.
    public enum Location: String, Hashable, Sendable, CaseIterable {
        case frameworks = "Frameworks"
        case sharedFrameworks = "SharedFrameworks"
        case plugins = "Plugins"
    }

    public let location: Location

    /// The file's name without extension, such as `SourceKitSupport`.
    public let name: String

    public init(location: Location, name: String) {
        self.location = location
        self.name = name
    }

    public enum Frameworks: String, CaseIterable, Sendable {
        case AssetCatalogAppleTVFoundation
        case AssetCatalogAppleTVKit
        case AssetCatalogCocoaTouchFoundation
        case AssetCatalogCocoaTouchKit
        case AssetCatalogFoundation
        case AssetCatalogKit
        case AssetCatalogVisionExtensions
        case AssetCatalogVisionFoundation
        case AssetCatalogVisionKit
        case DVTNFASupport
        case DebuggerFoundation
        case DevToolsCore
        case DevToolsSupport
        case GameCenterResourcesAppStoreConnectClient
        case GameCenterResourcesCore
        case GameCenterResourcesCoreModels
        case IBAutolayoutFoundation
        case IBCocoaTouchToolFoundation
        case IDEEditorGalleryPreviewSupport
        case IDEEvaluationKit
        case IDEFoundation
        case IDEGameKitCommonEditor
        case IDEGameKitEditor
        case IDEGameKitInspectorCore
        case IDEGameKitInspectorEditor
        case IDEKit
        case IDELanguageModelKit
        case IDENoticesFoundation
        case IDENoticesKit
        case IDESettingsPanel
        case IDESimulatorFoundation
        case IDESourceEditorGalleryExhibit
        case IDETrayKit
        case SiriSSUKit
        case SiriSSUKitModel
        case Xcode3Core
        case Xcode3UI
        case libIDEApplicationLoader
        case libLTO
        case libclang
        case libswiftDemangle
        case libxcodebuildLoader
    }

    public enum SharedFrameworks: String, CaseIterable, Sendable {
        case AccessibilityAudit
        case AccessibilitySupport
        case AppResourceGeneration
        case AppThinning
        case AssetRuntimeSupport
        case AuthenticationAPI
        case BuildServerProtocol
        case ChooseIdentity
        case CodeCompletionFoundation
        case CodeCompletionKit
        case CodeGenerationIntelligence
        case CombineXPC
        case CommonXcodeCloudAPI
        case ContentDelivery
        case ContentDeliveryServices
        case CoreDocumentation
        case CoreSymbolicationDT
        case CreateMLSwiftProtobuf
        case DNTDocumentationModel
        case DNTDocumentationSupport
        case DNTSourceKitSupport
        case DNTTransformer
        case DTDeviceKit
        case DTDeviceKitBase
        case DTDeviceServices
        case DTGTGraph
        case DTGTTimeline
        case DTGanache
        case DTGanacheBufferViewer
        case DTGanacheImageProcessor
        case DTGanacheImageViewer
        case DTGanacheTensorViewer
        case DTGraphKit
        case DTMLOpGraph
        case DTXConnectionServices
        case DVTAnalytics
        case DVTAnalyticsClient
        case DVTAnalyticsKit
        case DVTAnalyticsMetrics
        case DVTAnalyticsMetricsClient
        case DVTAppStoreConnect
        case DVTCocoaAdditionsKit
        case DVTCoreDeviceCore
        case DVTCoreGlyphs
        case DVTCrashLogFoundation
        case DVTDeviceFoundation
        case DVTDeviceKit
        case DVTDeviceProvisioning
        case DVTDocumentation
        case DVTExplorableKit
        case DVTFeedbackReporting
        case DVTFoundation
        case DVTITunesSoftware
        case DVTITunesSoftwareServiceFoundation
        case DVTIconKit
        case DVTInstrumentsAnalysisCore
        case DVTInstrumentsFoundation
        case DVTInstrumentsUtilities
        case DVTKeychain
        case DVTKeychainService
        case DVTKeychainUtilities
        case DVTKit
        case DVTLibraryKit
        case DVTMacroFoundation
        case DVTMarkup
        case DVTPlaygroundCommunication
        case DVTPlaygroundStubMacServices
        case DVTPortal
        case DVTProducts
        case DVTProductsUI
        case DVTServices
        case DVTSmartSearch
        case DVTSourceControl
        case DVTSourceEditor
        case DVTStructuredLayoutKit
        case DVTSystemPrerequisites
        case DVTSystemPrerequisitesUI
        case DVTUserInterfaceKit
        case DVTViewControllerKit
        case DebugHierarchyFoundation
        case DebugHierarchyKit
        case DebugSymbolsDT
        case DeltaFoundation
        case DeltaKit
        case EventsAPI
        case GLTools
        case GLToolsAnalysisEngine
        case GLToolsCore
        case GLToolsExpert
        case GLToolsInterface
        case GLToolsServices
        case GLToolsShaderProfiler
        case GPUTools
        case GPUToolsCore
        case GPUToolsDesktopFoundation
        case GPUToolsMobileFoundation
        case GPUToolsPlatform
        case GPUToolsRenderer
        case GPUToolsServices
        case GPUToolsShaderProfiler
        case GameToolsFoundation
        case HexFiend
        case IDEAnalyticsMetrics
        case IDECodeGenerationIntelligence
        case IDEDistribution
        case IDEDistributionKit
        case IDEMLCompilerCore
        case IDEMLModelCore
        case IDEMLModelEditorKit
        case IDENotifications
        case IDENotificationsKit
        case IDEPlaygroundEditor
        case IDEPlaygroundExecution
        case IDEPlaygroundResultsFoundation
        case IDEPlaygroundResultsKit
        case IDEPlaygroundsFoundation
        case IDEPlaygroundsKit
        case IDEProducts
        case IDEResultKit
        case IndexStoreDB_CIndexStoreDB
        case IndexStoreDB_Core
        case IndexStoreDB_Database
        case IndexStoreDB_Index
        case IndexStoreDB_LLVMSupport
        case IndexStoreDB_Support
        case IndexStoreDatabase
        case LLDB
        case LLDBRPC
        case LanguageServerProtocol
        case LiveExecutionResultsFoundation
        case LiveExecutionResultsHost
        case Localization
        case LoggingSupportHost
        case MLCloudDeployment
        case MLCloudDeploymentXPCServiceProtocol
        case MLCore
        case MLCoreKit
        case MLDataSource
        case MLDataSourceKit
        case MLDocumentFormat
        case MLEvaluation
        case MLEvaluationKit
        case MLExperiment
        case MLExplorationKit
        case MLFeature
        case MLKnownObjectTracking
        case MLModelCore
        case MLModelFormatEditor
        case MLModelKit
        case MLPersistenceEngine
        case MLPersistenceEntity
        case MLRecipeCore
        case MLRecipeExecutionController
        case MLRecipeExecutionServiceProtocol
        case MLShared
        case MLSharedKit
        case MLToolsCoreML
        case MLTraceReport
        case MTLTools
        case MTLToolsAnalysisEngine
        case MTLToolsServices
        case MTLToolsShaderProfiler
        case MallocStackLoggingDT
        case ManagedBackgroundAssetsXcodeSupport
        case MarkupSupport
        case Notarization
        case ODTDevTool
        case OpenAPIRuntime
        case OpenAPIURLSession
        case PackedPaths
        case PreviewsDeveloperTools
        case PreviewsFoundationHost
        case PreviewsMessagingHost
        case PreviewsModel
        case PreviewsPipeline
        case PreviewsPlatforms
        case PreviewsScenes
        case PreviewsSyntax
        case PreviewsUI
        case PreviewsXROSMessaging
        case PreviewsXROSServices
        case PreviewsXcodeUI
        case RealityKitAdditions
        case RealityKitInspection
        case RealityToolKit
        case RealityToolsDeviceSupport
        case RecountDT
        case SourceEditor
        case SourceEditorRegExSupport
        case SourceEditorSwiftSupport
        case SourceKit
        case SourceKitLSPSupport
        case SourceKitSupport
        case SourceModel
        case SourceModelSupport
        case SpatialInspectorFoundation
        case SpatialInspectorHost
        case StatusAPI
        case SwiftBasicFormat
        case SwiftBuild
        case SwiftDiagnostics
        case SwiftIDEUtils
        case SwiftOperators
        case SwiftPM
        case SwiftParser
        case SwiftParserDiagnostics
        case SwiftRefactor
        case SwiftSyntax
        case SwiftSyntaxBuilder
        case SwiftSyntaxCShims
        case SwiftSyntaxSupport
        case SwiftUITracingSupportDT
        case SymbolCache
        case SymbolCacheIndexing
        case SymbolCacheSupport
        case SymbolicationDT
        case TestResultsUI
        case Testing
        case USDLib_FormatLoaderProxy_Xcode
        case UVTestSupport
        case XCBuild
        case XCResultKit
        case XCServices
        case XCSourceControl
        case XCStringsParser
        case XCTAutomationSupport
        case XCTDaemonControl
        case XCTDaemonControlMobileDevice
        case XCTHarness
        case XCTest
        case XCTestCore
        case XCTestSupport
        case XCUIAutomation
        case XCUnit
        case XcodeCloudAPI
        case XcodeCloudCombineAPI
        case XcodeCloudDataSource
        case XcodeCloudFoundation
        case XcodeCloudKit
        case XcodeCloudModels
        case XcodeCloudUI
        case _CodeCompletionFoundation
        case _Testing_Foundation
        case kperfdataDT
        case ktraceDT
        case libXCTestSwiftSupport
        case llbuild
        case swiftargumentparser_ArgumentParser
        public var pathComponent: String {
            "/SharedFrameworks/\(rawValue).framework"
        }
    }

    public enum Plugins: String, CaseIterable, Sendable {
        case AppShortcutsEditor
        case AppShortcutsEditorUI
        case DVTCorePlistStructDefs
        case DVTFeedbackReportingDiagnosticExtension
        case DVTiOSPlistStructDefs
        case DebugHelperSupportUI
        case DebuggerKit
        case DebuggerLLDB
        case DebuggerLLDBService
        case DebuggerUI
        case GPUDebugger
        case GPUDebuggerGLSupport
        case HexEditor
        case IBBuildSupport
        case IBCocoaBuildSupport
        case IBExternalGeniusResults
        case IDEAnalytics
        case IDEAnalyticsKit
        case IDEAnalyticsMetricsKit
        case IDEAnalyticsMetricsNotifications
        case IDEConsoleKit
        case IDEDelta
        case IDEDocViewer
        case IDEDocumentation
        case IDEDocumentationLivePreview
        case IDEIODebugGaugesCore
        case IDEIODebugGaugesUI
        case IDEInstrumentsService
        case IDEIntelligenceChat
        case IDEIntelligenceFoundation
        case IDEIntelligenceMessaging
        case IDEIntelligenceModelService
        case IDEIntentBuilderCore
        case IDEIntentBuilderEditor
        case IDEInterfaceBuilderCocoaIntegration
        case IDEInterfaceBuilderCocoaTouchIntegration
        case IDEInterfaceBuilderDFRSupport
        case IDEInterfaceBuilderEditorDFRSupport
        case IDEInterfaceBuilderKit
        case IDEInterfaceBuilderiOSIntegration
        case IDEInterfaceBuilderiOSMacIntegration
        case IDELocalizationCatalogCore
        case IDELocalizationCatalogEditor
        case IDEMLCodeGeneratorPlugin
        case IDEMLModelEditorPlugin
        case IDEMemoryGraphDebugger
        case IDEModelEditor
        case IDEModelFoundation
        case IDEPDFViewer
        case IDEPegasusSourceEditor
        case IDEPerformanceDebugger
        case IDEPlaygroundSimulator
        case IDEProductsUI
        case IDEQuickHelp
        case IDEQuickLookEditor
        case IDERTFEditor
        case IDESceneKitEditor
        case IDESourceControlUI
        case IDESourceEditor
        case IDESpriteKitParticleEditor
        case IDEStandardExecutionActionsCore
        case IDEStandardExecutionActionsUI
        case IDEStoreKitCore
        case IDEStoreKitEditor
        case IDESwiftPackageCore
        case IDESwiftPackageUI
        case IDETestPlanEditor
        case IDETestResultsUI
        case IDETestingPlatformSupport
        case IDETimeline
        case IDEXCBuildSupportCore
        case IDEXCBuildSupportUI
        case IDEXCStringsCommentGenerationSupport
        case IDEXCStringsSupport
        case IDEXCStringsSupportCore
        case IDEiOSDebugger
        case IDEiOSSupportCore
        case IDEiPhoneSupport
        case PlaygroundLiveExecution
        case PlistEditor
        case PreviewsIDEAPI
        case PreviewsXcode
        case PreviewsXcodeXROSSupport
        case PreviewsXcodeXROSUI
        case ProvisoningProfileQuicklookExtension
        case RCPIDEFoundation
        case RCPIDESupportCore
        case RCPIDESupportUI
        case ScriptingDefinitionEditor
        case SpatialInspectorXcodePlugin
        case XCCFeedbackReportingDiagnosticExtension
        case XcodeCloud
    }

    public static func frameworks(_ framework: Frameworks) -> XcodeMachOFileName {
        XcodeMachOFileName(location: .frameworks, name: framework.rawValue)
    }

    public static func sharedFrameworks(_ framework: SharedFrameworks) -> XcodeMachOFileName {
        XcodeMachOFileName(location: .sharedFrameworks, name: framework.rawValue)
    }

    public static func plugins(_ plugin: Plugins) -> XcodeMachOFileName {
        XcodeMachOFileName(location: .plugins, name: plugin.rawValue)
    }

    /// Every file the lists name.
    public static var allCases: [XcodeMachOFileName] {
        Frameworks.allCases.map { .frameworks($0) }
            + SharedFrameworks.allCases.map { .sharedFrameworks($0) }
            + Plugins.allCases.map { .plugins($0) }
    }

    /// The Xcode the files are read from.
    public static let contentsDirectoryPath = "/Applications/Xcode.app/Contents/"

    /// The file's path under ``contentsDirectoryPath``, without extension.
    public var relativePath: String {
        "\(location.rawValue)/\(name)"
    }

    /// The file, with whatever extension it has on disk (`.framework`,
    /// `.dylib`, `.ideplugin`). Without a match the path carries no
    /// extension, and reading it fails.
    public var url: URL {
        let pathWithoutExtension = Self.contentsDirectoryPath + relativePath
        return Self.firstMatch(ofPattern: pathWithoutExtension + ".*") ?? URL(fileURLWithPath: pathWithoutExtension)
    }

    public var description: String {
        relativePath
    }

    private static func firstMatch(ofPattern pattern: String) -> URL? {
        var globResult = glob_t()
        defer {
            globfree(&globResult)
        }
        guard glob(pattern, 0, nil, &globResult) == 0, globResult.gl_pathc > 0, let firstMatch = globResult.gl_pathv[0] else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: firstMatch))
    }
}
