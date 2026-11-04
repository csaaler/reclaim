import Foundation

/// One thing an inspector found and can clean up.
public struct InspectorItem: Sendable, Identifiable, Hashable {
    /// Stable within the inspector, e.g. "chrome.profile.Profile 11".
    public let id: String
    public let inspectorID: String
    public let title: String
    public let subtitle: String?
    /// Shown in review.
    public let whatYouLose: String
    public let allocatedBytes: Int64
    public let risk: RiskLevel
    public let lastUsed: Date?
    public let paths: [String]
    public let requirement: AppStateRequirement
    /// E.g. "Remove profile".
    public let actionTitle: String
    /// False for entries that are listed but never cleaned (errors, admin-only caches, the active
    /// Chrome profile, a cache whose tool is missing). Such items must never reach the cleanup list
    /// or a plan. Tool-based items may have empty `paths` and still be actionable.
    public let isActionable: Bool

    public init(
        id: String,
        inspectorID: String,
        title: String,
        subtitle: String? = nil,
        whatYouLose: String,
        allocatedBytes: Int64,
        risk: RiskLevel,
        lastUsed: Date?,
        paths: [String],
        requirement: AppStateRequirement,
        actionTitle: String,
        isActionable: Bool = true
    ) {
        self.id = id
        self.inspectorID = inspectorID
        self.title = title
        self.subtitle = subtitle
        self.whatYouLose = whatYouLose
        self.allocatedBytes = allocatedBytes
        self.risk = risk
        self.lastUsed = lastUsed
        self.paths = paths
        self.requirement = requirement
        self.actionTitle = actionTitle
        self.isActionable = isActionable
    }
}

/// Thrown by `Inspector.discover` when the inspector cannot run, e.g. a tool is missing.
public struct InspectorUnavailable: Error, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public init(_ reason: String) {
        self.reason = reason
    }
}

public struct InspectorContext: Sendable {
    public let home: URL
    public let tools: any ToolRunning
    public let sizer: any SizeMeasuring
    public let now: Date

    public init(home: URL, tools: any ToolRunning, sizer: any SizeMeasuring, now: Date = Date()) {
        self.home = home
        self.tools = tools
        self.sizer = sizer
        self.now = now
    }
}

/// An app-specific plugin that understands an app's internal structure.
///
/// Contract (checked for every registered inspector by `InspectorConformanceTests`):
/// - `id` is unique lowercase kebab-case; `displayName` is not empty.
/// - `claimedPatterns` start with `~/` or `/` and never touch a protected path.
/// - `discover` is read-only. It returns items or throws `InspectorUnavailable`; any other error
///   is a bug. Every item carries this inspector's `id`, a unique item `id`, a title and a
///   `whatYouLose` text, and absolute paths.
/// - `plan` never deletes anything itself; it returns steps for the `CleanupEngine`. It returns no
///   step for an item that is not actionable. Path steps stay inside the item's `paths`, 🔴
///   (`userData`) path steps use `.trash`, and `runTool` executables are absolute paths.
public protocol Inspector: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// For attribution into By App.
    var bundleIDs: [String] { get }
    /// `PathPattern` syntax.
    var claimedPatterns: [String] { get }
    /// The By Category group for the paths this inspector claims, e.g. `.developerTools`. `nil`
    /// (the default) groups them by location kind like any other path.
    var category: StorageCategory? { get }
    /// Directories to search for this inspector's command-line tools, in addition to the
    /// standard ones in `ToolLocator`. `~/` expands to the home directory. Default: none.
    var toolSearchDirectories: [String] { get }
    /// Read-only. Throws `InspectorUnavailable` when the inspector cannot run.
    func discover(in context: InspectorContext) async throws -> [InspectorItem]
    func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan
    func claimedPaths(in context: InspectorContext) async -> [String]
}

extension Inspector {
    public var category: StorageCategory? { nil }

    public var toolSearchDirectories: [String] { [] }

    /// Expands `claimedPatterns` against `context.home`. Absolute patterns are expanded as-is.
    public func claimedPaths(in context: InspectorContext) async -> [String] {
        claimedPatterns.flatMap { PathPattern.expand($0, home: context.home) }
    }
}
