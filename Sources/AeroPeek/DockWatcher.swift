import AppKit
import ApplicationServices

/// Reports which running app's Dock icon the pointer is on.
///
/// Event-driven: the Dock posts an accessibility notification whenever its hovered ("selected") item
/// changes, so nothing polls and the process sleeps until the pointer reaches the Dock.
final class DockWatcher {
    struct Hover {
        let pid: pid_t
        /// Horizontal centre of the icon, screen coordinates.
        let iconMidX: CGFloat
        /// Top edge of the icon's Dock tile, screen coordinates (origin bottom-left). The tile reaches
        /// the Dock's top edge. Lower than its resting value while an auto-hiding Dock is still sliding in.
        let iconTop: CGFloat
        /// Changes when the Dock is resized, which invalidates any remembered `iconTop`.
        let iconHeight: CGFloat
    }

    /// Called on the main thread whenever the Dock reports a hover change, with `currentHover()`.
    var onChange: ((Hover?) -> Void)?

    private var observer: AXObserver?
    private var list: AXUIElement?

    init() {
        // The Dock restarts (crash, `killall Dock`, some settings changes) and the observer dies with it.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.dock" else { return }
            self?.start { started in
                if !started { log("the Dock restarted and cannot be observed again: relaunch aeropeek") }
            }
        }
    }

    // The observer's callback holds an unretained pointer to this object.
    deinit { stop() }

    /// Subscribes to the Dock, trying again for a few seconds: a Dock that has just launched (at login,
    /// after a restart) takes a moment to publish its icon list. `done` gets false when it never did,
    /// or when Accessibility permission is missing.
    func start(attemptsLeft: Int = 8, done: @escaping (Bool) -> Void) {
        if subscribe() { return done(true) }
        guard attemptsLeft > 1 else { return done(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.start(attemptsLeft: attemptsLeft - 1, done: done)
        }
    }

    private func subscribe() -> Bool {
        stop()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let children = AX.elements(AXUIElementCreateApplication(dock.processIdentifier), kAXChildrenAttribute),
              let list = children.first(where: { AX.string($0, kAXRoleAttribute) == kAXListRole })
        else { return false }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<DockWatcher>.fromOpaque(refcon).takeUnretainedValue()
            watcher.onChange?(watcher.currentHover())
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &observer) == .success, let observer,
              AXObserverAddNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success
        else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = observer
        self.list = list
        return true
    }

    private func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        list = nil
    }

    /// The running app whose icon the Dock considers hovered, or `nil` for any other item or none.
    ///
    /// The Dock keeps reporting an icon after the pointer has left it upwards, so this says where the
    /// pointer last was in the Dock, not that it is still there.
    func currentHover() -> Hover? {
        guard let list,
              let item = AX.elements(list, kAXSelectedChildrenAttribute)?.first,
              AX.string(item, kAXSubroleAttribute) == "AXApplicationDockItem",
              let url = AX.value(item, kAXURLAttribute) as? URL,
              // By identifier, not by path: the Dock's path and the running app's can differ (Safari
              // sits in /Applications and runs from a Cryptex volume).
              let identifier = Bundle(url: url)?.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first,
              let position = AX.point(item, kAXPositionAttribute), let size = AX.size(item, kAXSizeAttribute),
              // Accessibility measures from the top of the primary screen; AppKit from its bottom.
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        return Hover(pid: app.processIdentifier, iconMidX: position.x + size.width / 2,
                     iconTop: primaryHeight - position.y, iconHeight: size.height)
    }
}
