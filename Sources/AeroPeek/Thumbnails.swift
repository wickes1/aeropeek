import AppKit
import ScreenCaptureKit

/// Window thumbnails, captured at display size and kept in memory.
///
/// ScreenCaptureKit, not the private SkyLight capture (`CGSHWCaptureWindowList`) that window switchers
/// usually reach for: AeroSpace parks the windows of hidden workspaces one pixel inside the screen
/// corner, and SkyLight returns only that visible sliver (measured: a 1x32 image). ScreenCaptureKit
/// returns the whole window wherever it sits.
@MainActor
final class Thumbnails {
    private struct Entry { let pid: pid_t; let image: CGImage }

    private var cache: [CGWindowID: Entry] = [:]
    /// ScreenCaptureKit's handles, refetched only when a window is missing from the map (about 40 ms).
    private var handles: [CGWindowID: SCWindow] = [:]

    func cached(_ id: CGWindowID) -> CGImage? { cache[id]?.image }

    /// Captures each window and hands the image over as soon as it is ready. Captures run concurrently.
    /// - Parameter pixelSize: per window, the size it is drawn at, in pixels.
    func refresh(_ windows: [WindowInfo], pixelSizes: [CGSize], each: @escaping (WindowInfo, CGImage) -> Void) async {
        if windows.contains(where: { handles[$0.id] == nil }) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                handles = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            } catch {
                log("cannot list windows for capture (Screen Recording permission?): \(error.localizedDescription)")
                return
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for (window, pixelSize) in zip(windows, pixelSizes) {
                guard let handle = handles[window.id] else { continue }
                group.addTask { @MainActor in
                    let configuration = SCStreamConfiguration()
                    configuration.width = max(Int(pixelSize.width), 1)
                    configuration.height = max(Int(pixelSize.height), 1)
                    configuration.showsCursor = false
                    configuration.ignoreShadowsSingleWindow = true
                    do {
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: SCContentFilter(desktopIndependentWindow: handle), configuration: configuration)
                        self.cache[window.id] = Entry(pid: window.pid, image: image)
                        each(window, image)
                    } catch {
                        // A window that closed between listing and capture lands here; so does a stale handle.
                        self.handles[window.id] = nil
                        log("capture failed for window \(window.id): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Drops thumbnails of an app's windows that no longer exist. `keeping` is the app's current window list.
    func prune(pid: pid_t, keeping windows: [WindowInfo] = []) {
        let alive = Set(windows.map(\.id))
        cache = cache.filter { $0.value.pid != pid || alive.contains($0.key) }
    }
}
