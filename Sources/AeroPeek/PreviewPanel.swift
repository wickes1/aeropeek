import AppKit

/// The one preview panel, created once and reused for every hover.
///
/// Drawn with plain Core Animation layers: a thumbnail is a `CGImage` handed to the GPU as layer
/// contents, and there is no view tree to measure or diff.
final class PreviewPanel: NSPanel {
    /// Index of the clicked window in the list last passed to `show`.
    var onClick: ((Int) -> Void)?
    /// The pointer entered, left, or moved over the panel.
    var onPointerEvent: (() -> Void)?

    private let surface = SurfaceView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Above the Dock, which sits over normal windows.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = surface
        surface.panel = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(windows: [WindowInfo], layout: Layout, images: [CGImage?]) {
        setFrame(layout.panelFrame, display: false)
        surface.render(windows: windows, layout: layout, images: images)
        orderFrontRegardless()
    }

    func setImage(_ image: CGImage, at index: Int) {
        surface.setImage(image, at: index)
    }

    /// Moves the highlight to the card under the pointer. The owner calls this on every pointer move
    /// it hears of: macOS sends moves to the active app, so a panel that never activates cannot count
    /// on receiving them itself.
    func pointerMoved() {
        surface.highlightUnderPointer()
    }

    func hide() {
        orderOut(nil)
        surface.highlight(nil)
    }
}

private final class SurfaceView: NSView {
    weak var panel: PreviewPanel?

    private struct Card {
        let highlight = CALayer()
        let title = CATextLayer()
        let image = CALayer()
    }

    private var cards: [Card] = []
    private var layout: Layout?
    private var highlighted: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        // Enter and exit arrive reliably; moves only sometimes, so the owner also feeds them in from outside.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // A click must act at once: the panel never has focus, so without this the first click only "activates" it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func render(windows: [WindowInfo], layout: Layout, images: [CGImage?]) {
        self.layout = layout
        let scale = panel?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // No implicit animations: every change lands in the frame it is made.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Colours follow the system appearance at the moment of showing.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            while cards.count < windows.count {
                let card = Card()
                card.highlight.cornerRadius = 10
                card.highlight.cornerCurve = .continuous
                card.highlight.borderWidth = 2.5
                card.title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
                card.title.fontSize = 13
                card.title.alignmentMode = .center
                card.title.truncationMode = .middle
                card.image.cornerRadius = 6
                card.image.masksToBounds = true
                card.image.contentsGravity = .resize
                for sublayer in [card.highlight, card.title, card.image] { layer?.addSublayer(sublayer) }
                cards.append(card)
            }
            for (i, card) in cards.enumerated() {
                let used = i < windows.count
                card.highlight.isHidden = true
                card.title.isHidden = !used
                card.image.isHidden = !used
                guard used else { card.image.contents = nil; continue }
                card.highlight.frame = layout.cells[i].insetBy(dx: -8, dy: -8)
                card.highlight.borderColor = NSColor.controlAccentColor.cgColor
                card.title.frame = layout.titleRect(i)
                card.title.contentsScale = scale
                card.title.foregroundColor = NSColor.labelColor.cgColor
                card.title.string = windows[i].title
                card.image.frame = layout.thumbs[i]
                // Shows through until the first capture of a window arrives.
                card.image.backgroundColor = NSColor.quaternaryLabelColor.cgColor
                card.image.contents = images[i]
            }
        }
        highlighted = nil
        highlightUnderPointer()
    }

    func highlightUnderPointer() {
        guard let panel, panel.isVisible else { return }
        highlight(layout?.index(at: convert(panel.mouseLocationOutsideOfEventStream, from: nil)))
    }

    func setImage(_ image: CGImage, at index: Int) {
        guard index < cards.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cards[index].image.contents = image
        CATransaction.commit()
    }

    func highlight(_ index: Int?) {
        guard index != highlighted else { return }
        if debug { log("highlight \(index.map(String.init) ?? "none")") }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let highlighted, highlighted < cards.count { cards[highlighted].highlight.isHidden = true }
        if let index, index < cards.count { cards[index].highlight.isHidden = false }
        CATransaction.commit()
        highlighted = index
    }

    override func mouseEntered(with event: NSEvent) { panel?.onPointerEvent?() }
    override func mouseMoved(with event: NSEvent) { panel?.onPointerEvent?() }
    override func mouseExited(with event: NSEvent) { panel?.onPointerEvent?() }

    override func mouseDown(with event: NSEvent) {
        if let index = layout?.index(at: convert(event.locationInWindow, from: nil)) { panel?.onClick?(index) }
    }
}
