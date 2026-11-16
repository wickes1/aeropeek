import AppKit
import ApplicationServices

/// Private, but the only way from an accessibility window to its window-server id.
/// AeroSpace, AltTab and yabai rely on the same call.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

struct WindowInfo: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let size: CGSize
}

enum Windows {
    /// An app's standard windows, oldest first; `nil` when the app did not answer.
    ///
    /// Window ids only grow, so sorting by id is creation order: a window keeps its place in the
    /// panel no matter which one was used last.
    ///
    /// Asks the app itself, so call this off the main thread: a hung app answers only at the timeout.
    /// AeroSpace keeps every workspace in one macOS Space, which is why this sees windows on hidden
    /// workspaces too.
    static func list(pid: pid_t) -> [WindowInfo]? {
        guard let elements = AX.elements(AXUIElementCreateApplication(pid), kAXWindowsAttribute) else { return nil }
        // Some windows have no title; the app's name still says what the thumbnail is.
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        return elements.compactMap { element -> WindowInfo? in
            guard AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole else { return nil }
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
            let title = AX.string(element, kAXTitleAttribute) ?? ""
            return WindowInfo(id: id, pid: pid, title: title.isEmpty ? appName : title,
                              size: AX.size(element, kAXSizeAttribute) ?? .zero)
        }
        .sorted { $0.id < $1.id }
    }
}
