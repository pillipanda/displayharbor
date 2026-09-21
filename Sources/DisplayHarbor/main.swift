import AppKit
import ApplicationServices
import Foundation
import QuartzCore
import Sparkle
import UniformTypeIdentifiers

private extension Notification.Name {
    static let displayHarborOpenLicenseSettings = Notification.Name("DisplayHarbor.openLicenseSettings")
}

private enum L10n {
    private static let languagePreferenceKey = "DisplayHarbor.language"

    enum LanguagePreference: String {
        case system
        case chinese = "zh-Hans"
        case english = "en"
    }

    static var languagePreference: LanguagePreference {
        LanguagePreference(rawValue: UserDefaults.standard.string(forKey: languagePreferenceKey) ?? "") ?? .system
    }

    static func setLanguagePreference(_ preference: LanguagePreference) {
        UserDefaults.standard.set(preference.rawValue, forKey: languagePreferenceKey)
    }

    private static var localization: String {
        switch languagePreference {
        case .system:
            let language = Locale.preferredLanguages.first?.lowercased() ?? ""
            return language.hasPrefix("zh") ? "zh-Hans" : "en"
        case .chinese:
            return "zh-Hans"
        case .english:
            return "en"
        }
    }

    private static let bundle: Bundle = {
        // Packaged App bundles keep their localizations in Bundle.main. The
        // source-run debug build resolves them from the project Resources folder.
        if Bundle.main.url(forResource: "en", withExtension: "lproj") != nil
            || Bundle.main.url(forResource: "zh-Hans", withExtension: "lproj") != nil {
            return .main
        }
        let language = Locale.preferredLanguages.first?.lowercased() ?? ""
        let localization = language.hasPrefix("zh") ? "zh-Hans" : "en"
        let sourceResources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("\(localization).lproj", isDirectory: true)
        return Bundle(url: sourceResources) ?? .main
    }()

    private static var localizedBundle: Bundle {
        if Bundle.main.url(forResource: "en", withExtension: "lproj") != nil
            || Bundle.main.url(forResource: "zh-Hans", withExtension: "lproj") != nil {
            if let url = Bundle.main.url(forResource: localization, withExtension: "lproj"),
               let bundle = Bundle(url: url) {
                return bundle
            }
            return .main
        }
        let sourceResources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("(localization).lproj", isDirectory: true)
        return Bundle(url: sourceResources) ?? bundle
    }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, tableName: "Localizable", bundle: localizedBundle, value: key, comment: "")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    static var listSeparator: String { text("list.separator") }
}

private func displayHarborIcon() -> NSImage? {
    guard let image = NSImage(systemSymbolName: "rectangle.3.group.fill", accessibilityDescription: "DisplayHarbor") else {
        return nil
    }
    image.isTemplate = true
    image.size = NSSize(width: 64, height: 64)
    return image
}

// Native prototype for DisplayHarbor.
// The menu-bar -> capture -> restore chain is backed by durable local storage.

struct WindowSnapshot {
    let app: NSRunningApplication
    let bundleID: String
    let appName: String
    let pid: pid_t
    let title: String
    let windowIndex: Int
    let frame: CGRect
    let screen: NSScreen
    let isFullScreen: Bool?
}

struct PlacementRule: Codable {
    let bundleID: String
    let appName: String
    let displayID: String
    let displayLabel: String
    let title: String
    let windowIndex: Int
    let size: CGSize
    let normalizedFrame: CGRect
    let layoutPreset: String
    let isFullScreen: Bool?

    func frame(on screen: NSScreen) -> CGRect {
        let area = screen.visibleFrame
        return CGRect(
            x: area.minX + normalizedFrame.minX * area.width,
            y: area.minY + normalizedFrame.minY * area.height,
            width: normalizedFrame.width * area.width,
            height: normalizedFrame.height * area.height
        )
    }
}

@MainActor
private func requestExitApps(_ exitApps: [String: String]) -> [String] {
    var failedNames: [String] = []
    for (bundleID, appName) in exitApps.sorted(by: { $0.value.localizedStandardCompare($1.value) == .orderedAscending }) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated && $0.isFinishedLaunching
        }) else { continue }
        if !app.terminate() {
            failedNames.append(appName)
        }
    }
    return failedNames
}

struct DisplayDescriptor: Codable, Hashable {
    let id: String
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let isPrimary: Bool
}

struct EnvironmentSnapshot: Codable, Hashable {
    let key: String
    let label: String
    let displays: [DisplayDescriptor]
}

struct StoredScenario: Codable {
    let id: String
    var name: String
    var rules: [String: [PlacementRule]]
    var exitApps: [String: String]
    var isSystemDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, rules, exitApps, isSystemDefault
    }

    init(
        id: String,
        name: String,
        rules: [String: [PlacementRule]],
        exitApps: [String: String] = [:],
        isSystemDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rules = rules
        self.exitApps = exitApps
        self.isSystemDefault = isSystemDefault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rules = try container.decode([String: [PlacementRule]].self, forKey: .rules)
        exitApps = try container.decodeIfPresent([String: String].self, forKey: .exitApps) ?? [:]
        isSystemDefault = try container.decodeIfPresent(Bool.self, forKey: .isSystemDefault)
            ?? (id == "default" && (name == "默认" || name == "Default"))
    }

    var displayName: String {
        isSystemDefault ? L10n.text("Default") : name
    }
}

struct StoredEnvironment: Codable {
    let key: String
    var label: String
    var customName: String?
    var displays: [DisplayDescriptor]
    var scenarios: [String: StoredScenario]
    var activeScenarioID: String?

    var displayName: String { customName ?? L10n.text(displays.count == 1 ? "Single-display setup" : "%ld-display setup", displays.count) }
}

private struct LegacyStoredEnvironment: Codable {
    let key: String
    var label: String
    var customName: String?
    var displays: [DisplayDescriptor]
    var rules: [String: [PlacementRule]]
}

final class RuleStore {
    private(set) var currentEnvironment: EnvironmentSnapshot
    private var environments: [String: StoredEnvironment] = [:]
    private let storageURL: URL
    private(set) var lastPersistenceError: String?

    init(currentEnvironment: EnvironmentSnapshot) {
        self.currentEnvironment = currentEnvironment
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DisplayHarbor", isDirectory: true)
        self.storageURL = appSupport.appendingPathComponent("environments.json")
        load()
    }

    var allRules: [PlacementRule] {
        currentScenario?.rules.values.flatMap { $0 } ?? []
    }

    var storedEnvironments: [StoredEnvironment] {
        normalizeEnvironmentKeys()
        var result = Array(environments.values)
        if environments[currentEnvironment.key] == nil {
            result.append(makeEnvironment(from: currentEnvironment))
        }
        return result.sorted { lhs, rhs in
            if lhs.key == rhs.key { return false }
            if lhs.key == currentEnvironment.key { return true }
            if rhs.key == currentEnvironment.key { return false }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    func hasStoredEnvironment(_ key: String) -> Bool {
        environments[key] != nil
    }

    var currentEnvironmentName: String {
        environments[currentEnvironment.key]?.displayName ?? currentEnvironment.label
    }

    var currentScenarioName: String {
        currentScenario?.displayName ?? L10n.text("Default")
    }

    var currentScenarioID: String? {
        currentScenario?.id
    }

    var allBundleIDs: [String] {
        guard let scenario = currentScenario else { return [] }
        return Array(scenario.rules.keys)
    }

    func rules(for bundleID: String) -> [PlacementRule] {
        currentScenario?.rules[bundleID] ?? []
    }

    func rules(for bundleID: String, inEnvironment key: String, scenarioID: String? = nil) -> [PlacementRule] {
        guard let environment = environments[key] else { return [] }
        let id = scenarioID ?? environment.activeScenarioID
        return id.flatMap { environment.scenarios[$0]?.rules[bundleID] } ?? []
    }

    func exitApps(inEnvironment key: String, scenarioID: String? = nil) -> [String: String] {
        guard let environment = environments[key] else { return [:] }
        let id = scenarioID ?? environment.activeScenarioID
        return id.flatMap { environment.scenarios[$0]?.exitApps } ?? [:]
    }

    func displayLabel(for rule: PlacementRule, inEnvironment key: String) -> String {
        guard let display = environments[key]?.displays.first(where: { $0.id == rule.displayID }) else {
            return rule.displayLabel
        }
        return display.isPrimary ? L10n.text("Main Display · %@", display.name) : display.name
    }

    func scenarios(for environmentKey: String) -> [StoredScenario] {
        let scenarios: [StoredScenario]
        if let stored = environments[environmentKey]?.scenarios.values {
            scenarios = Array(stored)
        } else if environmentKey == currentEnvironment.key {
            scenarios = Array(makeEnvironment(from: currentEnvironment).scenarios.values)
        } else {
            scenarios = []
        }
        return scenarios.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func activeScenarioID(for environmentKey: String) -> String? {
        environments[environmentKey]?.activeScenarioID
            ?? (environmentKey == currentEnvironment.key ? "default" : nil)
    }

    @discardableResult
    func save(_ rules: [PlacementRule]) -> Bool {
        guard let bundleID = rules.first?.bundleID else { return false }
        let previous = environments[currentEnvironment.key]
        var environment = environments[currentEnvironment.key] ?? makeEnvironment(from: currentEnvironment)
        environment.label = currentEnvironment.label
        environment.displays = currentEnvironment.displays
        let scenarioID = environment.activeScenarioID ?? "default"
        if environment.scenarios[scenarioID] == nil {
            environment.scenarios[scenarioID] = StoredScenario(id: scenarioID, name: "Default", rules: [:], isSystemDefault: true)
        }
        environment.scenarios[scenarioID]?.rules[bundleID] = rules
        environment.activeScenarioID = scenarioID
        environments[currentEnvironment.key] = environment
        guard persist() else {
            if let previous {
                environments[currentEnvironment.key] = previous
            } else {
                environments.removeValue(forKey: currentEnvironment.key)
            }
            return false
        }
        return true
    }

    @discardableResult
    func addExitApps(
        _ apps: [String: String],
        inEnvironment key: String,
        scenarioID: String
    ) -> Bool {
        guard var environment = environments[key],
              var scenario = environment.scenarios[scenarioID] else { return false }
        let previous = environment
        for (bundleID, appName) in apps where scenario.rules[bundleID] == nil {
            scenario.exitApps[bundleID] = appName
        }
        environment.scenarios[scenarioID] = scenario
        environments[key] = environment
        guard persist() else {
            environments[key] = previous
            return false
        }
        return true
    }

    @discardableResult
    func removeExitApp(
        bundleID: String,
        fromEnvironment key: String,
        scenarioID: String
    ) -> Bool {
        guard var environment = environments[key],
              var scenario = environment.scenarios[scenarioID] else { return false }
        let previous = environment
        scenario.exitApps.removeValue(forKey: bundleID)
        environment.scenarios[scenarioID] = scenario
        environments[key] = environment
        guard persist() else {
            environments[key] = previous
            return false
        }
        return true
    }

    @discardableResult
    func remove(bundleID: String) -> Bool {
        let previous = environments[currentEnvironment.key]
        guard let scenarioID = environments[currentEnvironment.key]?.activeScenarioID else { return false }
        environments[currentEnvironment.key]?.scenarios[scenarioID]?.rules.removeValue(forKey: bundleID)
        guard persist() else {
            environments[currentEnvironment.key] = previous
            return false
        }
        return true
    }

    @discardableResult
    func renameEnvironment(key: String, to name: String?) -> Bool {
        let previous = environments[key]
        guard var environment = environments[key]
                ?? (key == currentEnvironment.key ? makeEnvironment(from: currentEnvironment) : nil) else { return false }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        environment.customName = trimmed.isEmpty ? nil : trimmed
        environments[key] = environment
        guard persist() else {
            if let previous {
                environments[key] = previous
            } else {
                environments.removeValue(forKey: key)
            }
            return false
        }
        return true
    }

    @discardableResult
    func removeEnvironment(key: String) -> Bool {
        let previous = environments[key]
        environments.removeValue(forKey: key)
        guard persist() else {
            if let previous {
                environments[key] = previous
            }
            return false
        }
        return true
    }

    @discardableResult
    func removeRule(bundleID: String, fromEnvironment key: String) -> Bool {
        removeRule(bundleID: bundleID, fromEnvironment: key, scenarioID: nil)
    }

    @discardableResult
    func removeRule(bundleID: String, fromEnvironment key: String, scenarioID: String?) -> Bool {
        let previous = environments[key]
        guard let activeID = environments[key]?.activeScenarioID else { return false }
        let targetID = scenarioID ?? activeID
        environments[key]?.scenarios[targetID]?.rules.removeValue(forKey: bundleID)
        guard persist() else {
            environments[key] = previous
            return false
        }
        return true
    }

    func hasRulesForOtherEnvironment(bundleID: String) -> Bool {
        environments.contains { key, environment in
            key != currentEnvironment.key && environment.scenarios.values.contains { $0.rules[bundleID] != nil }
        }
    }

    @discardableResult
    func selectScenario(environmentKey: String, scenarioID: String) -> Bool {
        guard environments[environmentKey]?.scenarios[scenarioID] != nil else { return false }
        let previous = environments[environmentKey]
        environments[environmentKey]?.activeScenarioID = scenarioID
        guard persist() else {
            environments[environmentKey] = previous
            return false
        }
        return true
    }

    @discardableResult
    func createScenario(environmentKey: String, name: String?, forkFrom sourceID: String?) -> String? {
        guard var environment = environments[environmentKey] else { return nil }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = sourceID.flatMap { environment.scenarios[$0] }
        let scenario = StoredScenario(
            id: UUID().uuidString,
            name: trimmed.isEmpty ? L10n.text("New workspace") : trimmed,
            rules: source?.rules ?? [:],
            exitApps: source?.exitApps ?? [:]
        )
        let previous = environment
        environment.scenarios[scenario.id] = scenario
        environment.activeScenarioID = scenario.id
        environments[environmentKey] = environment
        guard persist() else {
            environments[environmentKey] = previous
            return nil
        }
        return scenario.id
    }

    @discardableResult
    func renameScenario(environmentKey: String, scenarioID: String, to name: String?) -> Bool {
        guard var environment = environments[environmentKey],
              var scenario = environment.scenarios[scenarioID] else { return false }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        scenario.name = trimmed.isEmpty ? "Default" : trimmed
        scenario.isSystemDefault = false
        let previous = environment
        environment.scenarios[scenarioID] = scenario
        environments[environmentKey] = environment
        guard persist() else {
            environments[environmentKey] = previous
            return false
        }
        return true
    }

    @discardableResult
    func removeScenario(environmentKey: String, scenarioID: String) -> Bool {
        guard var environment = environments[environmentKey],
              environment.scenarios.count > 1,
              environment.scenarios[scenarioID] != nil else { return false }
        let previous = environment
        environment.scenarios.removeValue(forKey: scenarioID)
        if environment.activeScenarioID == scenarioID {
            environment.activeScenarioID = environment.scenarios.keys.sorted().first
        }
        environments[environmentKey] = environment
        guard persist() else {
            environments[environmentKey] = previous
            return false
        }
        return true
    }

    private var currentScenario: StoredScenario? {
        guard let environment = environments[currentEnvironment.key],
              let scenarioID = environment.activeScenarioID else { return nil }
        return environment.scenarios[scenarioID]
    }

    private func makeEnvironment(from snapshot: EnvironmentSnapshot) -> StoredEnvironment {
        let scenario = StoredScenario(id: "default", name: "Default", rules: [:], isSystemDefault: true)
        return StoredEnvironment(
            key: snapshot.key,
            label: snapshot.label,
            customName: nil,
            displays: snapshot.displays,
            scenarios: [scenario.id: scenario],
            activeScenarioID: scenario.id
        )
    }

    private func normalizeEnvironmentKeys() {
        var grouped: [String: [StoredEnvironment]] = [:]
        for environment in environments.values {
            grouped[topologyKey(for: environment.displays), default: []].append(environment)
        }
        let needsNormalization = grouped.values.contains { group in
            group.count > 1 || group.first.map { $0.key != topologyKey(for: $0.displays) } == true
        }
        guard needsNormalization else { return }

        var normalized: [String: StoredEnvironment] = [:]
        for (key, group) in grouped {
            guard var base = group.first else { continue }
            var scenarios = base.scenarios
            for environment in group.dropFirst() {
                if base.customName == nil { base.customName = environment.customName }
                if base.activeScenarioID == nil { base.activeScenarioID = environment.activeScenarioID }
                for (scenarioID, incoming) in environment.scenarios {
                    if var existing = scenarios[scenarioID] {
                        existing.rules.merge(incoming.rules) { current, _ in current }
                        scenarios[scenarioID] = existing
                    } else {
                        scenarios[scenarioID] = incoming
                    }
                }
            }
            if base.activeScenarioID == nil || base.scenarios[base.activeScenarioID ?? ""] == nil {
                base.activeScenarioID = scenarios.keys.sorted().first
            }
            base.scenarios = scenarios
            normalized[key] = StoredEnvironment(
                key: key,
                label: base.label,
                customName: base.customName,
                displays: base.displays,
                scenarios: base.scenarios,
                activeScenarioID: base.activeScenarioID
            )
        }
        environments = normalized
        _ = persist()
    }

    private func topologyKey(for displays: [DisplayDescriptor]) -> String {
        displays.sorted {
            if $0.frame.minX == $1.frame.minX { return $0.frame.minY < $1.frame.minY }
            return $0.frame.minX < $1.frame.minX
        }.map { display in
            [
                display.id,
                display.isPrimary ? "primary" : "secondary",
                String(format: "%.1f", Double(display.frame.minX)),
                String(format: "%.1f", Double(display.frame.minY)),
                String(format: "%.1f", Double(display.frame.width)),
                String(format: "%.1f", Double(display.frame.height))
            ].joined(separator: ":")
        }.joined(separator: "|")
    }

    @discardableResult
    func updateEnvironment(_ environment: EnvironmentSnapshot) -> Bool {
        let changed = currentEnvironment.key != environment.key
        currentEnvironment = environment
        return changed
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: storageURL)
            do {
                environments = try JSONDecoder().decode([String: StoredEnvironment].self, from: data)
            } catch {
                let legacy = try JSONDecoder().decode([String: LegacyStoredEnvironment].self, from: data)
                environments = legacy.mapValues { old in
                    let scenario = StoredScenario(id: "default", name: "Default", rules: old.rules, isSystemDefault: true)
                    return StoredEnvironment(
                        key: old.key,
                        label: old.label,
                        customName: old.customName,
                        displays: old.displays,
                        scenarios: [scenario.id: scenario],
                        activeScenarioID: scenario.id
                    )
                }
                _ = persist()
            }
            normalizeEnvironmentKeys()
        } catch {
            let backupURL = storageURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: storageURL, to: backupURL)
            lastPersistenceError = L10n.text("The rules file was corrupted and backed up as %@", backupURL.lastPathComponent)
        }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            let data = try JSONEncoder().encode(environments)
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: .atomic)
            lastPersistenceError = nil
            return true
        } catch {
            lastPersistenceError = error.localizedDescription
            return false
        }
    }
}

@MainActor
enum DisplayInfo {
    static func id(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.localizedName
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let uuid = unmanagedUUID.takeRetainedValue()
            return CFUUIDCreateString(nil, uuid) as String
        }
        return String(displayID)
    }

    static func label(for screen: NSScreen) -> String {
        let isPrimary = screen.frame.origin == NSScreen.screens.first?.frame.origin
        return isPrimary ? L10n.text("Main Display · %@", screen.localizedName) : screen.localizedName
    }

    static func screen(containing frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            intersectionArea(frame, lhs.frame) < intersectionArea(frame, rhs.frame)
        }
    }

    static func screen(withID id: String) -> NSScreen? {
        NSScreen.screens.first { DisplayInfo.id(for: $0) == id }
    }

    static var fallbackScreen: NSScreen? {
        NSScreen.screens.first
    }

    static func appKitFrame(fromAccessibilityFrame frame: CGRect) -> CGRect {
        guard let primary = primaryScreen else { return frame }
        return CGRect(
            x: frame.minX + primary.frame.minX,
            y: primary.frame.maxY - frame.minY - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    static func accessibilityFrame(fromAppKitFrame frame: CGRect) -> CGRect {
        guard let primary = primaryScreen else { return frame }
        return CGRect(
            x: frame.minX - primary.frame.minX,
            y: primary.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func currentEnvironment() -> EnvironmentSnapshot {
        let primaryFrameOrigin = NSScreen.screens.first?.frame.origin ?? .zero
        let displays = NSScreen.screens.map { screen in
            DisplayDescriptor(
                id: id(for: screen),
                name: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isPrimary: screen.frame.origin == primaryFrameOrigin
            )
        }.sorted { lhs, rhs in
            if lhs.frame.minX == rhs.frame.minX { return lhs.frame.minY < rhs.frame.minY }
            return lhs.frame.minX < rhs.frame.minX
        }

        let signature = displays.map { display in
            [
                display.id,
                display.isPrimary ? "primary" : "secondary",
                number(display.frame.minX), number(display.frame.minY),
                number(display.frame.width), number(display.frame.height)
            ].joined(separator: ":")
        }.joined(separator: "|")

        let label: String
        if displays.count <= 1 {
            label = L10n.text("Single-display setup")
        } else {
            label = L10n.text("%ld-display setup", displays.count)
        }
        return EnvironmentSnapshot(key: signature, label: label, displays: displays)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static var primaryScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

@MainActor
enum ApplicationIcon {
    private static var cachedImages: [String: NSImage] = [:]
    private static var resolvedBundleIDs = Set<String>()

    static func image(for bundleID: String) -> NSImage? {
        if resolvedBundleIDs.contains(bundleID) {
            return cachedImages[bundleID]
        }

        let image: NSImage?
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            image = runningApp.icon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = nil
        }
        resolvedBundleIDs.insert(bundleID)
        if let image {
            cachedImages[bundleID] = image
        }
        return image
    }
}

@MainActor
final class DisplayArrangementView: NSView {
    static let preferredHeight: CGFloat = 128

    private let displays: [DisplayDescriptor]
    private var highlightedRules: [PlacementRule] = []

    init(displays: [DisplayDescriptor]) {
        self.displays = displays
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    func highlight(_ rules: [PlacementRule]) {
        highlightedRules = rules
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layout = displayFrames() else { return }

        for display in displays {
            guard let frame = layout.frames[display.id] else { continue }
            let path = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
            NSColor.quaternaryLabelColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let label = displayLabel(for: display, in: frame, attributes: attributes)
            guard !label.isEmpty else { continue }
            let labelSize = (label as NSString).size(withAttributes: attributes)
            let labelRect = NSRect(
                x: frame.midX - labelSize.width / 2,
                y: frame.midY - labelSize.height / 2,
                width: labelSize.width,
                height: labelSize.height
            )
            (label as NSString).draw(in: labelRect, withAttributes: attributes)
        }

        for rule in highlightedRules {
            guard let displayFrame = layout.frames[rule.displayID],
                  let visibleFrame = layout.visibleFrames[rule.displayID] else { continue }
            let frame = NSRect(
                x: visibleFrame.minX + rule.normalizedFrame.minX * visibleFrame.width,
                y: visibleFrame.minY + rule.normalizedFrame.minY * visibleFrame.height,
                width: rule.normalizedFrame.width * visibleFrame.width,
                height: rule.normalizedFrame.height * visibleFrame.height
            ).intersection(displayFrame)
            guard !frame.isEmpty else { continue }
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func displayLabel(
        for display: DisplayDescriptor,
        in frame: NSRect,
        attributes: [NSAttributedString.Key: Any]
    ) -> String {
        let candidates = display.isPrimary
            ? [L10n.text("Main Display · %@", display.name), display.name, L10n.text("Main Display")]
            : [display.name, ""]
        let availableWidth = frame.width - 16
        return candidates.first { candidate in
            (candidate as NSString).size(withAttributes: attributes).width <= availableWidth
        } ?? ""
    }

    private func displayFrames() -> (frames: [String: NSRect], visibleFrames: [String: NSRect])? {
        guard let union = displays.map(\.frame).reduce(nil, { partial, frame in
            partial.map { $0.union(frame) } ?? frame
        }), union.width > 0, union.height > 0 else {
            return nil
        }

        let canvas = bounds.insetBy(dx: 8, dy: 8)
        let scale = min(canvas.width / union.width, canvas.height / union.height)
        let size = NSSize(width: union.width * scale, height: union.height * scale)
        let origin = NSPoint(x: canvas.midX - size.width / 2, y: canvas.midY - size.height / 2)
        let frames = Dictionary(uniqueKeysWithValues: displays.map { display in
            let frame = NSRect(
                x: origin.x + (display.frame.minX - union.minX) * scale,
                y: origin.y + (display.frame.minY - union.minY) * scale,
                width: display.frame.width * scale,
                height: display.frame.height * scale
            )
            return (display.id, frame)
        })
        let visibleFrames = Dictionary(uniqueKeysWithValues: displays.compactMap { display -> (String, NSRect)? in
            guard let frame = frames[display.id] else { return nil }
            let visibleFrame = NSRect(
                x: frame.minX + (display.visibleFrame.minX - display.frame.minX) / display.frame.width * frame.width,
                y: frame.minY + (display.visibleFrame.minY - display.frame.minY) / display.frame.height * frame.height,
                width: display.visibleFrame.width / display.frame.width * frame.width,
                height: display.visibleFrame.height / display.frame.height * frame.height
            )
            return (display.id, visibleFrame)
        })
        return (frames, visibleFrames)
    }
}

@MainActor
final class HoverableRuleRow: NSView {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private static weak var activeRow: HoverableRuleRow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            setHovering(false)
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        if hovering {
            Self.activeRow?.setHovering(false)
            Self.activeRow = self
        } else if Self.activeRow === self {
            Self.activeRow = nil
        }
        isHovering = hovering
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer?.backgroundColor = hovering
            ? NSColor.systemGray.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
        CATransaction.commit()
        onHover?(hovering)
    }
}

@MainActor
final class RuleDetailSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        layer?.cornerRadius = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class HoverFeedbackButton: NSButton {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var normalTintColor = NSColor.labelColor
    private var hoverTintColor: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovering = true
        updateAppearance(animated: true)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        resetAppearance(animated: true)
        onHoverChanged?(false)
    }

    override func viewDidMoveToWindow() {
        if window == nil {
            resetAppearance(animated: false)
        }
        super.viewDidMoveToWindow()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        animate(scale: 0.97, background: nil)
        super.mouseDown(with: event)
        updateAppearance(animated: true)
    }

    private func configure() {
        bezelStyle = .inline
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = false
        updateAppearance(animated: false)
    }

    private func updateAppearance(animated: Bool) {
        let textColor = isHovering
            ? (hoverTintColor ?? normalTintColor.blended(withFraction: 0.2, of: .black) ?? normalTintColor)
            : normalTintColor
        contentTintColor = textColor
        animate(scale: 1, background: nil, animated: animated)
    }

    private func resetAppearance(animated: Bool) {
        isHovering = false
        contentTintColor = normalTintColor
        if animated {
            animate(scale: 1, background: nil, animated: true)
        } else {
            layer?.removeAllAnimations()
            layer?.transform = CATransform3DIdentity
            layer?.backgroundColor = nil
        }
    }

    func setNormalTintColor(_ color: NSColor) {
        normalTintColor = color
        contentTintColor = color
    }

    func setHoverTintColor(_ color: NSColor?) {
        hoverTintColor = color
        updateAppearance(animated: false)
    }

    private func animate(scale: CGFloat, background: NSColor?, animated: Bool = true) {
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.16 : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer?.backgroundColor = background?.cgColor
        layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }
}

@MainActor
enum WindowProbe {
    static func isDesktopOnlyFinder(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier == "com.apple.finder" else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let value = attribute(axApp, kAXWindowsAttribute),
              let windows = value as? [AXUIElement] else {
            return false
        }
        let standardWindows = windows.filter(isStandardWindow)
        guard !standardWindows.isEmpty else { return false }
        return standardWindows.allSatisfy(isFinderDesktopWindow)
    }

    static func snapshot(for app: NSRunningApplication) -> WindowSnapshot? {
        guard let bundleID = app.bundleIdentifier,
              let window = firstWindow(for: app),
              let frame = frame(of: window),
              let screen = DisplayInfo.screen(containing: frame) else {
            return nil
        }

        let title = stringAttribute(window, kAXTitleAttribute) ?? L10n.text("Current window")
        return WindowSnapshot(
            app: app,
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            pid: app.processIdentifier,
            title: title,
            windowIndex: 0,
            frame: frame,
            screen: screen,
            isFullScreen: fullScreenState(of: window)
        )
    }

    static func snapshots(for app: NSRunningApplication) -> [WindowSnapshot] {
        guard let bundleID = app.bundleIdentifier else { return [] }
        return windows(for: app).enumerated().compactMap { index, window in
            guard let frame = frame(of: window),
                  let screen = DisplayInfo.screen(containing: frame) else {
                return nil
            }
            return WindowSnapshot(
                app: app,
                bundleID: bundleID,
                appName: app.localizedName ?? bundleID,
                pid: app.processIdentifier,
                title: stringAttribute(window, kAXTitleAttribute) ?? L10n.text("Current window"),
                windowIndex: index,
                frame: frame,
                screen: screen,
                isFullScreen: fullScreenState(of: window)
            )
        }
    }

    static func hasVisibleWindow(for app: NSRunningApplication) -> Bool {
        windows(for: app).contains { window in
            let minimized = (attribute(window, kAXMinimizedAttribute) as? Bool) ?? false
            let hidden = (attribute(window, kAXHiddenAttribute) as? Bool) ?? false
            return !minimized && !hidden
        }
    }

    static func restore(app: NSRunningApplication, using rules: [PlacementRule]) -> Int {
        guard !rules.isEmpty else { return 0 }
        let windows = windows(for: app)
        var used = Set<Int>()
        var restoredCount = 0

        for rule in rules.sorted(by: { $0.windowIndex < $1.windowIndex }) {
            guard let match = matchingWindow(for: rule, in: windows, excluding: used),
                  let targetScreen = DisplayInfo.screen(withID: rule.displayID) ?? DisplayInfo.fallbackScreen else {
                continue
            }
            if rule.isFullScreen == true {
                guard let current = fullScreenState(of: match.window) else {
                    _ = setFullScreen(true, on: match.window)
                    continue
                }
                if !current {
                    _ = setFullScreen(true, on: match.window)
                    continue
                }
                guard let currentFrame = frame(of: match.window),
                      let currentScreen = DisplayInfo.screen(containing: currentFrame) else { continue }
                if DisplayInfo.id(for: currentScreen) != rule.displayID {
                    _ = setFullScreen(false, on: match.window)
                    continue
                }
                used.insert(match.index)
                restoredCount += 1
                continue
            }
            if rule.isFullScreen == false,
               let current = fullScreenState(of: match.window), current {
                _ = setFullScreen(false, on: match.window)
                continue
            }
            if setFrame(rule.frame(on: targetScreen), on: match.window) {
                used.insert(match.index)
                restoredCount += 1
            }
        }
        return restoredCount
    }

    static func layoutMatches(snapshots: [WindowSnapshot], rules: [PlacementRule]) -> Bool {
        guard snapshots.count == rules.count else { return false }
        var used = Set<Int>()

        for rule in rules.sorted(by: { $0.windowIndex < $1.windowIndex }) {
            let available = snapshots.enumerated().filter { !used.contains($0.offset) }
            let match = available.first(where: { $0.element.title == rule.title })
                ?? available.first(where: { snapshot in
                    abs(snapshot.element.frame.width - rule.size.width) < 80
                        && abs(snapshot.element.frame.height - rule.size.height) < 80
                })
                ?? available.first
            guard let match else { return false }
            used.insert(match.offset)

            let snapshot = match.element
            guard DisplayInfo.id(for: snapshot.screen) == rule.displayID else { return false }
            if let expectedFullScreen = rule.isFullScreen,
               snapshot.isFullScreen != expectedFullScreen {
                return false
            }
            if rule.isFullScreen != true {
                let expectedFrame = rule.frame(on: snapshot.screen)
                let tolerance: CGFloat = 3
                guard abs(snapshot.frame.minX - expectedFrame.minX) <= tolerance,
                      abs(snapshot.frame.minY - expectedFrame.minY) <= tolerance,
                      abs(snapshot.frame.width - expectedFrame.width) <= tolerance,
                      abs(snapshot.frame.height - expectedFrame.height) <= tolerance else {
                    return false
                }
            }
        }
        return true
    }

    private static func windows(for app: NSRunningApplication) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let value = attribute(axApp, kAXWindowsAttribute),
              let windows = value as? [AXUIElement] else {
            return []
        }
        return windows.filter(isStandardWindow)
    }

    private static func firstWindow(for app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        if let focused = attribute(axApp, kAXFocusedWindowAttribute) {
            return unsafeDowncast(focused, to: AXUIElement.self)
        }
        return windows(for: app).first
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        let role = stringAttribute(window, kAXRoleAttribute)
        let subrole = stringAttribute(window, kAXSubroleAttribute)
        return role == kAXWindowRole && subrole == kAXStandardWindowSubrole
    }

    private static func isFinderDesktopWindow(_ window: AXUIElement) -> Bool {
        let title = stringAttribute(window, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDesktopTitle = title == nil || title?.isEmpty == true || title == "Desktop" || title == "桌面"
        guard isDesktopTitle,
              let frame = frame(of: window),
              let screen = DisplayInfo.screen(containing: frame) else {
            return false
        }
        return frame.width >= screen.frame.width * 0.95
            && frame.height >= screen.frame.height * 0.95
    }

    private struct WindowMatch {
        let index: Int
        let window: AXUIElement
    }

    private static func matchingWindow(
        for rule: PlacementRule,
        in windows: [AXUIElement],
        excluding used: Set<Int>
    ) -> WindowMatch? {
        let available = windows.enumerated().filter { !used.contains($0.offset) }
        let titleMatches = available.filter { stringAttribute($0.element, kAXTitleAttribute) == rule.title }
        let candidates = titleMatches.isEmpty ? available : titleMatches
        let targetScreen = DisplayInfo.screen(withID: rule.displayID)
        let targetFrame = targetScreen.map { rule.frame(on: $0) }
        guard let best = candidates.min(by: { lhs, rhs in
            matchScore(window: lhs.element, targetFrame: targetFrame, targetScreenID: rule.displayID)
                < matchScore(window: rhs.element, targetFrame: targetFrame, targetScreenID: rule.displayID)
        }) else { return nil }
        return WindowMatch(index: best.offset, window: best.element)
    }

    private static func matchScore(window: AXUIElement, targetFrame: CGRect?, targetScreenID: String) -> CGFloat {
        guard let currentFrame = frame(of: window) else { return .greatestFiniteMagnitude }
        var score = abs(currentFrame.width - (targetFrame?.width ?? currentFrame.width))
            + abs(currentFrame.height - (targetFrame?.height ?? currentFrame.height))
        if let targetFrame {
            score += abs(currentFrame.midX - targetFrame.midX) + abs(currentFrame.midY - targetFrame.midY)
        }
        if let screen = DisplayInfo.screen(containing: currentFrame), DisplayInfo.id(for: screen) != targetScreenID {
            score += 10_000
        }
        return score
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute),
              let size = attribute(window, kAXSizeAttribute) else {
            return nil
        }

        let positionValue = unsafeDowncast(position, to: AXValue.self)
        let axSizeValue = unsafeDowncast(size, to: AXValue.self)

        var point = CGPoint.zero
        var windowSize = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(axSizeValue, .cgSize, &windowSize) else {
            return nil
        }
        return DisplayInfo.appKitFrame(fromAccessibilityFrame: CGRect(origin: point, size: windowSize))
    }

    private static func setFrame(_ frame: CGRect, on window: AXUIElement) -> Bool {
        let accessibilityFrame = DisplayInfo.accessibilityFrame(fromAppKitFrame: frame)
        var position = accessibilityFrame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return positionResult == .success && sizeResult == .success
    }

    private static let fullScreenAttribute = "AXFullScreen"

    private static func fullScreenState(of window: AXUIElement) -> Bool? {
        guard let value = attribute(window, fullScreenAttribute) else { return nil }
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func setFullScreen(_ desired: Bool, on window: AXUIElement) -> Bool {
        let value = NSNumber(value: desired)
        let result = AXUIElementSetAttributeValue(window, fullScreenAttribute as CFString, value)
        if result == .success {
            return true
        }

        // Some apps expose AXFullScreen as readable but not writable. In that
        // case, press the native full-screen button as a best-effort fallback.
        guard let button = attribute(window, "AXFullScreenButton") else { return false }
        let buttonElement = unsafeDowncast(button, to: AXUIElement.self)
        return AXUIElementPerformAction(buttonElement, kAXPressAction as CFString) == .success
    }

    private static func stringAttribute(_ element: AXUIElement, _ attributeName: String) -> String? {
        attribute(element, attributeName) as? String
    }

    private static func attribute(_ element: AXUIElement, _ attributeName: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attributeName as CFString, &value)
        return result == .success ? value : nil
    }
}

/// Keeps short documents pinned to the top of an NSScrollView instead of
/// vertically centering them inside the clip view.
final class TopAlignedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        let documentFrame = documentView.frame
        guard documentFrame.height <= bounds.height else { return bounds }

        bounds.origin.y = documentView.isFlipped
            ? documentFrame.minY
            : documentFrame.maxY - bounds.height
        return bounds
    }
}

@MainActor
final class AnimatedButton: NSButton {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var pointerInside = false

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        animate(scale: 1.025, shadowOpacity: 0.12, duration: 0.18)
        onHoverChanged?(true)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        animate(scale: 1, shadowOpacity: 0, duration: 0.14)
        onHoverChanged?(false)
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        animate(scale: 0.97, shadowOpacity: 0.04, duration: 0.08)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        animate(scale: pointerInside ? 1.025 : 1, shadowOpacity: pointerInside ? 0.12 : 0, duration: 0.12)
    }

    private func animate(scale: CGFloat, shadowOpacity: Float, duration: TimeInterval) {
        guard let layer else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let targetTransform = CATransform3DMakeScale(reduceMotion ? 1 : scale, reduceMotion ? 1 : scale, 1)
        let targetShadowOpacity: Float = reduceMotion ? 0 : shadowOpacity
        let currentTransform = layer.presentation()?.transform ?? layer.transform
        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = currentTransform
        transformAnimation.toValue = targetTransform
        transformAnimation.duration = reduceMotion ? 0 : duration
        transformAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(transformAnimation, forKey: "displayharbor.button.transform")
        layer.transform = targetTransform

        let shadowAnimation = CABasicAnimation(keyPath: "shadowOpacity")
        shadowAnimation.fromValue = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        shadowAnimation.toValue = targetShadowOpacity
        shadowAnimation.duration = reduceMotion ? 0 : duration
        shadowAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(shadowAnimation, forKey: "displayharbor.button.shadow")
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowRadius = 5
        layer.shadowOpacity = targetShadowOpacity
    }
}

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    private let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }
}

@MainActor
final class PopoverViewController: NSViewController {
    private var snapshot: WindowSnapshot?
    private var snapshots: [WindowSnapshot]
    private let store: RuleStore
    private let hasTargetApplication: Bool
    private let onChange: () -> Void
    private let onOpenManager: () -> Void
    private let onOpenSettings: () -> Void
    private let onClosePopover: () -> Void

    private let statusLabel = NSTextField(labelWithString: "")
    private let displayValue = NSTextField(labelWithString: "")
    private let environmentValue = NSTextField(labelWithString: "")
    private let scenarioValue = NSTextField(labelWithString: "")
    private let sizeValue = NSTextField(labelWithString: "")
    private let layoutValue = NSTextField(labelWithString: "")
    private let ruleValue = NSTextField(labelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let appActionStack = NSStackView()
    private let footerStack = NSStackView()
    private var displayPreview: DisplayArrangementView?
    private var quickHelpPopover: NSPopover?
    private var quickHelpWorkItem: DispatchWorkItem?

    init(
        snapshot: WindowSnapshot?,
        snapshots: [WindowSnapshot],
        store: RuleStore,
        hasTargetApplication: Bool,
        onChange: @escaping () -> Void,
        onOpenManager: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onClosePopover: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.snapshots = snapshots
        self.store = store
        self.hasTargetApplication = hasTargetApplication
        self.onChange = onChange
        self.onOpenManager = onOpenManager
        self.onOpenSettings = onOpenSettings
        self.onClosePopover = onClosePopover
        super.init(nibName: nil, bundle: nil)
    }

    func update(snapshot: WindowSnapshot?, snapshots: [WindowSnapshot]) {
        self.snapshot = snapshot
        self.snapshots = snapshots
        guard isViewLoaded else { return }
        render()
    }

    func refreshUpdateState() {
        guard isViewLoaded else { return }
        render()
    }

    var popoverSize: NSSize {
        let hasExistingRules = snapshot.map { !store.rules(for: $0.bundleID).isEmpty } ?? false
        // The display topology is shown above the app card. Reserve its height
        // here so the card and footer keep their full layout instead of being
        // compressed by the popover's fixed content size.
        let baseHeight = hasExistingRules ? 540 : 520
        return NSSize(width: 360, height: baseHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: popoverSize.height))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let appearanceName: NSAppearance.Name = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            ? .darkAqua
            : .aqua
        root.appearance = NSAppearance(named: appearanceName)
        view = root

        statusLabel.alignment = .left
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .labelColor
        statusLabel.usesSingleLineMode = true
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        [displayValue, scenarioValue, sizeValue, layoutValue, ruleValue].forEach {
            $0.textColor = .labelColor
            $0.font = .systemFont(ofSize: 13)
            $0.usesSingleLineMode = true
            $0.lineBreakMode = .byTruncatingTail
            $0.setContentCompressionResistancePriority(.required, for: .vertical)
            $0.setContentHuggingPriority(.required, for: .vertical)
        }
        environmentValue.textColor = .labelColor
        environmentValue.font = .systemFont(ofSize: 13)
        environmentValue.usesSingleLineMode = true
        environmentValue.lineBreakMode = .byTruncatingTail
        environmentValue.setContentCompressionResistancePriority(.required, for: .vertical)
        environmentValue.setContentHuggingPriority(.required, for: .vertical)
        scenarioValue.textColor = .labelColor
        scenarioValue.font = .systemFont(ofSize: 13)
        scenarioValue.usesSingleLineMode = true
        scenarioValue.lineBreakMode = .byTruncatingTail
        scenarioValue.setContentCompressionResistancePriority(.required, for: .vertical)
        scenarioValue.setContentHuggingPriority(.required, for: .vertical)

        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 12
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor

        notice.font = .systemFont(ofSize: 12)
        notice.textColor = .secondaryLabelColor

        appActionStack.orientation = .horizontal
        appActionStack.spacing = 8
        appActionStack.alignment = .centerY
        appActionStack.distribution = .fillProportionally
        appActionStack.setContentHuggingPriority(.required, for: .vertical)
        appActionStack.setContentCompressionResistancePriority(.required, for: .vertical)

        footerStack.orientation = .horizontal
        footerStack.spacing = 18
        footerStack.alignment = .centerY
        footerStack.distribution = .fill
        footerStack.setContentHuggingPriority(.required, for: .vertical)
        footerStack.setContentCompressionResistancePriority(.required, for: .vertical)

        let cardContainer = NSView()
        let cardDivider = NSBox()
        cardDivider.boxType = .separator
        cardDivider.translatesAutoresizingMaskIntoConstraints = false
        cardDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let displayPreview = DisplayArrangementView(displays: store.currentEnvironment.displays)
        displayPreview.translatesAutoresizingMaskIntoConstraints = false
        self.displayPreview = displayPreview

        let cardBody = NSStackView(views: [detailsView(), cardDivider, notice, appActionStack])
        cardBody.orientation = .vertical
        cardBody.alignment = .width
        cardBody.distribution = .fill
        cardBody.detachesHiddenViews = true
        cardBody.spacing = 12
        cardBody.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(cardBody)
        card.contentView = cardContainer
        NSLayoutConstraint.activate([
            cardBody.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 16),
            cardBody.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -16),
            cardBody.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: 12),
            cardBody.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor, constant: -16)
        ])

        let brandContainer = NSView()
        let brandLabel = NSTextField(labelWithString: "DisplayHarbor")
        brandLabel.alignment = .center
        brandLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        brandLabel.textColor = .secondaryLabelColor
        brandLabel.setAccessibilityLabel("DisplayHarbor")
        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        brandContainer.addSubview(brandLabel)

        let settingsButton = NSButton(
            image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.text("Application management"))!,
            target: self,
            action: #selector(openSettings)
        )
        settingsButton.isBordered = false
        settingsButton.bezelStyle = .texturedRounded
        settingsButton.controlSize = .small
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.toolTip = L10n.text("Application management")
        settingsButton.setAccessibilityLabel(L10n.text("Application management"))
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        brandContainer.addSubview(settingsButton)
        NSLayoutConstraint.activate([
            brandContainer.heightAnchor.constraint(equalToConstant: 28),
            brandLabel.centerXAnchor.constraint(equalTo: brandContainer.centerXAnchor),
            brandLabel.widthAnchor.constraint(equalTo: brandContainer.widthAnchor),
            brandLabel.centerYAnchor.constraint(equalTo: brandContainer.centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: brandContainer.trailingAnchor),
            settingsButton.centerYAnchor.constraint(equalTo: brandContainer.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 24),
            settingsButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        let bodyContent = NSStackView(views: [displayPreview, card])
        bodyContent.orientation = .vertical
        bodyContent.alignment = .width
        bodyContent.distribution = .fill
        bodyContent.spacing = 14
        bodyContent.detachesHiddenViews = true
        bodyContent.setContentHuggingPriority(.required, for: .vertical)
        bodyContent.setContentCompressionResistancePriority(.required, for: .vertical)

        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let content = NSStackView(views: [brandContainer, bodyContent, bottomSpacer, footerStack])
        content.orientation = .vertical
        content.alignment = .width
        content.distribution = .fill
        content.detachesHiddenViews = true
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            brandContainer.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            brandContainer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
            bodyContent.widthAnchor.constraint(equalTo: content.widthAnchor),
            displayPreview.heightAnchor.constraint(equalToConstant: 64),
            card.widthAnchor.constraint(equalTo: bodyContent.widthAnchor),
            card.heightAnchor.constraint(equalToConstant: 320)
        ])

        render()
    }

    private func detailsView() -> NSView {
        let container = NSView()
        let appTitle = NSTextField(labelWithString: snapshot?.appName ?? L10n.text("Not available"))
        appTitle.font = .boldSystemFont(ofSize: 16)
        appTitle.textColor = .labelColor
        appTitle.setContentCompressionResistancePriority(.required, for: .vertical)
        appTitle.setContentHuggingPriority(.required, for: .vertical)

        var identityViews: [NSView] = []
        if let icon = snapshot?.app.icon {
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 28).isActive = true
            iconView.setContentCompressionResistancePriority(.required, for: .vertical)
            iconView.setContentHuggingPriority(.required, for: .vertical)
            identityViews.append(iconView)
        }
        identityViews.append(appTitle)
        let identity = NSStackView(views: identityViews)
        identity.orientation = .vertical
        identity.alignment = .centerX
        identity.spacing = 2
        identity.setContentCompressionResistancePriority(.required, for: .vertical)
        identity.setContentHuggingPriority(.required, for: .vertical)
        identity.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(identity)

        let rows: [(String, NSTextField)] = [
            (L10n.text("Current Display"), displayValue),
            (L10n.text("Current Display Setup"), environmentValue),
            (L10n.text("Current Workspace"), scenarioValue),
            (L10n.text("Current Size"), sizeValue),
            (L10n.text("Layout"), layoutValue),
            (L10n.text("Rules"), ruleValue),
            (L10n.text("Status"), statusLabel)
        ]
        let grid = NSGridView(views: rows.map { [label($0.0), $0.1] })
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).width = 80
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            identity.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            identity.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            grid.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return container
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 11)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setContentHuggingPriority(.required, for: .vertical)
        return field
    }

    private func render() {
        appActionStack.arrangedSubviews.forEach { appActionStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        footerStack.arrangedSubviews.forEach { footerStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        displayPreview?.highlight([])
        notice.textColor = .secondaryLabelColor
        environmentValue.stringValue = store.currentEnvironmentName
        scenarioValue.stringValue = store.currentScenarioName

        guard let snapshot else {
            notice.isHidden = false
            statusLabel.stringValue = L10n.text("Not available")
            statusLabel.textColor = .systemOrange
            displayValue.stringValue = "—"
            sizeValue.stringValue = "—"
            layoutValue.stringValue = "—"
            ruleValue.stringValue = L10n.text("No standard window recognized")
            if hasTargetApplication && !AXIsProcessTrusted() {
                notice.stringValue = L10n.text("Accessibility permission is required for DisplayHarbor to read and move windows.")
                let permissionButton = button(L10n.text("Open Accessibility Settings"), action: #selector(openAccessibility))
                addAppAction(permissionButton, fillsWidth: true)
            } else {
                notice.stringValue = L10n.text("Activate an App with a standard window, then open DisplayHarbor.")
            }
            addManageAction()
            addScenarioActions()
            addQuitAction()
            return
        }

        let existingRules = store.rules(for: snapshot.bundleID)
        displayPreview?.highlight(snapshots.map(makeRule(from:)))
        let unopenedBundleIDs = store.allBundleIDs.filter { !isAppRunning(bundleID: $0) }
        let unopenedAppNames = unopenedBundleIDs.map { bundleID in
            store.rules(for: bundleID).first?.appName ?? bundleID
        }
        let exitApps = store.exitApps(inEnvironment: store.currentEnvironment.key, scenarioID: store.currentScenarioID)
        let stillRunningExitAppNames = exitApps.compactMap { bundleID, appName in
            isAppRunning(bundleID: bundleID) ? appName : nil
        }.sorted()
        let layoutIsCurrent = !existingRules.isEmpty
            && WindowProbe.layoutMatches(snapshots: snapshots, rules: existingRules)
        statusLabel.stringValue = existingRules.isEmpty
            ? L10n.text("Not saved")
            : (layoutIsCurrent ? L10n.text("Saved · matches current") : L10n.text("Saved · current layout changed"))
        statusLabel.textColor = existingRules.isEmpty
            ? .secondaryLabelColor
            : (layoutIsCurrent ? .systemGreen : .systemOrange)
        let displayLabels = Array(Set(snapshots.map { DisplayInfo.label(for: $0.screen) })).sorted()
        displayValue.stringValue = displayLabels.joined(separator: L10n.listSeparator)
        sizeValue.stringValue = snapshots.count > 1
            ? L10n.text("%ld windows · current %@", snapshots.count, "\(Int(snapshot.frame.width)) × \(Int(snapshot.frame.height))")
            : "\(Int(snapshot.frame.width)) × \(Int(snapshot.frame.height))"
        layoutValue.stringValue = snapshots.count > 1
            ? L10n.text("Multi-window layout")
            : layoutPreset(for: snapshot)
        ruleValue.stringValue = existingRules.isEmpty
            ? (store.hasRulesForOtherEnvironment(bundleID: snapshot.bundleID) ? L10n.text("Saved in another display setup") : L10n.text("Not saved yet"))
            : L10n.text("Saved in current display setup: %ld windows", existingRules.count)

        notice.isHidden = true

        if existingRules.isEmpty {
            addAppAction(button(L10n.text("Save"), action: #selector(saveCurrentLayout)), fillsWidth: true)
        } else {
            if !layoutIsCurrent {
                addAppAction(button(L10n.text("Restore %ld windows", existingRules.count), action: #selector(restoreLayout)))
                addAppAction(button(L10n.text("Update current layout"), action: #selector(saveCurrentLayout)))
            }
            let delete = button(L10n.text("Delete rule"), action: #selector(deleteRule))
            delete.bezelStyle = .inline
            delete.contentTintColor = .secondaryLabelColor
            makeTextButton(delete)
            addAppAction(delete)
        }
        addManageAction()
        if !unopenedAppNames.isEmpty || !stillRunningExitAppNames.isEmpty {
            addQuickEnvironmentAction(for: unopenedAppNames, exitAppNames: stillRunningExitAppNames)
        }
        addScenarioActions()
        addQuitAction()
    }

    private func addAppAction(_ button: NSButton, fillsWidth: Bool = false) {
        appActionStack.addArrangedSubview(button)
        if fillsWidth {
            button.widthAnchor.constraint(equalTo: appActionStack.widthAnchor).isActive = true
        }
    }

    private func addQuitAction() {
        if footerStack.arrangedSubviews.count == 1 {
            footerStack.addArrangedSubview(footerSpacer())
        }
        let quit = button(L10n.text("Quit"), action: #selector(quitApp))
        quit.bezelStyle = .inline
        quit.contentTintColor = .secondaryLabelColor
        quit.font = .systemFont(ofSize: 11)
        makeTextButton(quit)
        footerStack.addArrangedSubview(NSView())
        footerStack.addArrangedSubview(quit)
    }

    private func addManageAction() {
        let manage = button(L10n.text("Manage Setups & App Rules"), action: #selector(openManager))
        manage.bezelStyle = .inline
        manage.contentTintColor = .secondaryLabelColor
        manage.font = .systemFont(ofSize: 11)
        makeTextButton(manage)
        footerStack.addArrangedSubview(manage)
    }

    private func addQuickEnvironmentAction(for appNames: [String], exitAppNames: [String]) {
        let quick = button(L10n.text("Apply current workspace"), action: #selector(openAllCurrentEnvironmentApps))
        quick.bezelStyle = .inline
        quick.contentTintColor = .secondaryLabelColor
        quick.font = .systemFont(ofSize: 11)
        let appsToOpen = appNames.isEmpty ? L10n.text("None") : appNames.joined(separator: L10n.listSeparator)
        let appsToExit = exitAppNames.isEmpty ? L10n.text("None") : exitAppNames.joined(separator: L10n.listSeparator)
        let quickHelp = L10n.text(
            "Apply current workspace help",
            appsToOpen,
            appsToExit
        )
        quick.onHoverChanged = { [weak self, weak quick] isHovering in
            self?.updateQuickHelp(isHovering ? quick : nil, text: quickHelp)
        }
        makeTextButton(quick)
        footerStack.addArrangedSubview(quick)
    }

    private func addScenarioActions() {
        guard store.scenarios(for: store.currentEnvironment.key).count > 1 else { return }
        let switchButton = button(L10n.text("Switch workspace"), action: #selector(switchScenario))
        switchButton.bezelStyle = .inline
        switchButton.contentTintColor = .secondaryLabelColor
        switchButton.font = .systemFont(ofSize: 11)
        makeTextButton(switchButton)
        footerStack.addArrangedSubview(switchButton)
    }

    private func footerSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func updateQuickHelp(_ button: NSButton?, text: String? = nil) {
        quickHelpWorkItem?.cancel()
        quickHelpWorkItem = nil
        quickHelpPopover?.performClose(nil)
        quickHelpPopover = nil

        guard let button, let text else { return }
        let workItem = DispatchWorkItem { [weak self, weak button] in
            guard let self, let button, button.window != nil else { return }
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .labelColor
            label.alignment = .left
            label.translatesAutoresizingMaskIntoConstraints = false

            let container = NSView()
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
                label.widthAnchor.constraint(equalToConstant: 196)
            ])
            let contentViewController = NSViewController()
            contentViewController.view = container
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = true
            popover.contentViewController = contentViewController
            popover.contentSize = NSSize(width: 220, height: max(54, label.fittingSize.height + 20))
            self.quickHelpPopover = popover
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
        quickHelpWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func makeTextButton(_ button: NSButton) {
        button.isBordered = false
        button.focusRingType = .none
        button.showsBorderOnlyWhileMouseInside = false
    }

    private func button(_ title: String, action: Selector) -> AnimatedButton {
        let button = AnimatedButton(title: title, target: self, action: action)
        button.wantsLayer = true
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.contentTintColor = .controlTextColor
        return button
    }

    private func preset(for frame: CGRect, on screen: NSScreen) -> String {
        let area = screen.visibleFrame
        let normalized = CGRect(
            x: (frame.minX - area.minX) / area.width,
            y: (frame.minY - area.minY) / area.height,
            width: frame.width / area.width,
            height: frame.height / area.height
        )
        let fullScreen = screen.frame
        if frame.width >= fullScreen.width * 0.99 && frame.height >= fullScreen.height * 0.99 {
            return L10n.text("Full-screen Space")
        }
        if normalized.width > 0.97 && normalized.height > 0.97 { return L10n.text("Window fills work area") }
        if normalized.minX < 0.03 && normalized.minY < 0.03 && normalized.width > 0.97 && normalized.height < 0.55 {
            return L10n.text("Bottom half window")
        }
        return L10n.text("Custom window layout")
    }

    private func layoutPreset(for snapshot: WindowSnapshot) -> String {
        snapshot.isFullScreen == true ? L10n.text("Full-screen Space") : preset(for: snapshot.frame, on: snapshot.screen)
    }

    private func makeRule(from snapshot: WindowSnapshot) -> PlacementRule {
        let area = snapshot.screen.visibleFrame
        let normalized = CGRect(
            x: (snapshot.frame.minX - area.minX) / area.width,
            y: (snapshot.frame.minY - area.minY) / area.height,
            width: snapshot.frame.width / area.width,
            height: snapshot.frame.height / area.height
        )
        return PlacementRule(
            bundleID: snapshot.bundleID,
            appName: snapshot.appName,
            displayID: DisplayInfo.id(for: snapshot.screen),
            displayLabel: DisplayInfo.label(for: snapshot.screen),
            title: snapshot.title,
            windowIndex: snapshot.windowIndex,
            size: snapshot.frame.size,
            normalizedFrame: normalized,
            layoutPreset: layoutPreset(for: snapshot),
            isFullScreen: snapshot.isFullScreen
        )
    }

    @objc private func saveCurrentLayout() {
        guard !snapshots.isEmpty else { return }
        let rules = snapshots.map(makeRule(from:))
        if let snapshot, !store.rules(for: snapshot.bundleID).isEmpty,
           rules.count < store.rules(for: snapshot.bundleID).count {
            notice.isHidden = false
            notice.textColor = .systemOrange
            notice.stringValue = L10n.text("Partial window snapshot could not replace the existing rules. Wait for the windows to settle and try again.")
            return
        }
        guard store.save(rules) else {
            notice.isHidden = false
            notice.textColor = .systemOrange
            notice.stringValue = L10n.text("Save failed: %@", store.lastPersistenceError ?? L10n.text("Unable to write the rules file."))
            return
        }
        onChange()
        render()
        notice.isHidden = false
        notice.textColor = .systemGreen
        notice.stringValue = L10n.text("Layout saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.onClosePopover()
        }
    }

    @objc private func restoreLayout() {
        guard let snapshot else { return }
        let rules = store.rules(for: snapshot.bundleID)
        snapshot.app.activate(options: [.activateAllWindows])
        let restoredCount = WindowProbe.restore(app: snapshot.app, using: rules)
        snapshots = WindowProbe.snapshots(for: snapshot.app)
        self.snapshot = WindowProbe.snapshot(for: snapshot.app) ?? snapshots.first
        render()
        if restoredCount < rules.count {
            notice.isHidden = false
            notice.stringValue = L10n.text("Some windows could not be restored. Check Accessibility permission or wait for the full-screen animation to finish, then try again.")
        }
        onChange()
    }

    private func isAppRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated && $0.isFinishedLaunching
        })
    }

    @objc private func openAllCurrentEnvironmentApps() {
        updateQuickHelp(nil)
        let bundleIDs = store.allBundleIDs
        let exitApps = store.exitApps(inEnvironment: store.currentEnvironment.key, scenarioID: store.currentScenarioID)
        _ = requestExitApps(exitApps)
        guard !bundleIDs.isEmpty else {
            render()
            return
        }

        onClosePopover()
        for (index, bundleID) in bundleIDs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.12) { [self] in
                launchAndRestore(bundleID: bundleID)
            }
        }
    }

    @objc private func switchScenario() {
        let scenarios = store.scenarios(for: store.currentEnvironment.key)
        guard scenarios.count > 1 else { return }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        scenarios.forEach {
            picker.addItem(withTitle: $0.displayName)
            picker.lastItem?.representedObject = $0.id
        }
        if let currentID = store.currentScenarioID,
           let item = picker.itemArray.first(where: { ($0.representedObject as? String) == currentID }) {
            picker.select(item)
        }
        let alert = NSAlert()
        alert.icon = displayHarborIcon()
        alert.messageText = L10n.text("Switch workspace")
        let selectedScenarioID = picker.selectedItem?.representedObject as? String
        let exitApps = store.exitApps(inEnvironment: store.currentEnvironment.key, scenarioID: selectedScenarioID)
        let exitNames = exitApps.values.sorted().joined(separator: L10n.listSeparator)
        alert.informativeText = exitNames.isEmpty
            ? L10n.text("After switching, the next workspace application or matching App launch will use the new layout.")
            : L10n.text("After switching, the next workspace application or matching App launch will use the new layout.\nThis workspace will request exit for: %@", exitNames)
        alert.accessoryView = picker
        alert.addButton(withTitle: L10n.text("Switch"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,
              let scenarioID = picker.selectedItem?.representedObject as? String else { return }
        guard store.selectScenario(environmentKey: store.currentEnvironment.key, scenarioID: scenarioID) else {
            notice.isHidden = false
            notice.stringValue = L10n.text("Switch failed: %@", store.lastPersistenceError ?? L10n.text("Unable to write the rules file."))
            return
        }
        let failedExitNames = requestExitApps(exitApps)
        render()
        if !failedExitNames.isEmpty {
            notice.isHidden = false
            notice.stringValue = L10n.text("Could not request exit for: %@", failedExitNames.joined(separator: L10n.listSeparator))
        }
        onChange()
    }

    private func launchAndRestore(bundleID: String) {
        let rules = store.rules(for: bundleID)
        guard !rules.isEmpty else { return }

        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated && $0.isFinishedLaunching
        }) {
            app.activate(options: [.activateAllWindows])
            _ = WindowProbe.restore(app: app, using: rules)
            return
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            guard let app else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                app.activate(options: [.activateAllWindows])
                _ = WindowProbe.restore(app: app, using: rules)
            }
        }
    }

    @objc private func deleteRule() {
        guard let snapshot else { return }
        guard store.remove(bundleID: snapshot.bundleID) else {
            notice.isHidden = false
            notice.stringValue = L10n.text("Delete failed: %@", store.lastPersistenceError ?? L10n.text("Unable to write the rules file."))
            return
        }
        onChange()
        render()
    }

    @objc private func openAccessibility() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func openManager() {
        onClosePopover()
        let openManager = onOpenManager
        DispatchQueue.main.async {
            openManager()
        }
    }

    @objc private func openSettings() {
        onClosePopover()
        onOpenSettings()
    }
}

@MainActor
final class EnvironmentManagerViewController: NSViewController {
    private let store: RuleStore
    private let onChange: () -> Void
    private let listStack = NSStackView()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var stateRefreshTimer: Timer?
    private var appStateSignature = ""
    private var shouldRevealCurrentEnvironment = true

    init(store: RuleStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(revealCurrentEnvironment: Bool = false) {
        guard isViewLoaded else { return }
        if revealCurrentEnvironment {
            shouldRevealCurrentEnvironment = true
        }
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startWorkspaceObserving()
        stateRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAppStatesIfNeeded()
            }
        }
        render()
    }

    override func viewWillDisappear() {
        stateRefreshTimer?.invalidate()
        stateRefreshTimer = nil
        stopWorkspaceObserving()
        super.viewWillDisappear()
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        root.wantsLayer = true
        let appearanceName: NSAppearance.Name = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            ? .darkAqua
            : .aqua
        root.appearance = NSAppearance(named: appearanceName)
        view = root

        let title = NSTextField(labelWithString: L10n.text("Environment & Rules"))
        title.font = .boldSystemFont(ofSize: 24)
        title.textColor = .labelColor
        title.alignment = .left

        let subtitle = NSTextField(wrappingLabelWithString: L10n.text("DisplayHarbor automatically chooses layouts based on your display setup. View, name, and maintain App rules for each setup here."))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .left

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        header.addSubview(subtitle)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            title.topAnchor.constraint(equalTo: header.topAnchor),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])

        let document = NSView()
        document.setContentHuggingPriority(.defaultLow, for: .horizontal)
        document.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 14
        listStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView = TopAlignedClipView()
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])

        render()
    }

    private func render() {
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let environments = store.storedEnvironments
        appStateSignature = currentAppStateSignature()
        guard !environments.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: L10n.text("No saved display setups yet. Save a layout for the current App from the DisplayHarbor menu bar item to create one."))
            empty.font = .systemFont(ofSize: 14)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            listStack.addArrangedSubview(empty)
            return
        }

        var currentCard: NSView?
        environments.forEach {
            let card = environmentView($0)
            listStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            if $0.key == store.currentEnvironment.key {
                currentCard = card
            }
        }

        guard shouldRevealCurrentEnvironment, let currentCard else { return }
        DispatchQueue.main.async { [weak self, weak currentCard] in
            guard let self, let currentCard else { return }
            self.view.layoutSubtreeIfNeeded()
            _ = currentCard.scrollToVisible(currentCard.bounds)
            self.shouldRevealCurrentEnvironment = false
        }
    }

    private func startWorkspaceObserving() {
        stopWorkspaceObserving()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshAppStatesIfNeeded()
                }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                Task { @MainActor [weak self] in
                    self?.render()
                }
            }
        }
    }

    private func stopWorkspaceObserving() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    private func currentAppStateSignature() -> String {
        store.storedEnvironments
            .flatMap { environment in
                environment.scenarios.values.flatMap { $0.rules.keys }
            }
            .sorted()
            .map { "\($0)=\(isAppRunning(bundleID: $0))" }
            .joined(separator: "|")
    }

    private func refreshAppStatesIfNeeded() {
        let signature = currentAppStateSignature()
        guard signature != appStateSignature else { return }
        render()
    }

    private func environmentView(_ environment: StoredEnvironment) -> NSView {
        let isStored = store.hasStoredEnvironment(environment.key)
        let isCurrent = environment.key == store.currentEnvironment.key
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 14
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor

        let container = NSView()
        box.contentView = container

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        let name = NSTextField(labelWithString: environment.displayName)
        name.font = .boldSystemFont(ofSize: 17)
        name.textColor = .labelColor

        let titleRow = NSView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleRow)
        name.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(name)
        var titleRowConstraints: [NSLayoutConstraint] = [
            name.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            name.topAnchor.constraint(equalTo: titleRow.topAnchor),
            name.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor)
        ]

        if isCurrent {
            let current = NSTextField(labelWithString: L10n.text("In use"))
            current.font = .systemFont(ofSize: 11, weight: .semibold)
            current.textColor = .systemGreen
            current.alignment = .left
            current.translatesAutoresizingMaskIntoConstraints = false
            titleRow.addSubview(current)
            titleRowConstraints.append(contentsOf: [
                current.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 16),
                current.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor)
            ])
        }

        let rename = iconButton(
            title: L10n.text("Rename display setup"),
            symbolName: "pencil",
            action: #selector(renameEnvironment(_:)),
            hoverTint: .controlAccentColor
        )
        rename.identifier = NSUserInterfaceItemIdentifier(environment.key)
        rename.isEnabled = isStored || environment.key == store.currentEnvironment.key
        rename.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(rename)

        let delete = iconButton(
            title: L10n.text("Delete display setup"),
            symbolName: "trash",
            action: #selector(deleteEnvironment(_:)),
            hoverTint: .systemRed
        )
        delete.identifier = NSUserInterfaceItemIdentifier(environment.key)
        let canDeleteEnvironment = isStored && !isCurrent
        delete.isEnabled = canDeleteEnvironment
        delete.setNormalTintColor(canDeleteEnvironment ? .secondaryLabelColor : .tertiaryLabelColor)
        delete.setHoverTintColor(canDeleteEnvironment ? .systemRed : nil)
        if !canDeleteEnvironment {
            delete.toolTip = L10n.text("Current display setup cannot be deleted")
        }
        delete.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(delete)

        titleRowConstraints.append(contentsOf: [
            delete.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            delete.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            rename.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -12),
            rename.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor)
        ])
        NSLayoutConstraint.activate(titleRowConstraints)

        let scenarios = store.scenarios(for: environment.key)
        let selectedScenario = scenarios.first { $0.id == environment.activeScenarioID } ?? scenarios.first
        let selectedScenarioID = selectedScenario?.id ?? ""
        let selectedRules = selectedScenario?.rules ?? [:]
        let selectedExitApps = selectedScenario?.exitApps ?? [:]
        let meta = NSTextField(labelWithString: "\(L10n.text(environment.displays.count == 1 ? "Single-display setup" : "%ld-display setup", environment.displays.count)) · \(L10n.text("%ld workspaces", scenarios.count))")
        meta.font = .systemFont(ofSize: 12)
        meta.textColor = .secondaryLabelColor
        meta.alignment = .left
        meta.translatesAutoresizingMaskIntoConstraints = false

        let displayNames = environment.displays.map { display in
            display.isPrimary ? L10n.text("Main Display · %@", display.name) : display.name
        }.joined(separator: L10n.listSeparator)
        let displays = NSTextField(wrappingLabelWithString: L10n.text("Display: %@", displayNames))
        displays.font = .systemFont(ofSize: 12)
        displays.textColor = .secondaryLabelColor
        displays.alignment = .left
        displays.translatesAutoresizingMaskIntoConstraints = false

        let displayPreview = DisplayArrangementView(displays: environment.displays)
        displayPreview.translatesAutoresizingMaskIntoConstraints = false

        let scenarioHeader = NSView()
        scenarioHeader.translatesAutoresizingMaskIntoConstraints = false
        let scenarioLabel = NSTextField(labelWithString: L10n.text("Workspace"))
        scenarioLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        scenarioLabel.textColor = .secondaryLabelColor
        scenarioLabel.translatesAutoresizingMaskIntoConstraints = false
        scenarioHeader.addSubview(scenarioLabel)
        let scenarioPicker = NSPopUpButton()
        scenarioPicker.controlSize = .small
        scenarioPicker.font = .systemFont(ofSize: 12)
        scenarioPicker.removeAllItems()
        scenarios.forEach { scenario in
            scenarioPicker.addItem(withTitle: scenario.displayName)
            scenarioPicker.lastItem?.representedObject = scenario.id
        }
        if let item = scenarioPicker.itemArray.first(where: { ($0.representedObject as? String) == selectedScenarioID }) {
            scenarioPicker.select(item)
        }
        scenarioPicker.target = self
        scenarioPicker.action = #selector(selectScenario(_:))
        scenarioPicker.identifier = NSUserInterfaceItemIdentifier(environment.key)
        scenarioPicker.isEnabled = isStored
        scenarioPicker.translatesAutoresizingMaskIntoConstraints = false
        scenarioHeader.addSubview(scenarioPicker)

        let newScenario = iconButton(
            title: L10n.text("New workspace"),
            symbolName: "plus",
            action: #selector(createScenario(_:)),
            hoverTint: .controlAccentColor
        )
        newScenario.identifier = NSUserInterfaceItemIdentifier("\(environment.key)\n\(selectedScenarioID)")
        newScenario.isEnabled = isStored
        newScenario.translatesAutoresizingMaskIntoConstraints = false
        scenarioHeader.addSubview(newScenario)
        let renameScenario = iconButton(
            title: L10n.text("Rename workspace"),
            symbolName: "pencil",
            action: #selector(renameScenario(_:)),
            hoverTint: .controlAccentColor
        )
        renameScenario.identifier = NSUserInterfaceItemIdentifier("\(environment.key)\n\(selectedScenarioID)")
        renameScenario.isEnabled = isStored
        renameScenario.translatesAutoresizingMaskIntoConstraints = false
        scenarioHeader.addSubview(renameScenario)
        let deleteScenario = iconButton(
            title: L10n.text("Delete workspace"),
            symbolName: "trash",
            action: #selector(deleteScenario(_:)),
            hoverTint: .systemRed
        )
        let canDeleteScenario = isStored && scenarios.count > 1
        deleteScenario.isEnabled = canDeleteScenario
        deleteScenario.setNormalTintColor(canDeleteScenario ? .secondaryLabelColor : .tertiaryLabelColor)
        deleteScenario.setHoverTintColor(canDeleteScenario ? .systemRed : nil)
        if !canDeleteScenario {
            deleteScenario.toolTip = L10n.text("At least one workspace must remain")
        }
        deleteScenario.identifier = NSUserInterfaceItemIdentifier("\(environment.key)\n\(selectedScenarioID)")
        deleteScenario.translatesAutoresizingMaskIntoConstraints = false
        scenarioHeader.addSubview(deleteScenario)

        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        let rulesTitle = NSTextField(labelWithString: L10n.text("Saved App rules · %@", selectedScenario?.displayName ?? L10n.text("Default")))
        rulesTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        rulesTitle.textColor = .labelColor
        rulesTitle.alignment = .left
        rulesTitle.translatesAutoresizingMaskIntoConstraints = false

        let rulesHeader = NSView()
        rulesHeader.translatesAutoresizingMaskIntoConstraints = false
        rulesHeader.addSubview(rulesTitle)
        let unopenedBundleIDs = selectedRules.keys.filter { !isAppRunning(bundleID: $0) }
        let environmentIsActive = isCurrent
        let openAll: HoverFeedbackButton?
        if environmentIsActive && unopenedBundleIDs.count > 1 {
            let button = HoverFeedbackButton(title: L10n.text("Open all"), target: self, action: #selector(openAllRuleApps(_:)))
            button.controlSize = .small
            button.setNormalTintColor(.secondaryLabelColor)
            button.identifier = NSUserInterfaceItemIdentifier("\(environment.key)\n\(selectedScenarioID)")
            button.translatesAutoresizingMaskIntoConstraints = false
            rulesHeader.addSubview(button)
            openAll = button
        } else {
            openAll = nil
        }

        let rules = NSStackView()
        rules.orientation = .vertical
        rules.alignment = .width
        rules.spacing = 0
        rules.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(meta)
        content.addSubview(displays)
        content.addSubview(displayPreview)
        content.addSubview(scenarioHeader)
        content.addSubview(divider)
        content.addSubview(rulesHeader)
        content.addSubview(rules)

        if selectedRules.isEmpty {
            let empty = NSTextField(labelWithString: L10n.text("No App rules"))
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .left
            empty.translatesAutoresizingMaskIntoConstraints = false
            rules.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: rules.widthAnchor).isActive = true
        } else {
            var ruleViews: [NSView] = []
            selectedRules.keys.sorted().forEach { bundleID in
                guard let placementRules = selectedRules[bundleID],
                      let firstRule = placementRules.first else { return }
                ruleViews.append(ruleView(
                    environmentKey: environment.key,
                    scenarioID: selectedScenarioID,
                    bundleID: bundleID,
                    appName: firstRule.appName,
                    placementRules: placementRules,
                    allowsAppLaunch: environmentIsActive,
                    onHover: { isHovering in
                        displayPreview.highlight(isHovering ? placementRules : [])
                    }
                ))
            }
            ruleViews.enumerated().forEach { index, rule in
                if index > 0 {
                    let divider = NSBox()
                    divider.boxType = .separator
                    divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                    divider.translatesAutoresizingMaskIntoConstraints = false
                    rules.addArrangedSubview(divider)
                    divider.widthAnchor.constraint(equalTo: rules.widthAnchor).isActive = true
                }
                rules.addArrangedSubview(rule)
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.widthAnchor.constraint(equalTo: rules.widthAnchor).isActive = true
            }
        }

        let exitDivider = NSBox()
        exitDivider.boxType = .separator
        exitDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        exitDivider.translatesAutoresizingMaskIntoConstraints = false

        let exitHeader = NSView()
        exitHeader.translatesAutoresizingMaskIntoConstraints = false
        let exitTitle = NSTextField(labelWithString: L10n.text("Exit Apps when entering"))
        exitTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        exitTitle.textColor = .labelColor
        exitTitle.alignment = .left
        exitTitle.translatesAutoresizingMaskIntoConstraints = false
        exitHeader.addSubview(exitTitle)
        let addExitApp = iconButton(
            title: L10n.text("Add App to exit"),
            symbolName: "plus",
            action: #selector(addExitApp(_:)),
            hoverTint: .controlAccentColor
        )
        addExitApp.identifier = NSUserInterfaceItemIdentifier("\(environment.key)\n\(selectedScenarioID)")
        addExitApp.isEnabled = isStored
        addExitApp.translatesAutoresizingMaskIntoConstraints = false
        exitHeader.addSubview(addExitApp)

        let exitApps = NSStackView()
        exitApps.orientation = .vertical
        exitApps.alignment = .width
        exitApps.spacing = 0
        exitApps.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(exitDivider)
        content.addSubview(exitHeader)
        content.addSubview(exitApps)

        if selectedExitApps.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: L10n.text("No Apps will be asked to exit when entering this workspace."))
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .left
            empty.translatesAutoresizingMaskIntoConstraints = false
            exitApps.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: exitApps.widthAnchor).isActive = true
        } else {
            selectedExitApps.keys.sorted { (selectedExitApps[$0] ?? $0).localizedStandardCompare(selectedExitApps[$1] ?? $1) == .orderedAscending }
                .forEach { bundleID in
                    guard let appName = selectedExitApps[bundleID] else { return }
                    exitApps.addArrangedSubview(exitAppView(
                        environmentKey: environment.key,
                        scenarioID: selectedScenarioID,
                        bundleID: bundleID,
                        appName: appName
                    ))
                }
        }

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -16),
            titleRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titleRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            titleRow.topAnchor.constraint(equalTo: content.topAnchor),
            meta.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            meta.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 10),
            displays.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            displays.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            displays.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 6),
            displayPreview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            displayPreview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            displayPreview.topAnchor.constraint(equalTo: displays.bottomAnchor, constant: 10),
            displayPreview.heightAnchor.constraint(equalToConstant: DisplayArrangementView.preferredHeight),
            scenarioHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scenarioHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scenarioHeader.topAnchor.constraint(equalTo: displayPreview.bottomAnchor, constant: 10),
            scenarioHeader.heightAnchor.constraint(equalToConstant: 24),
            scenarioLabel.leadingAnchor.constraint(equalTo: scenarioHeader.leadingAnchor),
            scenarioLabel.centerYAnchor.constraint(equalTo: scenarioHeader.centerYAnchor),
            scenarioPicker.leadingAnchor.constraint(equalTo: scenarioLabel.trailingAnchor, constant: 10),
            scenarioPicker.centerYAnchor.constraint(equalTo: scenarioHeader.centerYAnchor),
            newScenario.leadingAnchor.constraint(equalTo: scenarioPicker.trailingAnchor, constant: 10),
            newScenario.centerYAnchor.constraint(equalTo: scenarioHeader.centerYAnchor),
            renameScenario.leadingAnchor.constraint(equalTo: newScenario.trailingAnchor, constant: 10),
            renameScenario.centerYAnchor.constraint(equalTo: scenarioHeader.centerYAnchor),
            deleteScenario.leadingAnchor.constraint(equalTo: renameScenario.trailingAnchor, constant: 10),
            deleteScenario.centerYAnchor.constraint(equalTo: scenarioHeader.centerYAnchor),
            deleteScenario.trailingAnchor.constraint(lessThanOrEqualTo: scenarioHeader.trailingAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: scenarioHeader.bottomAnchor, constant: 10),
            rulesHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rulesHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rulesHeader.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            rulesTitle.leadingAnchor.constraint(equalTo: rulesHeader.leadingAnchor),
            rulesTitle.topAnchor.constraint(equalTo: rulesHeader.topAnchor),
            rulesTitle.bottomAnchor.constraint(equalTo: rulesHeader.bottomAnchor),
            rules.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rules.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rules.topAnchor.constraint(equalTo: rulesHeader.bottomAnchor, constant: 6),
            rules.bottomAnchor.constraint(equalTo: exitDivider.topAnchor, constant: -14),
            exitDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            exitDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            exitHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            exitHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            exitHeader.topAnchor.constraint(equalTo: exitDivider.bottomAnchor, constant: 10),
            exitHeader.heightAnchor.constraint(equalToConstant: 24),
            exitTitle.leadingAnchor.constraint(equalTo: exitHeader.leadingAnchor),
            exitTitle.centerYAnchor.constraint(equalTo: exitHeader.centerYAnchor),
            addExitApp.trailingAnchor.constraint(equalTo: exitHeader.trailingAnchor),
            addExitApp.centerYAnchor.constraint(equalTo: exitHeader.centerYAnchor),
            exitTitle.trailingAnchor.constraint(lessThanOrEqualTo: addExitApp.leadingAnchor, constant: -12),
            exitApps.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            exitApps.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            exitApps.topAnchor.constraint(equalTo: exitHeader.bottomAnchor, constant: 6),
            exitApps.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        if let openAll {
            NSLayoutConstraint.activate([
                rulesTitle.trailingAnchor.constraint(lessThanOrEqualTo: openAll.leadingAnchor, constant: -12),
                openAll.trailingAnchor.constraint(equalTo: rulesHeader.trailingAnchor),
                openAll.centerYAnchor.constraint(equalTo: rulesHeader.centerYAnchor)
            ])
        } else {
            rulesTitle.trailingAnchor.constraint(equalTo: rulesHeader.trailingAnchor).isActive = true
        }
        return box
    }

    private func iconButton(
        title: String,
        symbolName: String,
        action: Selector,
        hoverTint: NSColor
    ) -> HoverFeedbackButton {
        let button = HoverFeedbackButton(title: "", target: self, action: action)
        button.controlSize = .small
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: title
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        button.imagePosition = .imageOnly
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setNormalTintColor(.secondaryLabelColor)
        button.setHoverTintColor(hoverTint)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func ruleView(
        environmentKey: String,
        scenarioID: String,
        bundleID: String,
        appName: String,
        placementRules: [PlacementRule],
        allowsAppLaunch: Bool,
        onHover: @escaping (Bool) -> Void
    ) -> NSView {
        let title = NSTextField(labelWithString: appName)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .left

        let displayNames = Array(Set(placementRules.map { store.displayLabel(for: $0, inEnvironment: environmentKey) })).sorted().joined(separator: L10n.listSeparator)
        let fullScreenCount = placementRules.filter { $0.isFullScreen == true }.count
        let appIsOpen = isAppRunning(bundleID: bundleID)
        var detailParts = [L10n.text("%ld windows", placementRules.count), displayNames]
        if !appIsOpen {
            detailParts.append(L10n.text("Unopened"))
        }
        if fullScreenCount > 0 {
            detailParts.append(fullScreenCount == placementRules.count ? L10n.text("Dedicated Space") : L10n.text("Includes Dedicated Space"))
        }
        let detailViews = detailParts.enumerated().reduce(into: [NSView]()) { views, item in
            let (index, part) = item
            let field = NSTextField(labelWithString: part)
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.alignment = .left
            if index > 0 {
                let separator = RuleDetailSeparatorView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    separator.widthAnchor.constraint(equalToConstant: 1),
                    separator.heightAnchor.constraint(equalToConstant: 11)
                ])
                views.append(separator)
            }
            views.append(field)
        }
        let detail = NSStackView(views: detailViews)
        detail.orientation = .horizontal
        detail.alignment = .centerY
        detail.spacing = 8

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4

        let open: HoverFeedbackButton?
        if allowsAppLaunch && !appIsOpen {
            let button = HoverFeedbackButton(title: L10n.text("Open App"), target: self, action: #selector(openRuleApp(_:)))
            button.controlSize = .small
            button.setNormalTintColor(.secondaryLabelColor)
            button.identifier = NSUserInterfaceItemIdentifier("\(environmentKey)\n\(scenarioID)\n\(bundleID)")
            open = button
        } else {
            open = nil
        }

        let delete = HoverFeedbackButton(title: L10n.text("Delete rule"), target: self, action: #selector(deleteRule(_:)))
        delete.controlSize = .small
        delete.setNormalTintColor(.secondaryLabelColor)
        delete.identifier = NSUserInterfaceItemIdentifier("\(environmentKey)\n\(scenarioID)\n\(bundleID)")

        let row = HoverableRuleRow()
        row.onHover = onHover
        labels.translatesAutoresizingMaskIntoConstraints = false
        delete.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        row.addSubview(delete)
        if let open {
            open.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(open)
        }
        if let image = ApplicationIcon.image(for: bundleID) {
            let icon = NSImageView(image: image)
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 28),
                icon.heightAnchor.constraint(equalToConstant: 28),
                labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10)
            ])
            if !appIsOpen {
                icon.wantsLayer = true
                if let filter = CIFilter(name: "CIColorControls") {
                    filter.setValue(0, forKey: kCIInputSaturationKey)
                    filter.setValue(-0.04, forKey: kCIInputBrightnessKey)
                    filter.setValue(0.9, forKey: kCIInputContrastKey)
                    icon.layer?.filters = [filter]
                }
            }
        } else {
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            labels.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            delete.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            delete.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])
        if let open {
            NSLayoutConstraint.activate([
                labels.trailingAnchor.constraint(lessThanOrEqualTo: open.leadingAnchor, constant: -24),
                open.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -12),
                open.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
        } else {
            labels.trailingAnchor.constraint(lessThanOrEqualTo: delete.leadingAnchor, constant: -24).isActive = true
        }
        return row
    }

    private func exitAppView(
        environmentKey: String,
        scenarioID: String,
        bundleID: String,
        appName: String
    ) -> NSView {
        let title = NSTextField(labelWithString: appName)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .left
        let detail = NSTextField(labelWithString: L10n.text("Request exit when entering this workspace"))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .left
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4

        let remove = HoverFeedbackButton(title: L10n.text("Remove"), target: self, action: #selector(removeExitApp(_:)))
        remove.controlSize = .small
        remove.setNormalTintColor(.secondaryLabelColor)
        remove.identifier = NSUserInterfaceItemIdentifier("\(environmentKey)\n\(scenarioID)\n\(bundleID)")

        let row = HoverableRuleRow()
        labels.translatesAutoresizingMaskIntoConstraints = false
        remove.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        row.addSubview(remove)
        if let image = ApplicationIcon.image(for: bundleID) {
            let icon = NSImageView(image: image)
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 28),
                icon.heightAnchor.constraint(equalToConstant: 28),
                labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10)
            ])
        } else {
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            labels.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -24),
            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func isAppRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated && $0.isFinishedLaunching
        })
    }

    @objc private func openRuleApp(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 3 else { return }
        activateRule(bundleID: parts[2], environmentKey: parts[0], scenarioID: parts[1])
    }

    @objc private func addExitApp(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "").split(separator: "\n").map(String.init)
        guard parts.count == 2,
              let environment = store.storedEnvironments.first(where: { $0.key == parts[0] }),
              let scenario = environment.scenarios[parts[1]] else { return }

        let panel = NSOpenPanel()
        panel.title = L10n.text("Add Apps to exit")
        panel.prompt = L10n.text("Add")
        panel.message = L10n.text("Choose the Apps that should receive a normal quit request when entering this workspace.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK else { return }
            var apps: [String: String] = [:]
            for url in panel.urls {
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier else { continue }
                let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                guard scenario.rules[bundleID] == nil,
                      scenario.exitApps[bundleID] == nil else { continue }
                apps[bundleID] = appName
            }
            guard !apps.isEmpty else {
                self.showExitAppError(L10n.text("Choose an App without an existing layout or exit rule."))
                return
            }
            guard self.store.addExitApps(apps, inEnvironment: parts[0], scenarioID: parts[1]) else {
                self.showPersistenceError()
                return
            }
            self.render()
            self.onChange()
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(panel.runModal())
        }
    }

    @objc private func removeExitApp(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "").split(separator: "\n").map(String.init)
        guard parts.count == 3,
              let environment = store.storedEnvironments.first(where: { $0.key == parts[0] }),
              let appName = environment.scenarios[parts[1]]?.exitApps[parts[2]] else { return }

        let alert = NSAlert()
        alert.icon = displayHarborIcon()
        alert.messageText = L10n.text("Remove %@?", appName)
        alert.informativeText = L10n.text("DisplayHarbor will no longer request this App to exit when entering the workspace.")
        alert.addButton(withTitle: L10n.text("Remove"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.alertStyle = .warning
        presentAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.store.removeExitApp(bundleID: parts[2], fromEnvironment: parts[0], scenarioID: parts[1]) else {
                self.showPersistenceError()
                return
            }
            self.render()
            self.onChange()
        }
    }

    private func showExitAppError(_ message: String) {
        let alert = NSAlert()
        alert.icon = displayHarborIcon()
        alert.messageText = L10n.text("Unable to add exit App")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("OK"))
        presentAlert(alert) { _ in }
    }

    private func activateRule(bundleID: String, environmentKey: String, scenarioID: String? = nil) {
        guard let environment = store.storedEnvironments.first(where: { $0.key == environmentKey }),
              let targetScenarioID = scenarioID ?? environment.activeScenarioID,
              let rules = environment.scenarios[targetScenarioID]?.rules[bundleID],
              !rules.isEmpty else { return }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated && $0.isFinishedLaunching
        }) {
            app.activate(options: [.activateAllWindows])
            _ = WindowProbe.restore(app: app, using: rules)
            refresh()
            return
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            guard let app else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                app.activate(options: [.activateAllWindows])
                _ = WindowProbe.restore(app: app, using: rules)
            }
        }
    }

    @objc private func openAllRuleApps(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "").split(separator: "\n").map(String.init)
        guard parts.count == 2 else { return }
        let environmentKey = parts[0]
        let scenarioID = parts[1]
        guard let environment = store.storedEnvironments.first(where: { $0.key == environmentKey }) else { return }
        guard let scenario = environment.scenarios[scenarioID] else { return }
        let unopenedBundleIDs = scenario.rules.keys.filter { !isAppRunning(bundleID: $0) }
        for (index, bundleID) in unopenedBundleIDs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.12) { [weak self] in
                self?.activateRule(bundleID: bundleID, environmentKey: environmentKey, scenarioID: scenarioID)
            }
        }
    }

    @objc private func renameEnvironment(_ sender: NSButton) {
        let key = sender.identifier?.rawValue ?? ""
        guard let environment = store.storedEnvironments.first(where: { $0.key == key }) else { return }

        let field = NSTextField(string: environment.customName ?? environment.label)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.icon = displayHarborIcon()
        alert.messageText = L10n.text("Rename display setup")
        alert.informativeText = L10n.text("Give this display setup an easy-to-recognize name.")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("Save"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.window.initialFirstResponder = field
        presentAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.store.renameEnvironment(key: key, to: field.stringValue) else {
                self.showPersistenceError()
                return
            }
            self.render()
            self.onChange()
        }
    }

    @objc private func deleteEnvironment(_ sender: NSButton) {
        let key = sender.identifier?.rawValue ?? ""
        guard let environment = store.storedEnvironments.first(where: { $0.key == key }) else { return }
        guard environment.key != store.currentEnvironment.key else { return }

        let alert = NSAlert()
        alert.icon = displayHarborIcon()
        alert.messageText = L10n.text("Delete %@?", environment.displayName)
        alert.informativeText = L10n.text("This deletes all App rules saved for this display setup. This cannot be undone.")
        alert.addButton(withTitle: L10n.text("Delete"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.alertStyle = .warning
        presentAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.store.removeEnvironment(key: key) else {
                self.showPersistenceError()
                return
            }
            self.render()
            self.onChange()
        }
    }

    @objc private func deleteRule(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "").components(separatedBy: "\n")
        guard parts.count == 3 else { return }
        let environmentKey = parts[0]
        let scenarioID = parts[1]
        let bundleID = parts[2]
        guard let environment = store.storedEnvironments.first(where: { $0.key == environmentKey }),
              let rules = environment.scenarios[scenarioID]?.rules[bundleID],
              let appName = rules.first?.appName else { return }

        let alert = NSAlert()
        alert.icon = displayHarborIcon()
        alert.messageText = L10n.text("Delete %@ rule?", appName)
        alert.informativeText = L10n.text("Only its layout in the %@ display setup will be deleted.", environment.displayName)
        alert.addButton(withTitle: L10n.text("Delete"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.alertStyle = .warning
        presentAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.store.removeRule(bundleID: bundleID, fromEnvironment: environmentKey, scenarioID: scenarioID) else {
                self.showPersistenceError()
                return
            }
            self.render()
            self.onChange()
        }
    }

    @objc private func selectScenario(_ sender: NSPopUpButton) {
        let environmentKey = sender.identifier?.rawValue ?? ""
        guard let scenarioID = sender.selectedItem?.representedObject as? String else { return }
        guard store.selectScenario(environmentKey: environmentKey, scenarioID: scenarioID) else {
            showPersistenceError()
            return
        }
        let failedExitNames: [String]
        if environmentKey == store.currentEnvironment.key {
            failedExitNames = requestExitApps(store.exitApps(inEnvironment: environmentKey, scenarioID: scenarioID))
        } else {
            failedExitNames = []
        }
        render()
        if !failedExitNames.isEmpty {
            showExitFailure(failedExitNames)
        }
        onChange()
    }

    @objc private func createScenario(_ sender: NSButton) {
        guard requireLicensedWorkspaceFeature() else { return }
        let parts = (sender.identifier?.rawValue ?? "").split(separator: "\n").map(String.init)
        guard parts.count == 2,
              let environment = store.storedEnvironments.first(where: { $0.key == parts[0] }),
              let source = environment.scenarios[parts[1]] else { return }
        let field = NSTextField(string: "\(source.displayName) \(L10n.text("Copy suffix"))")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.icon = displayHarborIcon()
        alert.messageText = L10n.text("New workspace")
        alert.informativeText = L10n.text("Copy the current App rules from %@.", source.displayName)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("Create"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.window.initialFirstResponder = field
        presentAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.store.createScenario(environmentKey: parts[0], name: field.stringValue, forkFrom: source.id) != nil else {
                self.showPersistenceError()
                return
            }
            self.render()
            self.onChange()
        }
    }

    @objc private func renameScenario(_ sender: NSButton) {
        guard requireLicensedWorkspaceFeature() else { return }
        let parts = (sender.identifier?.rawValue ?? "").split(separator: "\n").map(String.init)
        guard parts.count == 2,
              let environment = store.storedEnvironments.first(where: { $0.key == parts[0] }),
              let scenario = environment.scenarios[parts[1]] else { return }
        let field = NSTextField(string: scenario.displayName)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.icon = displayHarborIcon()
        alert.messageText = L10n.text("Rename workspace")
        alert.informativeText = L10n.text("Give this workspace an easy-to-recognize name.")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("Save"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.window.initialFirstResponder = field
        presentAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.store.renameScenario(environmentKey: parts[0], scenarioID: parts[1], to: field.stringValue) else {
                self.showPersistenceError()
                return
            }
            self.render()
            self.onChange()
        }
    }

    @objc private func deleteScenario(_ sender: NSButton) {
        guard requireLicensedWorkspaceFeature() else { return }
        let parts = (sender.identifier?.rawValue ?? "").split(separator: "\n").map(String.init)
        guard parts.count == 2,
              let environment = store.storedEnvironments.first(where: { $0.key == parts[0] }),
              let scenario = environment.scenarios[parts[1]],
              environment.scenarios.count > 1 else { return }

        let alert = NSAlert()
        alert.icon = displayHarborIcon()
        alert.messageText = L10n.text("Delete %@?", scenario.displayName)
        alert.informativeText = L10n.text("This deletes all App rules saved for this workspace. This cannot be undone.")
        alert.addButton(withTitle: L10n.text("Delete"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.alertStyle = .warning
        presentAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.store.removeScenario(environmentKey: parts[0], scenarioID: parts[1]) else {
                self.showPersistenceError()
                return
            }
            self.render()
            self.onChange()
        }
    }

    private func showPersistenceError() {
        let alert = NSAlert()
        alert.icon = displayHarborIcon()
        alert.messageText = L10n.text("Save failed")
        alert.informativeText = store.lastPersistenceError ?? L10n.text("Unable to write the rules file.")
        alert.addButton(withTitle: L10n.text("OK"))
        presentAlert(alert) { _ in }
    }

    private func requireLicensedWorkspaceFeature() -> Bool {
        guard LicenseManager.shared.isLicensed else {
            let alert = NSAlert()
            alert.icon = displayHarborIcon()
            alert.messageText = L10n.text("License required")
            alert.informativeText = L10n.text("Named workspaces require an activated DisplayHarbor license.")
            alert.addButton(withTitle: L10n.text("Open License Settings"))
            alert.addButton(withTitle: L10n.text("Cancel"))
            presentAlert(alert) { response in
                if response == .alertFirstButtonReturn {
                    NotificationCenter.default.post(name: .displayHarborOpenLicenseSettings, object: nil)
                }
            }
            return false
        }
        return true
    }

    private func showExitFailure(_ appNames: [String]) {
        let alert = NSAlert()
        alert.icon = displayHarborIcon()
        alert.messageText = L10n.text("Some Apps did not exit")
        alert.informativeText = L10n.text("DisplayHarbor could not request exit for: %@", appNames.joined(separator: L10n.listSeparator))
        alert.addButton(withTitle: L10n.text("OK"))
        presentAlert(alert) { _ in }
    }

    private func presentAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = view.window else {
            completion(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}

@MainActor
final class EnvironmentManagerWindowController: NSWindowController {
    init(store: RuleStore, onChange: @escaping () -> Void) {
        let contentViewController = EnvironmentManagerViewController(store: store, onChange: onChange)
        let window = NSWindow(contentViewController: contentViewController)
        window.title = L10n.text("DisplayHarbor · Environment & Rules")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class AppSettingsViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let languageTitleLabel = NSTextField(labelWithString: "")
    private let updateTitleLabel = NSTextField(labelWithString: "")
    private let checkButton = NSButton()
    private let versionTitleLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton()
    private let licenseTitleLabel = NSTextField(labelWithString: "")
    private let licenseStatusLabel = NSTextField(labelWithString: "")
    private let licenseDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let credentialField = NSTextField()
    private let verifyLicenseButton = NSButton()
    private let bindingField = NSTextField()
    private let copyBindingButton = NSButton()
    private let purchaseButton = NSButton()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 470))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .labelColor

        languageTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        languageTitleLabel.textColor = .labelColor

        updateTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        updateTitleLabel.textColor = .labelColor

        checkButton.target = self
        checkButton.action = #selector(checkForUpdates)
        checkButton.bezelStyle = .rounded
        checkButton.controlSize = .regular

        versionTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        versionTitleLabel.textColor = .labelColor
        versionLabel.stringValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor

        licenseTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        licenseTitleLabel.textColor = .labelColor
        licenseStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        licenseDetailLabel.font = .systemFont(ofSize: 12)
        licenseDetailLabel.textColor = .secondaryLabelColor
        licenseDetailLabel.maximumNumberOfLines = 0
        credentialField.font = .systemFont(ofSize: 12)
        credentialField.placeholderString = "eyJhbGciOiJFZERTQSIs…"
        verifyLicenseButton.target = self
        verifyLicenseButton.action = #selector(verifyLicense)
        verifyLicenseButton.bezelStyle = .rounded
        copyBindingButton.target = self
        copyBindingButton.action = #selector(copyBindingCode)
        copyBindingButton.bezelStyle = .rounded
        purchaseButton.target = self
        purchaseButton.action = #selector(openPurchasePage)
        purchaseButton.bezelStyle = .rounded
        bindingField.isEditable = false
        bindingField.isSelectable = true
        bindingField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        languagePopup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let languageRow = NSStackView(views: [languageTitleLabel, languagePopup])
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 12

        let updateRow = NSStackView(views: [updateTitleLabel, checkButton])
        updateRow.orientation = .horizontal
        updateRow.alignment = .firstBaseline
        updateRow.spacing = 10
        updateTitleLabel.setContentHuggingPriority(.required, for: .horizontal)
        updateTitleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let versionRow = NSStackView(views: [versionTitleLabel, versionLabel])
        versionRow.orientation = .horizontal
        versionRow.alignment = .firstBaseline
        versionRow.spacing = 10
        versionTitleLabel.setContentHuggingPriority(.required, for: .horizontal)
        versionTitleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let licenseHeader = NSStackView(views: [licenseTitleLabel, licenseStatusLabel])
        licenseHeader.orientation = .horizontal
        licenseHeader.alignment = .firstBaseline
        licenseHeader.spacing = 12
        let activationRow = NSStackView(views: [credentialField, verifyLicenseButton])
        activationRow.orientation = .horizontal
        activationRow.alignment = .centerY
        activationRow.spacing = 8
        credentialField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        credentialField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bindingRow = NSStackView(views: [bindingField, copyBindingButton])
        bindingRow.orientation = .horizontal
        bindingRow.alignment = .centerY
        bindingRow.spacing = 8
        bindingField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bindingField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let licenseContent = NSStackView(views: [licenseHeader, licenseDetailLabel, activationRow, bindingRow, purchaseButton])
        licenseContent.orientation = .vertical
        licenseContent.alignment = .leading
        licenseContent.spacing = 8

        let content = NSStackView(views: [titleLabel, languageRow, updateRow, versionRow, licenseContent])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -28),
            updateRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            checkButton.widthAnchor.constraint(equalToConstant: 112),
            licenseContent.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            activationRow.trailingAnchor.constraint(equalTo: licenseContent.trailingAnchor),
            bindingRow.trailingAnchor.constraint(equalTo: licenseContent.trailingAnchor),
            credentialField.heightAnchor.constraint(equalToConstant: 26),
            bindingField.heightAnchor.constraint(equalToConstant: 24)
        ])
        view = root
        LicenseManager.shared.onChange = { [weak self] in self?.refreshLicenseUI() }
        refreshLocalizedText()
    }

    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkForUpdates()
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let preference: L10n.LanguagePreference
        switch sender.indexOfSelectedItem {
        case 1:
            preference = .chinese
        case 2:
            preference = .english
        default:
            preference = .system
        }
        L10n.setLanguagePreference(preference)
        refreshLocalizedText()
    }

    @objc private func verifyLicense() {
        verifyLicenseButton.isEnabled = false
        LicenseManager.shared.importLicense(credentialField.stringValue)
        refreshLicenseUI()
    }

    @objc private func copyBindingCode() {
        guard !bindingField.stringValue.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bindingField.stringValue, forType: .string)
    }

    @objc private func openPurchasePage() {
        guard let url = LicenseManager.shared.configuration.purchaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshLocalizedText() {
        titleLabel.stringValue = L10n.text("Application management")
        languageTitleLabel.stringValue = L10n.text("Language")
        updateTitleLabel.stringValue = L10n.text("Updates")
        checkButton.title = L10n.text("Check for updates")
        versionTitleLabel.stringValue = L10n.text("Version")
        licenseTitleLabel.stringValue = L10n.text("License")
        verifyLicenseButton.title = L10n.text("Verify license")
        copyBindingButton.title = L10n.text("Copy binding code")
        purchaseButton.title = L10n.text("Buy a license")
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: [
            L10n.text("Follow System"),
            L10n.text("简体中文"),
            L10n.text("English")
        ])
        languagePopup.selectItem(at: languagePopupIndex())
        view.window?.title = L10n.text("Application management")
        refreshLicenseUI()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        LicenseManager.shared.restore()
        refreshLicenseUI()
    }

    private func refreshLicenseUI() {
        let manager = LicenseManager.shared
        licenseStatusLabel.stringValue = manager.displayName
        credentialField.stringValue = manager.savedLicenseCredential()
        bindingField.stringValue = (try? manager.installationBindingCode()) ?? ""
        switch manager.status {
        case .licensed:
            let expiry = manager.expiryText.map { L10n.text("Expires %@", $0) } ?? L10n.text("No expiry")
            licenseDetailLabel.stringValue = L10n.text("This installation is activated. %@", expiry)
        case .notConfigured:
            licenseDetailLabel.stringValue = L10n.text("The license product is not configured in this build.")
        case .unlicensed:
            licenseDetailLabel.stringValue = L10n.text("Paste the license credential received after purchase, then verify it locally.")
        case .expired:
            licenseDetailLabel.stringValue = L10n.text("This license has expired. Please purchase or activate another license.")
        case .error(let message):
            licenseDetailLabel.stringValue = message
        }
        let canActivate = manager.configuration.isConfigured
        credentialField.isEnabled = canActivate
        verifyLicenseButton.isEnabled = canActivate
        copyBindingButton.isEnabled = canActivate && !bindingField.stringValue.isEmpty
        purchaseButton.isHidden = manager.configuration.purchaseURL == nil
    }

    private func languagePopupIndex() -> Int {
        switch L10n.languagePreference {
        case .system:
            return 0
        case .chinese:
            return 1
        case .english:
            return 2
        }
    }
}

@MainActor
final class AppSettingsWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentViewController: AppSettingsViewController())
        window.title = L10n.text("Application management")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 470))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: RuleStore!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var environmentWindowController: EnvironmentManagerWindowController?
    private var settingsWindowController: AppSettingsWindowController?
    private var lastExternalApplication: NSRunningApplication?
    private var environmentChangeWorkItem: DispatchWorkItem?
    private var statusResetWorkItem: DispatchWorkItem?
    private var accessibilityRefreshTimer: Timer?
    private var didPromptForAccessibilityThisLaunch = false
    private var popoverApplication: NSRunningApplication?
    private var restoreGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = displayHarborIcon()
        _ = UpdateChecker.shared
        LicenseManager.shared.restore()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openLicenseSettingsNotification),
            name: .displayHarborOpenLicenseSettings,
            object: nil
        )
        store = RuleStore(currentEnvironment: DisplayInfo.currentEnvironment())
        observeApplications()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        setStatusItemState(.normal)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 400)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            stopAccessibilityRefresh()
            popover.performClose(sender)
            return
        }

        let app = externalApplication()
        popoverApplication = app
        let snapshots = app.map { WindowProbe.snapshots(for: $0) } ?? []
        let snapshot = app.flatMap { WindowProbe.snapshot(for: $0) } ?? snapshots.first
        let controller = PopoverViewController(
            snapshot: snapshot,
            snapshots: snapshots,
            store: store,
            hasTargetApplication: app != nil,
            onChange: { [weak self] in
                self?.refreshStatusItem()
            },
            onOpenManager: { [weak self] in
                self?.openEnvironmentManager()
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onClosePopover: { [weak self] in
                self?.closePopover()
            }
        )
        popover.contentViewController = controller
        popover.contentSize = controller.popoverSize
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: statusItem.button?.bounds ?? .zero, of: statusItem.button ?? NSView(), preferredEdge: .minY)
        focusPopover()

        guard app != nil, !AXIsProcessTrusted() else { return }
        startAccessibilityRefresh()
        guard !didPromptForAccessibilityThisLaunch else { return }
        didPromptForAccessibilityThisLaunch = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.popover.isShown, !AXIsProcessTrusted() else { return }
            self.openAccessibilitySettings()
        }
    }

    private func externalApplication() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let candidate = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastExternalApplication : frontmost
        guard let candidate, !WindowProbe.isDesktopOnlyFinder(candidate) else { return nil }
        return candidate
    }

    private func startAccessibilityRefresh() {
        stopAccessibilityRefresh()
        accessibilityRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                guard self.popover.isShown else {
                    self.accessibilityRefreshTimer?.invalidate()
                    self.accessibilityRefreshTimer = nil
                    return
                }
                guard AXIsProcessTrusted() else { return }
                self.accessibilityRefreshTimer?.invalidate()
                self.accessibilityRefreshTimer = nil
                self.refreshPopoverAfterAccessibilityGranted()
            }
        }
    }

    private func stopAccessibilityRefresh() {
        accessibilityRefreshTimer?.invalidate()
        accessibilityRefreshTimer = nil
    }

    private func refreshPopoverAfterAccessibilityGranted() {
        guard let controller = popover.contentViewController as? PopoverViewController,
              let app = popoverApplication ?? externalApplication() else { return }
        let snapshots = WindowProbe.snapshots(for: app)
        controller.update(snapshot: WindowProbe.snapshot(for: app) ?? snapshots.first, snapshots: snapshots)
        popover.contentSize = controller.popoverSize
    }

    private func focusPopover() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.popover.contentViewController?.view.window else { return }
            window.makeKeyAndOrderFront(nil)
            if let contentView = self.popover.contentViewController?.view {
                window.makeFirstResponder(contentView)
            }
        }
    }

    private func openEnvironmentManager() {
        applyCurrentEnvironment()
        NSApp.activate(ignoringOtherApps: true)

        let controller: EnvironmentManagerWindowController
        if let controller = environmentWindowController {
            (controller.contentViewController as? EnvironmentManagerViewController)?.refresh(revealCurrentEnvironment: true)
            controller.showWindow(nil)
            self.bringManagerWindowToFront(controller)
        } else {
            controller = EnvironmentManagerWindowController(store: store) { [weak self] in
                self?.refreshStatusItem()
            }
            environmentWindowController = controller
            controller.showWindow(nil)
            bringManagerWindowToFront(controller)
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let controller = settingsWindowController {
            controller.showWindow(nil)
            bringSettingsWindowToFront(controller)
            return
        }
        let controller = AppSettingsWindowController()
        settingsWindowController = controller
        controller.showWindow(nil)
        bringSettingsWindowToFront(controller)
    }

    @objc private func openLicenseSettingsNotification() {
        openSettings()
    }

    private func bringSettingsWindowToFront(_ controller: AppSettingsWindowController) {
        guard let window = controller.window else { return }
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    private func bringManagerWindowToFront(_ controller: EnvironmentManagerWindowController) {
        guard let window = controller.window else { return }
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    private func closePopover() {
        if popover.isShown {
            stopAccessibilityRefresh()
            popover.performClose(nil)
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func observeApplications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApplication = app
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              !store.rules(for: bundleID).isEmpty else { return }
        restoreAfterLaunch(app: app, rules: store.rules(for: bundleID), attempt: 0)
    }

    private func restoreAfterLaunch(
        app: NSRunningApplication,
        rules: [PlacementRule],
        attempt: Int,
        preserveStatus: Bool = false,
        generation: Int? = nil
    ) {
        let generation = generation ?? restoreGeneration
        guard attempt < 8 else {
            if preserveStatus {
            setStatusItemState(.warning)
            } else {
                refreshStatusItem(warning: true)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.8 : 0.5)) { [weak self] in
            guard let self else { return }
            guard generation == self.restoreGeneration, !app.isTerminated else {
                if !app.isTerminated { self.refreshStatusItem() }
                return
            }
            if attempt == 0 {
                app.activate(options: [.activateAllWindows])
            }
            let restoredCount = WindowProbe.restore(app: app, using: rules)
            if restoredCount >= rules.count {
                if !preserveStatus {
                    self.refreshStatusItem()
                }
            } else {
                self.restoreAfterLaunch(
                    app: app,
                    rules: rules,
                    attempt: attempt + 1,
                    preserveStatus: preserveStatus,
                    generation: generation
                )
            }
        }
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        environmentChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.applyCurrentEnvironment()
        }
        environmentChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private func applyCurrentEnvironment() {
        let environmentChanged = store.updateEnvironment(DisplayInfo.currentEnvironment())
        guard environmentChanged else { return }
        restoreGeneration += 1

        let bundleIDs = store.allBundleIDs
        guard !bundleIDs.isEmpty else {
            refreshStatusItem()
            return
        }

        statusResetWorkItem?.cancel()
        setStatusItemState(.restoring)
        let reset = DispatchWorkItem { [weak self] in
            self?.refreshStatusItem()
        }
        statusResetWorkItem = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: reset)

        for bundleID in bundleIDs {
            let rules = store.rules(for: bundleID)
            guard rules.contains(where: { DisplayInfo.screen(withID: $0.displayID) != nil }) else { continue }
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID {
                restoreAfterLaunch(app: app, rules: rules, attempt: 0, preserveStatus: true)
            }
        }
    }

    private func refreshStatusItem(warning: Bool = false) {
        setStatusItemState(warning ? .warning : .normal)
    }

    private enum StatusItemState {
        case normal
        case restoring
        case warning
    }

    private func setStatusItemState(_ state: StatusItemState) {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        let help: String
        switch state {
        case .normal:
            symbolName = "rectangle.3.group.fill"
            help = "DisplayHarbor"
        case .restoring:
            symbolName = "arrow.triangle.2.circlepath"
            help = L10n.text("DisplayHarbor: restoring window layouts")
        case .warning:
            symbolName = "exclamationmark.triangle.fill"
            help = L10n.text("DisplayHarbor: window restoration needs attention")
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "DisplayHarbor")
        image?.isTemplate = true
        button.image = image
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = help
        button.setAccessibilityLabel("DisplayHarbor")
        button.setAccessibilityHelp(help)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
