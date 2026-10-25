import AppKit
import SwiftUI

/// Owns the floating widget window.
///
/// The widget is a borderless, non-activating panel: it never takes focus from the app
/// you're working in, follows you across Spaces and full-screen apps, can be dragged
/// anywhere, fades when the pointer is away, and can be made click-through.
@MainActor
final class FloatingWidgetController {
    private weak var model: AppModel?
    private var panel: FloatingPanel?
    private var hovering = false
    private var screenObserver: NSObjectProtocol?
    private static let autosaveName = "KvotaWidgetPanel"

    func attach(_ model: AppModel) {
        self.model = model
        sync()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.keepOnScreen() }
        }
    }

    /// Applies the current settings: shows, hides and restyles the panel.
    func sync() {
        guard let model else { return }
        let settings = model.settings
        guard settings.widgetVisible else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel(model: model)
        panel.ignoresMouseEvents = settings.widgetClickThrough
        panel.level = settings.widgetOnTop
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        behavior.insert(settings.widgetAllSpaces ? .canJoinAllSpaces : .moveToActiveSpace)
        if settings.widgetAllSpaces { behavior.insert(.stationary) }
        panel.collectionBehavior = behavior
        applyAlpha(animated: false)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            keepOnScreen()
        }
    }

    func resetPosition() {
        guard let panel else { return }
        panel.setFrameOrigin(defaultOrigin(for: panel.frame.size))
        panel.saveFrame(usingName: Self.autosaveName)
    }

    private func makePanel(model: AppModel) -> FloatingPanel {
        let panel = FloatingPanel()
        let root = WidgetView().environment(model)
        let hosting = WidgetHostingView(rootView: AnyView(root))
        hosting.onHoverChange = { [weak self] inside in
            self?.hovering = inside
            self?.applyAlpha(animated: true)
        }
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if !panel.setFrameUsingName(Self.autosaveName) {
            panel.setFrameOrigin(defaultOrigin(for: panel.frame.size))
        }
        // The saved frame may have a stale size; only its position matters.
        panel.setContentSize(hosting.fittingSize)
        _ = panel.setFrameAutosaveName(Self.autosaveName)
        self.panel = panel
        return panel
    }

    private func applyAlpha(animated: Bool) {
        guard let panel, let settings = model?.settings else { return }
        let target = (hovering || !settings.widgetFadeWhenIdle) ? 1.0 : settings.widgetOpacity
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = target
            }
        } else {
            panel.alphaValue = target
        }
    }

    /// Top-right corner of the main screen, under the menu bar.
    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 14, y: visible.maxY - size.height - 10)
    }

    private func keepOnScreen() {
        guard let panel else { return }
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !onScreen { resetPosition() }
    }
}

/// Borderless panel that floats without ever becoming the active window.
final class FloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        title = "Kvota"
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that lets the whole widget drag the window, resizes the window when the
/// content changes size, and reports hover even though the app is never active.
final class WidgetHostingView: NSHostingView<AnyView> {
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    private var resizeScheduled = false

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.resizeScheduled = false
            self?.resizeWindowToFit()
        }
    }

    /// Keeps the edge nearest the screen corner fixed, so a widget parked top-right
    /// grows down and to the left.
    func resizeWindowToFit() {
        guard let window else { return }
        let size = fittingSize
        guard size.width > 1, size.height > 1 else { return }
        var frame = window.frame
        guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let anchorRight = frame.midX > screen.midX
        let anchorTop = frame.midY > screen.midY
        let newX = anchorRight ? frame.maxX - size.width : frame.minX
        let newY = anchorTop ? frame.maxY - size.height : frame.minY
        frame = NSRect(x: newX, y: newY, width: size.width, height: size.height)
        window.setFrame(frame, display: true)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}
