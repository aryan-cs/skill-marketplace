import AppKit
import ApplicationServices
import CryptoKit
import Foundation

private let chromeBundleID = "com.google.Chrome"
private let identityProviderField = "Identity Provider"
private let deadlineSeconds: TimeInterval = 20 * 60
private let pollSeconds: TimeInterval = 0.75
private let maximumElements = 8_000
private let maximumDepth = 24
private let webAreaRole = "AXWebArea"
private let secureTextFieldRole = "AXSecureTextField"
private let menuItemRole = "AXMenuItem"
private let maximumActionAttempts = 3
private let actionRetryDelay: TimeInterval = 5

private enum AuthRole: String, CaseIterable {
    case identityProvider = "identity_provider"
    case institution
    case microsoft
    case mfa
}

private struct RuntimeConfig {
    let origin: URL
    let username: String
    let microsoftAccount: String
    let identityProviderLabel: String
    let browserUserDataDirectory: String
    let workbenchService: String
    let serverKey: String
    let profile: String
    let image: String
    let resource: String
    let environmentLabel: String
    let resourceLabel: String
    let remoteRoot: String
    let authDomains: [AuthRole: [String]]

    var originHost: String { origin.host!.lowercased() }

    var spawnPath: String {
        serverKey.isEmpty ? "/hub/spawn" : "/hub/spawn/\(username)/\(serverKey)"
    }

    var userWorkbenchPath: String {
        let server = serverKey.isEmpty ? "" : "/\(serverKey)"
        return "/user/\(username)\(server)/\(workbenchService)"
    }

    var hubWorkbenchPath: String { "/hub\(userWorkbenchPath)" }

    func host(_ host: String, has role: AuthRole) -> Bool {
        authDomains[role, default: []].contains { domainMatches(host, domain: $0) }
    }

    func isAllowedAuthHost(_ host: String) -> Bool {
        AuthRole.allCases.contains { self.host(host, has: $0) }
    }

    static func load() throws -> RuntimeConfig {
        let environment = ProcessInfo.processInfo.environment
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else {
                throw ControllerError.configuration("missing required launcher variable \(name)")
            }
            return value
        }

        let originString = try required("ICRN_ORIGIN")
        guard let origin = URL(string: originString),
              origin.scheme?.lowercased() == "https",
              origin.host != nil,
              origin.user == nil,
              origin.password == nil,
              origin.query == nil,
              origin.fragment == nil else {
            throw ControllerError.configuration("ICRN_ORIGIN is not a valid HTTPS origin")
        }

        let authJSON = try required("ICRN_ALLOWED_AUTH_DOMAINS_JSON")
        guard let data = authJSON.data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == Set(AuthRole.allCases.map(\.rawValue)) else {
            throw ControllerError.configuration("ICRN_ALLOWED_AUTH_DOMAINS_JSON is invalid")
        }
        var authDomains: [AuthRole: [String]] = [:]
        for role in AuthRole.allCases {
            guard let domains = raw[role.rawValue] as? [String],
                  (role == .mfa || !domains.isEmpty),
                  domains.allSatisfy({ !$0.isEmpty && $0 == $0.lowercased() }) else {
                throw ControllerError.configuration("auth-domain role \(role.rawValue) is invalid")
            }
            authDomains[role] = domains
        }

        let remoteRoot = try required("ICRN_REMOTE_ROOT")
        guard remoteRoot.hasPrefix("/") else {
            throw ControllerError.configuration("ICRN_REMOTE_ROOT must be absolute")
        }
        return RuntimeConfig(
            origin: origin,
            username: try required("ICRN_USERNAME"),
            microsoftAccount: try required("ICRN_MICROSOFT_ACCOUNT"),
            identityProviderLabel: try required("ICRN_IDENTITY_PROVIDER_LABEL"),
            browserUserDataDirectory: try required("ICRN_BROWSER_USER_DATA_DIRECTORY"),
            workbenchService: try required("ICRN_WORKBENCH_SERVICE"),
            serverKey: environment["ICRN_SERVER_KEY"] ?? "",
            profile: try required("ICRN_PROFILE"),
            image: try required("ICRN_IMAGE"),
            resource: try required("ICRN_RESOURCE"),
            environmentLabel: try required("ICRN_ENVIRONMENT_LABEL"),
            resourceLabel: try required("ICRN_RESOURCE_LABEL"),
            remoteRoot: remoteRoot,
            authDomains: authDomains
        )
    }
}

private let config: RuntimeConfig = {
    do {
        return try RuntimeConfig.load()
    } catch {
        fputs("ICRN controller: \(error)\n", stderr)
        exit(2)
    }
}()

private enum Mode {
    case run
    case observe
}

private enum RunCompletion {
    case ready
    case windowClosed
}

private enum CleanupResult {
    case noMatch
    case closed
    case ambiguous(Int)
    case closeFailed
}

private struct ActionAttempt {
    let count: Int
    let attemptedAt: Date
}

private struct Node {
    let element: AXUIElement
    let role: String
    let title: String
    let value: String
    let description: String
    let help: String
    let url: URL?
    let enabled: Bool
    let selected: Bool?

    var strings: [String] {
        [title, value, description, help].filter { !$0.isEmpty }
    }
}

private struct BrowserSnapshot {
    let application: AXUIElement
    let window: AXUIElement
    let webArea: AXUIElement
    let nodes: [Node]
    let pageURL: URL?

    var normalizedText: Set<String> {
        Set(nodes.flatMap(\.strings).map(normalize))
    }

    func containsText(_ text: String) -> Bool {
        let wanted = normalize(text)
        return normalizedText.contains(wanted)
    }

    func containsFragment(_ fragment: String) -> Bool {
        let wanted = normalize(fragment)
        return normalizedText.contains { $0.contains(wanted) }
    }
}

private struct OwnedChromeWindow {
    let application: AXUIElement
    let window: AXUIElement
}

private struct OwnedFlow {
    let chrome: OwnedChromeWindow
    let snapshot: BrowserSnapshot
}

private enum ControllerError: Error, CustomStringConvertible {
    case configuration(String)
    case accessibilityUnavailable
    case chromeUnavailable
    case targetWindowUnavailable
    case windowClosed
    case ambiguousTargetWindows(Int)
    case ambiguousControl(String, Int)
    case actionFailed(String, AXError)
    case launchFailed(String)
    case serverFailed
    case retriesExhausted(String)
    case timedOut(String)
    case windowCloseFailed

    var description: String {
        switch self {
        case .configuration(let message):
            return "Invalid ICRN configuration: \(message)."
        case .accessibilityUnavailable:
            return "Accessibility access is required. In System Settings, open Privacy & Security > Accessibility, enable your terminal, then rerun this script."
        case .chromeUnavailable:
            return "Google Chrome is not running."
        case .targetWindowUnavailable:
            return "The ICRN tab is not visible to Accessibility yet."
        case .windowClosed:
            return "The launcher-owned Chrome window was closed."
        case .ambiguousTargetWindows(let count):
            return "Refusing to automate because \(count) browser windows look like the ICRN flow."
        case .ambiguousControl(let label, let count):
            return "Refusing to press ambiguous control \"\(label)\" (\(count) matches)."
        case .actionFailed(let label, let error):
            return "Could not press \"\(label)\" (AX error \(error.rawValue))."
        case .launchFailed(let message):
            return "Could not launch Chrome: \(message)"
        case .serverFailed:
            return "ICRN reported that the server failed to start."
        case .retriesExhausted(let label):
            return "\"\(label)\" stayed visible after \(maximumActionAttempts) attempts."
        case .timedOut(let state):
            return "Timed out while waiting at: \(state)."
        case .windowCloseFailed:
            return "The configured instance is ready, but the launcher-owned Chrome window could not be closed."
        }
    }
}

private func normalize(_ value: String) -> String {
    value
        .lowercased()
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
}

private func copiedAttribute(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else {
        return nil
    }
    return result
}

private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String {
    if let string = copiedAttribute(element, attribute) as? String {
        return string
    }
    if let attributed = copiedAttribute(element, attribute) as? NSAttributedString {
        return attributed.string
    }
    return ""
}

private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    guard let value = copiedAttribute(element, attribute) else { return nil }
    if let boolean = value as? Bool { return boolean }
    if let number = value as? NSNumber { return number.boolValue }
    return nil
}

private func isProtectedValueElement(_ element: AXUIElement) -> Bool {
    stringAttribute(element, kAXRoleAttribute as CFString) == secureTextFieldRole
        || stringAttribute(element, kAXSubroleAttribute as CFString) == secureTextFieldRole
}

private func safeStringValue(_ element: AXUIElement) -> String {
    guard !isProtectedValueElement(element) else { return "" }
    return stringAttribute(element, kAXValueAttribute as CFString)
}

private func safeBooleanValue(_ element: AXUIElement) -> Bool? {
    guard !isProtectedValueElement(element) else { return nil }
    return boolAttribute(element, kAXValueAttribute as CFString)
}

private func elementsAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
    copiedAttribute(element, attribute) as? [AXUIElement] ?? []
}

private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    guard let value = copiedAttribute(element, attribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func urlAttribute(_ element: AXUIElement) -> URL? {
    guard let value = copiedAttribute(element, kAXURLAttribute as CFString) else { return nil }
    if let url = value as? URL { return url }
    if let string = value as? String { return URL(string: string) }
    return nil
}

private func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

private func node(for element: AXUIElement) -> Node {
    let role = stringAttribute(element, kAXRoleAttribute as CFString)
    return Node(
        element: element,
        role: role,
        title: stringAttribute(element, kAXTitleAttribute as CFString),
        value: safeStringValue(element),
        description: stringAttribute(element, kAXDescriptionAttribute as CFString),
        help: stringAttribute(element, kAXHelpAttribute as CFString),
        url: urlAttribute(element),
        enabled: boolAttribute(element, kAXEnabledAttribute as CFString) ?? true,
        selected: boolAttribute(element, kAXSelectedAttribute as CFString)
    )
}

private func descendants(of root: AXUIElement) -> [Node] {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    var result: [Node] = []

    while index < queue.count && result.count < maximumElements {
        let (element, depth) = queue[index]
        index += 1
        result.append(node(for: element))
        guard depth < maximumDepth else { continue }

        let children = elementsAttribute(element, kAXChildrenAttribute as CFString)
        for child in children.prefix(maximumElements - result.count) {
            queue.append((child, depth + 1))
        }
    }
    return result
}

private func allowedFlowHost(_ url: URL?) -> Bool {
    guard let host = url?.host?.lowercased() else { return false }
    return host == config.originHost || config.isAllowedAuthHost(host)
}

private func domainMatches(_ host: String, domain: String) -> Bool {
    host == domain
}

private func pageEvidenceIsRelevant(url: URL?, normalized: Set<String>) -> Bool {
    guard let url, let host = url.host?.lowercased() else { return false }
    let has = { (fragment: String) in normalized.contains { $0.contains(fragment) } }

    if has("duo security") || has("check for a duo push") || has("approve this login") {
        return true
    }

    if host == config.originHost {
        let path = url.path
        return path.hasPrefix("/hub/login")
            || path.hasPrefix("/hub/home")
            || path.hasPrefix("/hub/spawn")
            || workbenchPathMatches(path)
            || has("research notebooks")
            || has("sign in with cilogon")
            || has("launch server")
            || has(config.environmentLabel.lowercased())
            || has(config.resourceLabel.lowercased())
    }
    if config.host(host, has: .identityProvider) {
        return has("cilogon") || has("identity provider") || has(config.identityProviderLabel.lowercased())
    }
    if config.host(host, has: .microsoft) {
        return has(config.microsoftAccount.lowercased())
            || has("pick an account")
            || has("enter password")
            || has("stay signed in")
    }
    if config.host(host, has: .mfa) {
        return has("duo") || has("approve") || has("push")
    }
    if config.host(host, has: .institution) {
        return has(config.microsoftAccount.lowercased()) || has("sign in")
    }
    return false
}

private func workbenchPathMatches(_ path: String) -> Bool {
    let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    return trimmed == config.userWorkbenchPath || trimmed == config.hubWorkbenchPath
}

private func fancyConfiguration(in value: String) -> [String: Any]? {
    guard let marker = value.range(of: "#fancy-forms-config=") else { return nil }
    let encoded = String(value[marker.upperBound...])
    let decoded = encoded.removingPercentEncoding ?? encoded
    guard let data = decoded.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let configuration = object as? [String: Any] else {
        return nil
    }
    return configuration
}

private func fancyConfigurationIsExpected(_ value: String) -> Bool {
    guard let selected = fancyConfiguration(in: value) else { return false }
    let expectedKeys = Set([
        "profile",
        "image",
        "image:unlisted_choice",
        "resource",
        "resource:unlisted_choice"
    ])
    return Set(selected.keys) == expectedKeys
        && selected["profile"] as? String == config.profile
        && selected["image"] as? String == config.image
        && selected["resource"] as? String == config.resource
        && selected["image:unlisted_choice"] as? String == ""
        && selected["resource:unlisted_choice"] as? String == ""
}

private func spawnNextIsExpected(_ value: String) -> Bool {
    guard let marker = value.range(of: "#fancy-forms-config=") else { return false }
    return String(value[..<marker.lowerBound]) == config.spawnPath
        && fancyConfigurationIsExpected(value)
}

private func userNextIsExpected(_ value: String) -> Bool {
    guard let components = URLComponents(string: value),
          workbenchPathMatches(components.path) else {
        return false
    }
    let items = components.queryItems ?? []
    guard items.count == 2 else { return false }
    return items.filter { $0.name == "folder" }.compactMap(\.value) == [config.remoteRoot]
        && items.filter { $0.name == "redirects" }.compactMap(\.value) == ["2"]
}

private func isTopLevelWebArea(_ element: AXUIElement, in window: AXUIElement) -> Bool {
    var current = elementAttribute(element, kAXParentAttribute as CFString)
    for _ in 0..<maximumDepth {
        guard let candidate = current else { return true }
        if CFEqual(candidate, window) { return true }
        if stringAttribute(candidate, kAXRoleAttribute as CFString) == webAreaRole {
            return false
        }
        current = elementAttribute(candidate, kAXParentAttribute as CFString)
    }
    return false
}

private func isConfiguredLaunchOrigin(_ url: URL?) -> Bool {
    guard let url, url.host?.lowercased() == config.originHost else { return false }
    if url.path == "/hub/login",
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
        let nextValues = components.queryItems?
            .filter { $0.name == "next" }
            .compactMap(\.value) ?? []
        return nextValues.count == 2
            && nextValues.contains(where: userNextIsExpected)
            && nextValues.contains(where: spawnNextIsExpected)
    }
    if url.path == config.spawnPath {
        return fancyConfigurationIsExpected(url.absoluteString)
    }
    return workbenchPathMatches(url.path)
}

private func snapshots(
    application appElement: AXUIElement,
    window: AXUIElement,
    originOnly: Bool
) -> [BrowserSnapshot] {
    let windowNodes = descendants(of: window)
    let webAreas = windowNodes
        .filter { $0.role == webAreaRole }
        .map(\.element)
        .filter { isTopLevelWebArea($0, in: window) }

    var candidates: [BrowserSnapshot] = []
    for webArea in webAreas {
        let nodes = descendants(of: webArea)
        let url = urlAttribute(webArea)
        let normalized = Set(nodes.flatMap(\.strings).map(normalize))
        let hasNestedDuo = nodes.contains { node in
            guard let host = node.url?.host?.lowercased() else { return false }
            return config.host(host, has: .mfa)
        }
        guard allowedFlowHost(url),
              pageEvidenceIsRelevant(url: url, normalized: normalized) || hasNestedDuo else {
            continue
        }
        let candidate = BrowserSnapshot(
            application: appElement,
            window: window,
            webArea: webArea,
            nodes: nodes,
            pageURL: url
        )
        guard !originOnly
                || isConfiguredLaunchOrigin(url)
                || configuredSpawnAttested(candidate) else {
            continue
        }
        candidates.append(candidate)
    }
    return candidates
}

private func chromeWindows() -> [AXUIElement] {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID)
        .filter { !$0.isTerminated }

    var windows: [AXUIElement] = []
    for application in running {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        windows.append(contentsOf: elementsAttribute(
            appElement,
            kAXWindowsAttribute as CFString
        ))
    }
    return windows
}

private func newChromeWindows(excluding excludedWindows: [AXUIElement]) throws -> [OwnedChromeWindow] {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID)
        .filter { !$0.isTerminated }
    guard !running.isEmpty else { throw ControllerError.chromeUnavailable }

    var result: [OwnedChromeWindow] = []
    for application in running {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        for window in elementsAttribute(appElement, kAXWindowsAttribute as CFString)
            where !excludedWindows.contains(where: { CFEqual($0, window) }) {
            result.append(OwnedChromeWindow(application: appElement, window: window))
        }
    }
    return result
}

private func originSnapshots(excluding excludedWindows: [AXUIElement] = []) throws -> [BrowserSnapshot] {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID)
        .filter { !$0.isTerminated }
    guard !running.isEmpty else { throw ControllerError.chromeUnavailable }

    var candidates: [BrowserSnapshot] = []
    for application in running {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        for window in elementsAttribute(appElement, kAXWindowsAttribute as CFString) {
            guard !excludedWindows.contains(where: { CFEqual($0, window) }) else { continue }
            candidates.append(contentsOf: snapshots(
                application: appElement,
                window: window,
                originOnly: true
            ))
        }
    }
    return candidates
}

private func launchChrome() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let executable = environment["OPEN_ICRN_CHROME"],
          let profile = environment["OPEN_ICRN_PROFILE"],
          let userDataDirectory = environment["OPEN_ICRN_USER_DATA_DIR"],
          let targetURL = environment["OPEN_ICRN_URL"] else {
        throw ControllerError.launchFailed("launcher environment is incomplete")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [
        "--user-data-dir=\(userDataDirectory)",
        "--profile-directory=\(profile)",
        "--new-window",
        targetURL
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw ControllerError.launchFailed("the configured browser could not be started")
    }
}

private func originSnapshot(excluding excludedWindows: [AXUIElement] = []) throws -> BrowserSnapshot {
    let candidates = try originSnapshots(excluding: excludedWindows)
    guard !candidates.isEmpty else { throw ControllerError.targetWindowUnavailable }
    guard candidates.count == 1 else {
        throw ControllerError.ambiguousTargetWindows(candidates.count)
    }
    return candidates[0]
}

private func snapshot(boundTo prior: BrowserSnapshot) throws -> BrowserSnapshot {
    let candidates = snapshots(
        application: prior.application,
        window: prior.window,
        originOnly: false
    )
    guard !candidates.isEmpty else { throw ControllerError.targetWindowUnavailable }
    guard candidates.count == 1 else {
        throw ControllerError.ambiguousTargetWindows(candidates.count)
    }
    return candidates[0]
}

private func windowWasClosed(application: AXUIElement, window: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        application,
        kAXWindowsAttribute as CFString,
        &value
    ) == .success,
    let windows = value as? [AXUIElement] else {
        return false
    }
    return !windows.contains { CFEqual($0, window) }
}

private func ownedWindowWasClosed(_ snapshot: BrowserSnapshot) -> Bool {
    windowWasClosed(application: snapshot.application, window: snapshot.window)
}

private func matchingNewFlows(excluding excludedWindows: [AXUIElement]) throws -> [OwnedFlow] {
    var matches: [OwnedFlow] = []
    for owned in try newChromeWindows(excluding: excludedWindows) {
        let candidates = snapshots(
            application: owned.application,
            window: owned.window,
            originOnly: false
        )
        guard candidates.count <= 1 else {
            throw ControllerError.ambiguousTargetWindows(candidates.count)
        }
        if let snapshot = candidates.first {
            matches.append(OwnedFlow(chrome: owned, snapshot: snapshot))
        }
    }
    return matches
}

private func waitForOwnedFlow(excluding excludedWindows: [AXUIElement]) throws -> OwnedFlow {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        do {
            let candidates = try matchingNewFlows(excluding: excludedWindows)
            if candidates.count == 1 { return candidates[0] }
            if candidates.count > 1 {
                throw ControllerError.ambiguousTargetWindows(candidates.count)
            }
        } catch ControllerError.chromeUnavailable {
            // Chrome may not have registered the new process/window yet.
        }
        Thread.sleep(forTimeInterval: pollSeconds)
    }
    throw ControllerError.targetWindowUnavailable
}

@discardableResult
private func closeWindow(_ window: AXUIElement) -> Bool {
    guard let closeButton = elementAttribute(window, kAXCloseButtonAttribute as CFString) else {
        return false
    }
    return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
}

private func closeSoleNewFlowWindow(excluding excludedWindows: [AXUIElement]) -> CleanupResult {
    let matches: [OwnedFlow]
    do {
        matches = try matchingNewFlows(excluding: excludedWindows)
    } catch {
        return .noMatch
    }
    guard !matches.isEmpty else { return .noMatch }
    guard matches.count == 1 else { return .ambiguous(matches.count) }
    return closeWindow(matches[0].chrome.window) ? .closed : .closeFailed
}

private func reportCleanup(_ result: CleanupResult) {
    switch result {
    case .noMatch:
        fputs("ICRN controller: warning: no launcher-owned window could be proven for cleanup.\n", stderr)
    case .closed:
        break
    case .ambiguous(let count):
        fputs(
            "ICRN controller: warning: cleanup left \(count) ambiguous new Chrome windows open.\n",
            stderr
        )
    case .closeFailed:
        fputs("ICRN controller: warning: the sole matching new window could not be closed.\n", stderr)
    }
}

private func exactLabelMatches(_ node: Node, _ label: String) -> Bool {
    let wanted = normalize(label)
    return node.strings.contains { normalize($0) == wanted }
}

private func pressableAncestor(of element: AXUIElement, boundedBy webArea: AXUIElement) -> AXUIElement? {
    var current: AXUIElement? = element
    for _ in 0..<8 {
        guard let candidate = current else { return nil }
        if actionNames(candidate).contains(kAXPressAction as String) {
            return candidate
        }
        if CFEqual(candidate, webArea) { return nil }
        current = elementAttribute(candidate, kAXParentAttribute as CFString)
    }
    return nil
}

private func uniquePressable(
    in snapshot: BrowserSnapshot,
    label: String,
    safeLabel: String? = nil
) throws -> AXUIElement? {
    var matches: [AXUIElement] = []
    for candidate in snapshot.nodes where candidate.enabled && exactLabelMatches(candidate, label) {
        guard let pressable = pressableAncestor(of: candidate.element, boundedBy: snapshot.webArea) else {
            continue
        }
        guard boolAttribute(pressable, kAXEnabledAttribute as CFString) ?? true else {
            continue
        }
        if !matches.contains(where: { CFEqual($0, pressable) }) {
            matches.append(pressable)
        }
    }
    guard matches.count <= 1 else {
        throw ControllerError.ambiguousControl(safeLabel ?? label, matches.count)
    }
    return matches.first
}

private func press(_ element: AXUIElement, label: String) throws {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { throw ControllerError.actionFailed(label, result) }
}

private func selectedChoice(in snapshot: BrowserSnapshot, label: String) -> Bool {
    let wanted = normalize(label)
    for candidate in snapshot.nodes where candidate.strings.contains(where: { normalize($0) == wanted }) {
        var current: AXUIElement? = candidate.element
        for _ in 0..<6 {
            guard let element = current else { break }
            if boolAttribute(element, kAXSelectedAttribute as CFString) == true { return true }
            if let value = safeBooleanValue(element), value { return true }
            if stringAttribute(element, kAXRoleAttribute as CFString) == (kAXPopUpButtonRole as String)
                && normalize(safeStringValue(element)) == wanted {
                return true
            }
            if CFEqual(element, snapshot.webArea) { break }
            current = elementAttribute(element, kAXParentAttribute as CFString)
        }
    }
    return false
}

private func popupButton(
    in snapshot: BrowserSnapshot,
    field: String,
    fallbackIndex: Int,
    expectedPopupCount: Int = 2
) throws -> AXUIElement? {
    let popups = snapshot.nodes.filter { $0.role == (kAXPopUpButtonRole as String) }
    let wanted = normalize(field)
    let labeled = popups.filter { popup in
        if popup.strings.contains(where: { normalize($0).contains(wanted) }) {
            return true
        }
        guard let titleElement = elementAttribute(
            popup.element,
            "AXTitleUIElement" as CFString
        ) else {
            return false
        }
        return node(for: titleElement).strings.contains { normalize($0).contains(wanted) }
    }
    guard labeled.count <= 1 else {
        throw ControllerError.ambiguousControl(field, labeled.count)
    }
    if let popup = labeled.first { return popup.element }
    guard popups.count == expectedPopupCount, popups.indices.contains(fallbackIndex) else {
        return nil
    }
    return popups[fallbackIndex].element
}

private func choosePopupOption(
    in snapshot: BrowserSnapshot,
    field: String,
    fallbackIndex: Int,
    expectedPopupCount: Int = 2,
    choice: String,
    safeChoiceLabel: String
) throws -> Bool {
    guard let popup = try popupButton(
        in: snapshot,
        field: field,
        fallbackIndex: fallbackIndex,
        expectedPopupCount: expectedPopupCount
    ) else {
        return false
    }
    if normalize(safeStringValue(popup)) == normalize(choice) {
        return true
    }

    var settable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(
        popup,
        kAXValueAttribute as CFString,
        &settable
    ) == .success, settable.boolValue {
        let result = AXUIElementSetAttributeValue(
            popup,
            kAXValueAttribute as CFString,
            choice as CFString
        )
        if result == .success { return true }
    }

    let openResult = AXUIElementPerformAction(popup, kAXPressAction as CFString)
    guard openResult == .success else {
        throw ControllerError.actionFailed(field, openResult)
    }

    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let searchRoots = [popup, snapshot.application]
        var matches: [AXUIElement] = []
        for root in searchRoots {
            for candidate in descendants(of: root)
                where candidate.role == menuItemRole && exactLabelMatches(candidate, choice) {
                if !matches.contains(where: { CFEqual($0, candidate.element) }) {
                    matches.append(candidate.element)
                }
            }
        }
        guard matches.count <= 1 else {
            throw ControllerError.ambiguousControl(safeChoiceLabel, matches.count)
        }
        if let item = matches.first {
            let actions = actionNames(item)
            let action = actions.contains(kAXPressAction as String)
                ? kAXPressAction as CFString
                : "AXPick" as CFString
            let result = AXUIElementPerformAction(item, action)
            guard result == .success else {
                throw ControllerError.actionFailed(safeChoiceLabel, result)
            }
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw ControllerError.timedOut("configured option was not exposed by \(field)")
}

private func isDuo(_ snapshot: BrowserSnapshot) -> Bool {
    let host = snapshot.pageURL?.host?.lowercased() ?? ""
    return config.host(host, has: .mfa)
        || snapshot.nodes.contains { node in
            guard let nestedHost = node.url?.host?.lowercased() else { return false }
            return config.host(nestedHost, has: .mfa)
        }
        || snapshot.containsFragment("duo security")
        || snapshot.containsFragment("check for a duo push")
        || snapshot.containsFragment("approve this login")
}

private func isVSCodeReady(_ snapshot: BrowserSnapshot) -> Bool {
    guard let url = snapshot.pageURL,
          url.host?.lowercased() == config.originHost,
          workbenchPathMatches(url.path) else {
        return false
    }
    let hasTitle = snapshot.containsFragment("visual studio code")
        || snapshot.containsFragment("code - oss")
        || snapshot.containsFragment("code-server")
    let landmarks = [
        "explorer",
        "search",
        "source control",
        "run and debug",
        "extensions",
        "accounts",
        "manage"
    ].filter { snapshot.containsFragment($0) }
    return hasTitle && landmarks.count >= 2
}

private func configuredSpawnAttested(_ snapshot: BrowserSnapshot) -> Bool {
    guard let url = snapshot.pageURL, url.path == config.spawnPath else { return false }
    if fancyConfigurationIsExpected(url.absoluteString) {
        return true
    }
    if selectedChoice(in: snapshot, label: config.environmentLabel)
        && selectedChoice(in: snapshot, label: config.resourceLabel) {
        return true
    }

    return false
}

private func hostSummary(_ snapshot: BrowserSnapshot) -> String {
    guard let url = snapshot.pageURL,
          let host = url.host?.lowercased() else {
        return "unknown"
    }
    if host == config.originHost {
        if workbenchPathMatches(url.path) { return "workbench" }
        if url.path == config.spawnPath || url.path.hasPrefix("/hub/spawn-pending") {
            return "spawn"
        }
        if url.path.hasPrefix("/hub/login") { return "hub-login" }
        return "hub"
    }
    if config.host(host, has: .identityProvider) { return "identity-provider" }
    if config.host(host, has: .microsoft) { return "microsoft" }
    if config.host(host, has: .institution) { return "institution" }
    if config.host(host, has: .mfa) { return "mfa" }
    return "unknown"
}

private func actionLedgerKey(_ action: String, snapshot: BrowserSnapshot) -> String {
    let exactURL = snapshot.pageURL?.absoluteString ?? "missing-url"
    let digest = SHA256.hash(data: Data(exactURL.utf8))
        .prefix(16)
        .map { String(format: "%02x", $0) }
        .joined()
    return "\(action):\(hostSummary(snapshot)):\(digest)"
}

private func observe() throws {
    let current = try originSnapshot()
    let knownLabels = [
        ("Sign in with CILogon", "Sign in with CILogon"),
        (config.identityProviderLabel, "configured identity provider"),
        (config.microsoftAccount, "configured Microsoft account"),
        ("Sign in", "Sign in"),
        ("No", "No"),
        ("Launch Server", "Launch Server"),
        ("Start", "Start")
    ].compactMap { actual, safe in current.containsText(actual) ? safe : nil }
    print("ICRN observation")
    print("page: \(hostSummary(current))")
    print("vscode_ready: \(isVSCodeReady(current))")
    print("duo_wait: \(isDuo(current))")
    print("known_controls: \(knownLabels.isEmpty ? "none" : knownLabels.joined(separator: ", "))")
}

private func run(initial: BrowserSnapshot) throws -> RunCompletion {
    let start = Date()
    var lastStatus = ""
    var completedSelections = Set<String>()
    var actionAttempts: [String: ActionAttempt] = [:]
    var duoMessagePrinted = false
    var confirmedMicrosoftAccount = false
    var bound = initial
    var pendingSelection: (label: String, safeLabel: String, deadline: Date)?
    var unattestedSpawnSince: Date?

    while Date().timeIntervalSince(start) < deadlineSeconds {
        let current: BrowserSnapshot
        do {
            current = try snapshot(boundTo: bound)
        } catch ControllerError.targetWindowUnavailable {
            if ownedWindowWasClosed(bound) {
                print("The owned Chrome window was closed; exiting.")
                return .windowClosed
            }
            Thread.sleep(forTimeInterval: pollSeconds)
            continue
        } catch ControllerError.chromeUnavailable {
            if ownedWindowWasClosed(bound) {
                print("The owned Chrome window was closed; exiting.")
                return .windowClosed
            }
            Thread.sleep(forTimeInterval: pollSeconds)
            continue
        }
        bound = current

        if let pending = pendingSelection {
            if selectedChoice(in: current, label: pending.label) {
                pendingSelection = nil
            } else if Date() >= pending.deadline {
                throw ControllerError.timedOut(
                    "selection did not become active: \(pending.safeLabel)"
                )
            } else {
                Thread.sleep(forTimeInterval: pollSeconds)
                continue
            }
        }

        if isVSCodeReady(current) {
            print("Ready: the ICRN Visual Studio Code instance is fully loaded.")
            return .ready
        }

        if isDuo(current) {
            if !duoMessagePrinted {
                print("Duo approval is required. Approve the expected UIUC sign-in; the script is waiting and will continue automatically.")
                duoMessagePrinted = true
            }
            Thread.sleep(forTimeInterval: pollSeconds)
            continue
        }
        duoMessagePrinted = false

        if current.containsFragment("spawn failed")
            || current.containsFragment("server failed to start")
            || current.containsFragment("error starting server") {
            throw ControllerError.serverFailed
        }

        let host = current.pageURL?.host?.lowercased() ?? ""
        var nextAction: (
            ledgerKey: String,
            label: String,
            element: AXUIElement
        )?

        func consider(
            _ key: String,
            _ controlLabel: String,
            statusLabel: String? = nil
        ) throws {
            guard nextAction == nil,
                  let element = try uniquePressable(
                    in: current,
                    label: controlLabel,
                    safeLabel: statusLabel
                  ) else {
                return
            }
            let safeLabel = statusLabel ?? controlLabel
            let ledgerKey = actionLedgerKey(key, snapshot: current)
            if let prior = actionAttempts[ledgerKey] {
                let elapsed = Date().timeIntervalSince(prior.attemptedAt)
                guard elapsed >= actionRetryDelay else { return }
                guard prior.count < maximumActionAttempts else {
                    throw ControllerError.retriesExhausted(safeLabel)
                }
            }
            nextAction = (ledgerKey, safeLabel, element)
        }

        if host == config.originHost {
            try consider("cilogon", "Sign in with CILogon")
        }
        if config.host(host, has: .identityProvider)
            || current.containsFragment("select an identity provider") {
            if !selectedChoice(in: current, label: config.identityProviderLabel) {
                if !completedSelections.contains("configured-idp"), try choosePopupOption(
                    in: current,
                    field: identityProviderField,
                    fallbackIndex: 0,
                    expectedPopupCount: 1,
                    choice: config.identityProviderLabel,
                    safeChoiceLabel: "configured identity provider"
                ) {
                    completedSelections.insert("configured-idp")
                    pendingSelection = (
                        label: config.identityProviderLabel,
                        safeLabel: "configured identity provider",
                        deadline: Date().addingTimeInterval(12)
                    )
                    print("Continuing: configured identity provider")
                    Thread.sleep(forTimeInterval: pollSeconds)
                    continue
                }
            } else {
                try consider("cilogon-logon", "Log On")
            }
        }
        if config.host(host, has: .microsoft) || config.host(host, has: .institution) {
            let exactAccountVisible = current.containsText(config.microsoftAccount)
            if current.containsFragment("pick an account")
                || current.containsFragment("choose an account") {
                try consider(
                    "account",
                    config.microsoftAccount,
                    statusLabel: "configured Microsoft account"
                )
            } else if current.containsFragment("stay signed in") {
                if confirmedMicrosoftAccount || exactAccountVisible {
                    try consider("stay-signed-in-no", "No")
                }
            } else if exactAccountVisible {
                confirmedMicrosoftAccount = true
                try consider("microsoft-sign-in", "Sign in")
            }
        }

        if host == config.originHost {
            let path = current.pageURL?.path ?? ""
            if path.hasPrefix("/hub/spawn-pending") {
                unattestedSpawnSince = nil
            } else if path == config.spawnPath || current.containsFragment("session options") {
                if configuredSpawnAttested(current) {
                    unattestedSpawnSince = nil
                    try consider("start", "Start")
                } else if let since = unattestedSpawnSince {
                    if Date().timeIntervalSince(since) >= 15 {
                        throw ControllerError.timedOut(
                            "the spawn page did not attest the configured environment and resource"
                        )
                    }
                } else {
                    unattestedSpawnSince = Date()
                }
            } else {
                unattestedSpawnSince = nil
                try consider("launch-server", "Launch Server")
            }
        }

        if let action = nextAction {
            let priorCount = actionAttempts[action.ledgerKey]?.count ?? 0
            let attempt = priorCount + 1
            actionAttempts[action.ledgerKey] = ActionAttempt(
                count: attempt,
                attemptedAt: Date()
            )
            print("Continuing: \(action.label) (attempt \(attempt)/\(maximumActionAttempts))")
            do {
                try press(action.element, label: action.label)
            } catch ControllerError.actionFailed {
                print("The AX press failed; waiting to retry with a fresh element.")
            }
            Thread.sleep(forTimeInterval: 1.25)
            continue
        }

        let status = hostSummary(current)
        if status != lastStatus {
            print("Waiting at \(status)")
            lastStatus = status
        }
        Thread.sleep(forTimeInterval: pollSeconds)
    }
    throw ControllerError.timedOut(lastStatus.isEmpty ? "unknown page" : lastStatus)
}

private func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 1 else {
        fputs("Usage: open_icrn.swift [--run|--observe]\n", stderr)
        exit(2)
    }
    let mode: Mode
    switch arguments[0] {
    case "--run": mode = .run
    case "--observe": mode = .observe
    default:
        fputs("Usage: open_icrn.swift [--run|--observe]\n", stderr)
        exit(2)
    }

    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(prompt) else {
        throw ControllerError.accessibilityUnavailable
    }

    switch mode {
    case .run:
        let existingWindows = chromeWindows()
        try launchChrome()
        let owned: OwnedFlow
        do {
            owned = try waitForOwnedFlow(excluding: existingWindows)
        } catch {
            reportCleanup(closeSoleNewFlowWindow(excluding: existingWindows))
            throw error
        }
        let initial = owned.snapshot
        do {
            let completion = try run(initial: initial)
            if completion == .ready {
                var closed = ownedWindowWasClosed(initial)
                for _ in 0..<2 {
                    if closed { break }
                    _ = closeWindow(initial.window)
                    let closeDeadline = Date().addingTimeInterval(2)
                    while Date() < closeDeadline {
                        if ownedWindowWasClosed(initial) {
                            closed = true
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                }
                guard closed else { throw ControllerError.windowCloseFailed }
                print("Closed the launcher-owned Chrome window; the configured instance remains running.")
            }
        } catch {
            if !ownedWindowWasClosed(initial), !closeWindow(initial.window) {
                fputs("ICRN controller: warning: could not close the owned Chrome window.\n", stderr)
            }
            throw error
        }
    case .observe: try observe()
    }
}

do {
    try main()
} catch {
    fputs("ICRN controller: \(error)\n", stderr)
    exit(1)
}
