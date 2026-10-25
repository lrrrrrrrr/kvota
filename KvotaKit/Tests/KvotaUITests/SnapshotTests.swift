import AppKit
import SwiftUI
import XCTest
@testable import KvotaUI

/// Renders the main views with sample data to transparent PNGs at 2x.
/// `scripts/compose-screenshots.py` turns them into the README and App Store images.
/// Set KVOTA_SNAPSHOT_DIR to enable.
@MainActor
final class SnapshotTests: XCTestCase {
    func testRenderSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["KVOTA_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set KVOTA_SNAPSHOT_DIR to render snapshots")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            func file(_ name: String) -> URL { directory.appendingPathComponent("\(name)-\(suffix).png") }

            try render(MenuBarStrip().environment(SampleData.model()), scheme: scheme, to: file("menubar"))

            try render(
                MenuContentView()
                    .environment(SampleData.model())
                    .background(MenuWindowBackground()),
                scheme: scheme,
                to: file("menu")
            )

            try render(WidgetView().environment(SampleData.model(style: .compact)), scheme: scheme, to: file("widget-compact"))
            try render(WidgetView().environment(SampleData.model(style: .detailed)), scheme: scheme, to: file("widget-detailed"))

            for tab in [SettingsTab.providers, .widget] {
                let selection = SettingsSelection()
                selection.tab = tab
                try render(
                    SnapshotWindowChrome(title: "Kvota Settings") {
                        SettingsView(selection: selection).environment(SampleData.model())
                    },
                    scheme: scheme,
                    to: file("settings-\(tab.rawValue)")
                )
            }
        }
    }

    func testViewsBuildWithEmptyModel() {
        // Smoke test: an empty model must render without crashing.
        let model = AppModel(preview: AppSettings(), states: [], now: Date())
        let renderer = ImageRenderer(content: MenuContentView().environment(model).environment(\.kvotaSnapshotMode, true))
        XCTAssertNotNil(renderer.nsImage)
        let widget = ImageRenderer(content: WidgetView().environment(model).environment(\.kvotaSnapshotMode, true))
        XCTAssertNotNil(widget.nsImage)
    }

    /// Draws the view through AppKit (so AppKit-backed controls render too) into a
    /// transparent 2x bitmap.
    private func render<V: View>(_ view: V, scheme: ColorScheme, to url: URL) throws {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(
            rootView: view
                .environment(\.kvotaSnapshotMode, true)
                .environment(\.colorScheme, scheme)
        )
        hosting.appearance = appearance
        let size = hosting.fittingSize
        XCTAssertGreaterThan(size.width, 10, url.lastPathComponent)
        XCTAssertGreaterThan(size.height, 10, url.lastPathComponent)

        let window = SnapshotWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Give SwiftUI and AppKit a moment to finish layout and image loading.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return XCTFail("Could not allocate bitmap for \(url.lastPathComponent)") }
        rep.size = size
        appearance?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }
}

/// Reports itself as the active window so controls draw in their active colors.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// The menu bar item next to a clock, as it appears at the top of the screen.
private struct MenuBarStrip: View {
    var body: some View {
        HStack(spacing: 16) {
            MenuBarLabel()
            Text("Sun 25 Oct  9:41")
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}

/// Translucent rounded card like the menu bar window's material.
private struct MenuWindowBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.8))
            shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
    }
}

/// A plain macOS-style title bar so the settings view reads as a window.
private struct SnapshotWindowChrome<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                    Spacer()
                }
                .padding(.leading, 13)
            }
            .frame(height: 30)
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}
