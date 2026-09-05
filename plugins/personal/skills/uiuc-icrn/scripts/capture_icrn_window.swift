import AppKit
import ApplicationServices
import Foundation

private let chromeBundleIdentifier = "com.google.Chrome"
private let webAreaRole = "AXWebArea"
private let maximumElementCount = 8_000
private let maximumDepth = 24
private let boundsTolerance: CGFloat = 2

private struct CaptureConfig {
    let originHost: String
    let username: String
    let serverKey: String
    let workbenchService: String
    let remoteRoot: String

    var userWorkbenchPath: String {
        let server = serverKey.isEmpty ? "" : "/\(serverKey)"
        return "/user/\(username)\(server)/\(workbenchService)"
    }

    var hubWorkbenchPath: String { "/hub\(userWorkbenchPath)" }

    static func load() throws -> CaptureConfig {
        let environment = ProcessInfo.processInfo.environment
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else {
                throw CaptureError.configuration("missing required launcher variable \(name)")
            }
            return value
        }
        let originString = try required("ICRN_ORIGIN")
        guard let origin = URL(string: originString),
              origin.scheme?.lowercased() == "https",
              let originHost = origin.host,
              origin.user == nil,
              origin.password == nil,
              origin.query == nil,
              origin.fragment == nil else {
            throw CaptureError.configuration("ICRN_ORIGIN is not a valid HTTPS origin")
        }
        let remoteRoot = try required("ICRN_REMOTE_ROOT")
        guard remoteRoot.hasPrefix("/") else {
            throw CaptureError.configuration("ICRN_REMOTE_ROOT must be absolute")
        }
        return CaptureConfig(
            originHost: originHost.lowercased(),
            username: try required("ICRN_USERNAME"),
            serverKey: environment["ICRN_SERVER_KEY"] ?? "",
            workbenchService: try required("ICRN_WORKBENCH_SERVICE"),
            remoteRoot: remoteRoot
        )
    }
}

private let config: CaptureConfig = {
    do {
        return try CaptureConfig.load()
    } catch {
        fputs("ICRN window capture: \(error)\n", stderr)
        exit(2)
    }
}()

private enum CaptureError: Error, CustomStringConvertible {
    case configuration(String)
    case accessibilityUnavailable
    case chromeUnavailable
    case targetUnavailable
    case ambiguousTargets(Int)
    case windowBoundsUnavailable
    case cgWindowUnavailable
    case ambiguousCGWindows([CGWindowID])
    case captureFailed(Int32)
    case invalidCapture(String)

    var description: String {
        switch self {
        case .configuration(let message):
            return "Invalid ICRN configuration: \(message)."
        case .accessibilityUnavailable:
            return "Accessibility access is required."
        case .chromeUnavailable:
            return "Google Chrome is not running."
        case .targetUnavailable:
            return "No Chrome window contains the requested ICRN VS Code web area."
        case .ambiguousTargets(let count):
            return "Refusing to capture because \(count) Chrome windows contain the requested ICRN VS Code web area."
        case .windowBoundsUnavailable:
            return "The target Chrome window did not expose usable Accessibility bounds."
        case .cgWindowUnavailable:
            return "Could not map the target Accessibility window to a Core Graphics window."
        case .ambiguousCGWindows(let identifiers):
            return "The target Accessibility window maps to multiple Core Graphics windows: \(identifiers)."
        case .captureFailed(let status):
            return "screencapture failed with exit status \(status)."
        case .invalidCapture(let path):
            return "screencapture did not create a readable, non-empty image at \(path)."
        }
    }
}

private struct TargetWindow {
    let element: AXUIElement
    let processIdentifier: pid_t
    let title: String
}

private struct CGWindowCandidate {
    let identifier: CGWindowID
    let bounds: CGRect
    let title: String
}

private func copiedAttribute(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value
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
    guard let value = copiedAttribute(element, kAXURLAttribute as CFString) else {
        return nil
    }
    if let url = value as? URL { return url }
    if let string = value as? String { return URL(string: string) }
    return nil
}

private func descendants(of root: AXUIElement) -> [AXUIElement] {
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var index = 0
    var result: [AXUIElement] = []

    while index < queue.count && result.count < maximumElementCount {
        let item = queue[index]
        index += 1
        result.append(item.element)
        guard item.depth < maximumDepth else { continue }
        for child in elementsAttribute(item.element, kAXChildrenAttribute as CFString)
            .prefix(maximumElementCount - result.count) {
            queue.append((child, item.depth + 1))
        }
    }
    return result
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

private func isRequestedWorkbenchURL(_ url: URL?) -> Bool {
    guard let url,
          url.scheme?.lowercased() == "https",
          url.host?.lowercased() == config.originHost else {
        return false
    }
    let path = url.path.count > 1 && url.path.hasSuffix("/")
        ? String(url.path.dropLast())
        : url.path
    guard path == config.userWorkbenchPath || path == config.hubWorkbenchPath else {
        return false
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return false
    }
    let folderValues = (components.queryItems ?? [])
        .filter { $0.name == "folder" }
        .compactMap(\.value)
    return folderValues == [config.remoteRoot]
}

private func findTargetWindow() throws -> TargetWindow {
    let applications = NSRunningApplication.runningApplications(
        withBundleIdentifier: chromeBundleIdentifier
    ).filter { !$0.isTerminated }
    guard !applications.isEmpty else { throw CaptureError.chromeUnavailable }

    var matches: [TargetWindow] = []
    for application in applications {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        for window in elementsAttribute(appElement, kAXWindowsAttribute as CFString) {
            let hasTarget = descendants(of: window).contains { element in
                stringAttribute(element, kAXRoleAttribute as CFString) == webAreaRole
                    && isTopLevelWebArea(element, in: window)
                    && isRequestedWorkbenchURL(urlAttribute(element))
            }
            guard hasTarget else { continue }
            matches.append(TargetWindow(
                element: window,
                processIdentifier: application.processIdentifier,
                title: stringAttribute(window, kAXTitleAttribute as CFString)
            ))
        }
    }

    guard !matches.isEmpty else { throw CaptureError.targetUnavailable }
    guard matches.count == 1 else { throw CaptureError.ambiguousTargets(matches.count) }
    return matches[0]
}

private func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
    guard let object = copiedAttribute(element, attribute),
          CFGetTypeID(object) == AXValueGetTypeID() else {
        return nil
    }
    let value = unsafeBitCast(object, to: AXValue.self)
    var point = CGPoint.zero
    guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
    return point
}

private func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
    guard let object = copiedAttribute(element, attribute),
          CFGetTypeID(object) == AXValueGetTypeID() else {
        return nil
    }
    let value = unsafeBitCast(object, to: AXValue.self)
    var size = CGSize.zero
    guard AXValueGetValue(value, .cgSize, &size) else { return nil }
    return size
}

private func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
    abs(lhs - rhs) <= boundsTolerance
}

private func boundsMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    nearlyEqual(lhs.origin.x, rhs.origin.x)
        && nearlyEqual(lhs.origin.y, rhs.origin.y)
        && nearlyEqual(lhs.size.width, rhs.size.width)
        && nearlyEqual(lhs.size.height, rhs.size.height)
}

private func cgWindowID(for target: TargetWindow) throws -> CGWindowID {
    guard let position = pointAttribute(target.element, kAXPositionAttribute as CFString),
          let size = sizeAttribute(target.element, kAXSizeAttribute as CFString) else {
        throw CaptureError.windowBoundsUnavailable
    }
    let accessibilityBounds = CGRect(origin: position, size: size)
    guard let rawWindows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        throw CaptureError.cgWindowUnavailable
    }

    let candidates: [CGWindowCandidate] = rawWindows.compactMap { info in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                == target.processIdentifier,
              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0,
              let identifier = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              boundsMatch(bounds, accessibilityBounds) else {
            return nil
        }
        return CGWindowCandidate(
            identifier: identifier,
            bounds: bounds,
            title: info[kCGWindowName as String] as? String ?? ""
        )
    }

    guard !candidates.isEmpty else { throw CaptureError.cgWindowUnavailable }
    if let direct = copiedAttribute(target.element, "AXWindowNumber" as CFString) as? NSNumber {
        let identifier = direct.uint32Value
        if candidates.contains(where: { $0.identifier == identifier }) { return identifier }
    }
    if candidates.count == 1 { return candidates[0].identifier }

    let exactTitleMatches = candidates.filter {
        !target.title.isEmpty && $0.title == target.title
    }
    if exactTitleMatches.count == 1 { return exactTitleMatches[0].identifier }
    let containedTitleMatches = candidates.filter {
        !target.title.isEmpty && !$0.title.isEmpty
            && (target.title.contains($0.title) || $0.title.contains(target.title))
    }
    if containedTitleMatches.count == 1 { return containedTitleMatches[0].identifier }
    throw CaptureError.ambiguousCGWindows(candidates.map(\.identifier))
}

private func capture(windowID: CGWindowID, to outputURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-tpng", "-l\(windowID)", outputURL.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CaptureError.captureFailed(process.terminationStatus)
    }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
          let byteCount = attributes[.size] as? NSNumber,
          byteCount.int64Value > 0,
          let image = NSImage(contentsOf: outputURL),
          image.size.width > 0,
          image.size.height > 0 else {
        throw CaptureError.invalidCapture(outputURL.path)
    }
}

private func main() throws {
    guard AXIsProcessTrusted() else { throw CaptureError.accessibilityUnavailable }
    let outputPath = CommandLine.arguments.dropFirst().first
        ?? "/private/tmp/icrn-vscode-window.png"
    let outputURL = URL(fileURLWithPath: outputPath)
    let target = try findTargetWindow()
    let identifier = try cgWindowID(for: target)
    try capture(windowID: identifier, to: outputURL)
    print(outputURL.path)
}

do {
    try main()
} catch {
    fputs("ICRN window capture: \(error)\n", stderr)
    exit(1)
}
