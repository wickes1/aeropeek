import CoreGraphics

/// Geometry of the preview panel.
///
/// Pure arithmetic on purpose: the panel's frame is known before anything is drawn and never depends on
/// whether a thumbnail has arrived, so it cannot lag behind its content. (A panel sized by measuring
/// what it has rendered gets clipped when a preview grows after the measurement.)
struct Layout {
    /// 16:10, the shape of a full-screen tile on a MacBook display.
    static let thumbBox = CGSize(width: 300, height: 187.5)
    static let padding: CGFloat = 16
    static let titleHeight: CGFloat = 18
    static let titleGap: CGFloat = 8
    static let screenMargin: CGFloat = 8
    /// Space between the Dock's top edge and the panel: small enough that the pointer crosses it
    /// within the hide grace period.
    static let dockGap: CGFloat = 4
    static let panelHeight = padding + titleHeight + titleGap + thumbBox.height + padding

    /// Screen coordinates, origin bottom-left.
    let panelFrame: CGRect
    /// Panel coordinates, origin bottom-left. One per window: the title strip plus the thumbnail box.
    let cells: [CGRect]
    /// Panel coordinates. The window's own shape fitted inside its cell's thumbnail box.
    let thumbs: [CGRect]

    /// - Parameters:
    ///   - windowSizes: one per window, in the order they are shown.
    ///   - anchorMidX: horizontal centre of the hovered Dock icon, screen coordinates.
    ///   - dockThickness: from the screen's bottom edge to the Dock's top edge when the Dock is at rest.
    init(windowSizes: [CGSize], anchorMidX: CGFloat, screen: CGRect, dockThickness: CGFloat) {
        let count = CGFloat(max(windowSizes.count, 1))
        let available = screen.width - 2 * Self.screenMargin
        // Too many windows for the screen: narrow the boxes, keep the height.
        let boxWidth = min(Self.thumbBox.width, ((available - Self.padding) / count - Self.padding).rounded(.down))
        let width = Self.padding + count * (boxWidth + Self.padding)
        let x = min(max(anchorMidX - width / 2, screen.minX + Self.screenMargin), screen.maxX - Self.screenMargin - width)
        panelFrame = CGRect(x: x.rounded(), y: screen.minY + dockThickness + Self.dockGap, width: width, height: Self.panelHeight)

        var cells: [CGRect] = [], thumbs: [CGRect] = []
        for (i, size) in windowSizes.enumerated() {
            let box = CGRect(x: Self.padding + CGFloat(i) * (boxWidth + Self.padding), y: Self.padding,
                             width: boxWidth, height: Self.thumbBox.height)
            cells.append(CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height + Self.titleGap + Self.titleHeight))
            thumbs.append(Self.fit(size, in: box))
        }
        self.cells = cells
        self.thumbs = thumbs
    }

    func titleRect(_ i: Int) -> CGRect {
        CGRect(x: cells[i].minX, y: cells[i].maxY - Self.titleHeight, width: cells[i].width, height: Self.titleHeight)
    }

    /// The window under a point in panel coordinates. The gaps between cells belong to no window.
    func index(at point: CGPoint) -> Int? {
        cells.firstIndex { $0.contains(point) }
    }

    private static func fit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}
