import AppKit
import ApplicationServices
import os

private let logger = Logger(subsystem: "dev.wickend.aeropeek", category: "app")

/// Failures go to the unified log (an app started from Finder has no stderr anyone reads) and to
/// stderr. `AEROPEEK_DEBUG=1` adds hover events and timings.
func log(_ message: @autoclosure () -> String) {
    let text = message()
    logger.notice("\(text, privacy: .public)")
    fputs("aeropeek: \(text)\n", stderr)
}

let debug = ProcessInfo.processInfo.environment["AEROPEEK_DEBUG"] == "1"

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    /// Long enough to carry the pointer from the icon across the gap into the panel, short enough
    /// that the panel does not linger after the pointer leaves for somewhere else.
    private static let hideGrace: TimeInterval = 0.2
    /// How often a sliding Dock is re-read. Short enough that the panel follows it without a visible lag.
    private static let dockSettleInterval: TimeInterval = 0.05
    /// Homebrew on Apple silicon, Homebrew on Intel, nix-darwin. An app started from Finder has no shell PATH to search.
    private static let aerospaceLocations = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace", "/run/current-system/sw/bin/aerospace"]
    private static let aerospace = aerospaceLocations.first { FileManager.default.isExecutableFile(atPath: $0) }

    private let watcher = DockWatcher()
    private let thumbnails = Thumbnails()
    private let panel = PreviewPanel()
    private let lookup = DispatchQueue(label: "aeropeek.windows", qos: .userInteractive)

    /// The hover the visible panel was built for; `nil` while hidden.
    private var hover: DockWatcher.Hover?
    private var shown: [WindowInfo] = []
    /// Bumped whenever the panel's content changes or it hides; work started earlier drops its result.
    private var generation = 0
    private var pendingHide: DispatchWorkItem?
    /// Exists only while the panel is visible, so an idle aeropeek receives no mouse events at all.
    private var pointerMonitor: Any?
    /// Highest icon top seen for the current Dock size on the current screen: where the Dock's top edge rests.
    private var dockRest: (iconHeight: CGFloat, screenMinY: CGFloat, top: CGFloat)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let problem = unsupportedSetup() {
            log(problem)
            let alert = NSAlert()
            alert.messageText = "aeropeek cannot run here"
            alert.informativeText = problem
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        // One slow app must not stall the rest: every accessibility call in this process gives up after this long.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        watcher.onChange = { [weak self] hover in MainActor.assumeIsolated { self?.hoverChanged(hover) } }
        panel.onPointerEvent = { [weak self] in self?.pointerMoved() }
        panel.onClick = { [weak self] index in self?.clicked(index) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.thumbnails.prune(pid: pid) }
        }

        // Screen Recording: without it captures fail and cards stay grey. macOS applies a new grant on relaunch.
        if !CGPreflightScreenCaptureAccess() {
            log("Screen Recording permission missing: thumbnails stay empty until it is granted and aeropeek is relaunched")
            CGRequestScreenCaptureAccess()
        }
        // Accessibility: needed to hear the Dock and to list other apps' windows.
        if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            startWatching()
        } else {
            log("Accessibility permission missing: waiting for it")
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                MainActor.assumeIsolated { self?.startWatching() }
            }
        }
    }

    /// What stops aeropeek from working on this Mac, in words for the user; `nil` when nothing does.
    /// Checked once at launch so a broken setup is announced instead of showing up as a click that does nothing.
    private func unsupportedSetup() -> String? {
        if Self.aerospace == nil {
            return "The aerospace command was not found at \(Self.aerospaceLocations.joined(separator: ", ")). aeropeek hands every click to AeroSpace."
        }
        // Absent means the default, which is the bottom.
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        if let orientation, orientation != "bottom" {
            return "The Dock is on the \(orientation) edge. aeropeek places its panel above a Dock at the bottom of the screen."
        }
        return nil
    }

    private func startWatching() {
        watcher.start { [weak self] started in
            guard started else {
                log("cannot observe the Dock (is it running?)")
                NSApp.terminate(nil)
                return
            }
            MainActor.assumeIsolated { self?.prewarm() }
        }
    }

    /// Captures every open window once, so the first hover of each app already has its thumbnails.
    private func prewarm() {
        let pids = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
        lookup.async {
            let windows = pids.flatMap { Windows.list(pid: $0) ?? [] }
            Task { @MainActor in
                let started = CFAbsoluteTimeGetCurrent()
                // One layout per window: laid out together, this many windows would get narrowed boxes
                // and the cache would start out with thumbnails too small for a real panel.
                let sizes = windows.flatMap { self.pixelSizes(Layout(windowSizes: [$0.size], anchorMidX: 0, screen: NSScreen.main?.frame ?? .zero, dockThickness: 0)) }
                await self.thumbnails.refresh(windows, pixelSizes: sizes, each: { _, _ in })
                if debug { log("prewarmed \(windows.count) windows in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms") }
            }
        }
    }

    // MARK: Showing

    private func hoverChanged(_ newHover: DockWatcher.Hover?) {
        if debug { log("dock reports: \(newHover.map { "pid \($0.pid)" } ?? "no app")") }
        guard let newHover else {
            // The pointer is on the Trash, a folder, a separator: no app to preview. The Dock does not
            // report this when the pointer leaves an icon upwards, so it cannot cut off the way into the
            // panel. A panel still being looked up is dropped too, or it would open under a pointer that
            // has moved on.
            if !panel.isVisible || pointerIsInDockZone() { hide() }
            return
        }
        cancelHide()
        // The Dock repeats its report for the icon it is already on; that app's panel is up.
        guard newHover.pid != hover?.pid else { return }
        hover = newHover
        generation += 1
        let generation = generation, started = CFAbsoluteTimeGetCurrent()
        lookup.async {
            let windows = Windows.list(pid: newHover.pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.present(windows, for: newHover, generation: generation, started: started) }
            }
        }
    }

    private func present(_ windows: [WindowInfo]?, for hover: DockWatcher.Hover, generation: Int, started: CFAbsoluteTime) {
        guard generation == self.generation else { return }
        guard let windows else {
            // Its thumbnails stay cached: the app is busy, not gone.
            log("pid \(hover.pid) did not answer the window query")
            hide()
            return
        }
        thumbnails.prune(pid: hover.pid, keeping: windows)
        guard !windows.isEmpty, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            hide()
            return
        }
        let dock = noteDockTop(hover, screenMinY: screen.frame.minY)
        let layout = Layout(windowSizes: windows.map(\.size), anchorMidX: hover.iconMidX, screen: screen.frame,
                            dockThickness: dock.top - screen.frame.minY)
        shown = windows
        panel.show(windows: windows, layout: layout, images: windows.map { thumbnails.cached($0.id) })
        watchPointer()
        // The pointer may have left while the windows were being listed; no event will say so.
        pointerMoved()
        if !dock.known { settleDock(screenMinY: screen.frame.minY) }
        let shownAt = CFAbsoluteTimeGetCurrent()

        // The cached image is already on screen; replace it with a fresh one when the capture lands.
        Task {
            await thumbnails.refresh(windows, pixelSizes: pixelSizes(layout, scale: screen.backingScaleFactor)) { [weak self] window, image in
                guard let self, generation == self.generation, let index = self.shown.firstIndex(of: window) else { return }
                self.panel.setImage(image, at: index)
            }
            if debug {
                log("pid \(hover.pid): \(windows.count) windows, panel in \(Int((shownAt - started) * 1000)) ms, fresh thumbnails \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms after hover")
            }
        }
    }

    private func pixelSizes(_ layout: Layout, scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2) -> [CGSize] {
        layout.thumbs.map { CGSize(width: $0.width * scale, height: $0.height * scale) }
    }

    // MARK: Where the Dock's top edge rests

    /// Records a reading of the Dock's top edge and returns where the edge rests as far as is known.
    /// `known` is false when the reading was new or higher than before: the Dock may then still be
    /// sliding in, and `top` may be too low.
    private func noteDockTop(_ hover: DockWatcher.Hover, screenMinY: CGFloat) -> (top: CGFloat, known: Bool) {
        if let rest = dockRest, rest.iconHeight == hover.iconHeight, rest.screenMinY == screenMinY, hover.iconTop <= rest.top {
            return (rest.top, true)
        }
        dockRest = (hover.iconHeight, screenMinY, hover.iconTop)
        return (hover.iconTop, false)
    }

    /// Follows a Dock that is still sliding in: re-reads its top edge until the reading holds still,
    /// lifting the panel each time it rises. Runs only after a reading that was new; once the resting
    /// position is known, every panel opens in its final place and nothing is re-read.
    private func settleDock(screenMinY: CGFloat, readsLeft: Int = 12, unchanged: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dockSettleInterval) { [weak self] in
            guard let self, self.panel.isVisible, let now = self.watcher.currentHover() else { return }
            let dock = self.noteDockTop(now, screenMinY: screenMinY)
            if !dock.known {
                var frame = self.panel.frame
                frame.origin.y = dock.top + Layout.dockGap
                if debug { log("dock still rising: panel moved to y \(Int(frame.origin.y))") }
                self.panel.setFrame(frame, display: true)
            }
            // Three readings in a row without a rise: the Dock has stopped.
            let unchanged = dock.known ? unchanged + 1 : 0
            if unchanged < 3, readsLeft > 1 { self.settleDock(screenMinY: screenMinY, readsLeft: readsLeft - 1, unchanged: unchanged) }
        }
    }

    // MARK: Hiding

    /// The strip below the panel on the panel's own screen, where the Dock is.
    private func pointerIsInDockZone() -> Bool {
        let pointer = NSEvent.mouseLocation
        return panel.isVisible && pointer.y < panel.frame.minY && panel.screen?.frame.contains(pointer) == true
    }

    private func watchPointer() {
        guard pointerMonitor == nil else { return }
        // A global monitor hears the moves macOS sends to other apps, which is nearly all of them: moves
        // go to the active app even while the pointer is over this panel. The few sent here instead
        // come in through the panel's tracking area.
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    /// The panel stays while the pointer is on it or in the Dock below it, and goes shortly after the
    /// pointer is anywhere else. The Dock's own report cannot decide this: it keeps naming the icon
    /// after the pointer has left it.
    private func pointerMoved() {
        guard panel.isVisible else { return }
        panel.pointerMoved()
        if panel.frame.contains(NSEvent.mouseLocation) || pointerIsInDockZone() {
            cancelHide()
        } else if pendingHide == nil {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            pendingHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideGrace, execute: work)
        }
    }

    private func cancelHide() {
        pendingHide?.cancel()
        pendingHide = nil
    }

    private func hide() {
        cancelHide()
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        generation += 1
        hover = nil
        shown = []
        panel.hide()
    }

    private func clicked(_ index: Int) {
        guard index < shown.count, let aerospace = Self.aerospace else { return }
        let id = shown[index].id
        hide()
        // AeroSpace owns focus: it switches to the window's workspace and focuses it in one step.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: aerospace)
        process.arguments = ["focus", "--window-id", String(id)]
        process.terminationHandler = { finished in
            if finished.terminationStatus != 0 { log("aerospace focus --window-id \(id) exited \(finished.terminationStatus)") }
        }
        do { try process.run() } catch { log("cannot run \(aerospace): \(error.localizedDescription)") }
    }
}

// Top-level code runs on the main thread, but in Swift 5 mode the compiler does not know it.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = Controller()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
