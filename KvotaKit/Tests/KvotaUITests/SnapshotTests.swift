import AppKit
import SwiftUI
import XCTest
@testable import KvotaUI

/// Renders the main views with sample data to PNG files. CI uploads them so UI changes
/// can be reviewed without running the app. Set KVOTA_SNAPSHOT_DIR to enable.
@MainActor
final class SnapshotTests: XCTestCase {
    func testRenderSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["KVOTA_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set KVOTA_SNAPSHOT_DIR to render snapshots")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"

            let menuModel = SampleData.model()
            try render(MenuContentView().environment(menuModel), scheme: scheme, to: directory.appendingPathComponent("menu-\(suffix).png"))

            let compact = SampleData.model(style: .compact)
            try render(WidgetView().environment(compact).padding(12), scheme: scheme, to: directory.appendingPathComponent("widget-compact-\(suffix).png"))

            let detailed = SampleData.model(style: .detailed)
            try render(WidgetView().environment(detailed).padding(12), scheme: scheme, to: directory.appendingPathComponent("widget-detailed-\(suffix).png"))
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

    private func render<V: View>(_ view: V, scheme: ColorScheme, to url: URL) throws {
        let background = scheme == .dark ? Color(white: 0.13) : Color(white: 0.94)
        let content = view
            .environment(\.kvotaSnapshotMode, true)
            .environment(\.colorScheme, scheme)
            .background(background)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return XCTFail("Could not render \(url.lastPathComponent)") }
        try png.write(to: url)
    }
}
