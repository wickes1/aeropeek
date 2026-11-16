import CoreGraphics
import Testing
@testable import AeroPeek

@Suite struct PanelGeometry {
    // A second display, left of and below the primary one: an origin of (0, 0) would hide any place
    // where the layout forgets to offset by the screen.
    private let screen = CGRect(x: -1512, y: -200, width: 1512, height: 982)
    private let tiled = CGSize(width: 1512, height: 948)

    private func layout(_ sizes: [CGSize], midX: CGFloat = -800) -> Layout {
        Layout(windowSizes: sizes, anchorMidX: midX, screen: screen, dockThickness: 70)
    }

    // A panel that changes height or jumps vertically from one hover to the next is the fault this
    // tool was written to avoid. Both are the same for any app, any window count, any window shape.
    @Test func heightAndVerticalPositionNeverChange() {
        let reference = layout([tiled]).panelFrame
        for sizes in [[tiled, tiled], Array(repeating: tiled, count: 9), [CGSize(width: 400, height: 900)], [CGSize(width: 1800, height: 300), tiled]] {
            let frame = layout(sizes).panelFrame
            #expect(frame.height == reference.height)
            #expect(frame.minY == reference.minY)
        }
    }

    // The panel's bottom edge is the Dock's top edge plus a gap of a few points: any further and the
    // pointer could not cross from the icon into the panel before the hide grace period runs out.
    @Test func sitsJustAboveTheDock() {
        let gap = layout([tiled]).panelFrame.minY - (screen.minY + 70)
        #expect(gap >= 0 && gap <= 8)
    }

    // An app with many windows must still be fully reachable: nothing may hang off the screen, and
    // every thumbnail must stay inside its own cell.
    @Test func manyWindowsStayOnScreen() {
        let many = layout(Array(repeating: tiled, count: 11) + [CGSize(width: 1800, height: 300)])
        #expect(many.panelFrame.minX >= screen.minX)
        #expect(many.panelFrame.maxX <= screen.maxX)
        #expect(many.cells.count == 12)
        #expect(many.cells.allSatisfy { $0.minX >= 0 && $0.maxX <= many.panelFrame.width })
        #expect(zip(many.cells, many.thumbs).allSatisfy { $0.insetBy(dx: -0.01, dy: -0.01).contains($1) })
    }

    // Icons at either end of the Dock would centre the panel past the screen edge.
    @Test func clampsAtScreenEdges() {
        #expect(layout([tiled, tiled], midX: screen.minX + 5).panelFrame.minX == screen.minX + Layout.screenMargin)
        #expect(layout([tiled, tiled], midX: screen.maxX - 2).panelFrame.maxX == screen.maxX - Layout.screenMargin)
    }

    // A thumbnail keeps its window's shape, tall or wide, so a capture is never stretched to fill the box.
    @Test func thumbnailKeepsWindowShape() {
        for window in [CGSize(width: 400, height: 900), CGSize(width: 1800, height: 300)] {
            let thumb = layout([window]).thumbs[0]
            #expect(abs(thumb.width / thumb.height - window.width / window.height) < 0.001)
            #expect(thumb.height <= Layout.thumbBox.height + 0.01 && thumb.width <= Layout.thumbBox.width + 0.01)
        }
    }

    // A click must go to the window drawn under the pointer, and a click in a gap to none.
    @Test func hitTestFindsTheWindowUnderThePointer() {
        let two = layout([tiled, tiled])
        #expect(two.index(at: CGPoint(x: two.cells[0].midX, y: two.cells[0].midY)) == 0)
        #expect(two.index(at: CGPoint(x: two.cells[1].midX, y: two.titleRect(1).midY)) == 1)
        #expect(two.index(at: CGPoint(x: (two.cells[0].maxX + two.cells[1].minX) / 2, y: two.cells[0].midY)) == nil)
    }
}
