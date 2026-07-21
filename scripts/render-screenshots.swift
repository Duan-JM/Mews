import AppKit
import Darwin
import Foundation
import SwiftUI
import Vision

@main
@MainActor
enum RenderSyntheticScreenshots {
    static func main() {
        do {
            try run()
        } catch {
            fputs("screenshot renderer: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 2 else {
            throw SyntheticScreenshotError("usage: render-screenshots <output-directory>")
        }
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let outputDirectory = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let catalog = try SyntheticScreenshotCatalog.make()
        let documents = [
            ScreenshotDocument(
                fileName: SyntheticScreenshotCatalog.statusFileName,
                expectedWords: ["IDLE", "RUN", "ASK", "DONE", "FAIL"],
                view: AnyView(
                    SyntheticStatusOverview(fixtures: catalog.statusSnapshots)
                )
            ),
            ScreenshotDocument(
                fileName: SyntheticScreenshotCatalog.sessionsFileName,
                expectedWords: ["ASK", "FAIL", "DONE", "RETURN", "COPY"],
                view: AnyView(
                    SyntheticPanelScene(snapshot: catalog.sessionsSnapshot)
                )
            ),
            ScreenshotDocument(
                fileName: SyntheticScreenshotCatalog.healthFileName,
                expectedWords: [
                    "DEGRADED",
                    "EVENT",
                    "DELIVERY",
                    "COPY",
                    "FIX",
                    "RUN",
                    "IDLE"
                ],
                view: AnyView(
                    SyntheticPanelScene(snapshot: catalog.healthSnapshot)
                )
            )
        ]
        for document in documents {
            try render(document: document, outputDirectory: outputDirectory)
        }
        try writeManifest(catalog: catalog, outputDirectory: outputDirectory)
    }

    private static func render(
        document: ScreenshotDocument,
        outputDirectory: URL
    ) throws {
        let data = try pngData(for: document.view)
        try validateExpectedText(
            in: data,
            expectedWords: document.expectedWords
        )
        try data.write(
            to: outputDirectory.appendingPathComponent(document.fileName),
            options: Data.WritingOptions.atomic
        )
    }

    private static func pngData(for view: AnyView) throws -> Data {
        let hostingView = makeHostingView(view: view)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let representation = try bitmapRepresentation()
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        window.contentView = nil
        window.close()

        guard representation.pixelsWide == SyntheticScreenshotCatalog.pixelWidth,
              representation.pixelsHigh == SyntheticScreenshotCatalog.pixelHeight,
              let data = representation.representation(
                using: NSBitmapImageRep.FileType.png,
                properties: [:]
              ) else {
            throw SyntheticScreenshotError("could not encode fixed-size PNG")
        }
        return data
    }

    private static func validateExpectedText(
        in data: Data,
        expectedWords: [String]
    ) throws {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
              ) else {
            throw SyntheticScreenshotError("could not read rendered PNG")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let recognized = recognizedWords(observations: request.results ?? [])
        let missing = expectedWords.filter { !recognized.contains($0) }
        guard missing.isEmpty else {
            throw SyntheticScreenshotError(
                "rendered PNG is missing text anchors: \(missing.joined(separator: ", "))"
            )
        }
    }

    private static func recognizedWords(
        observations: [VNRecognizedTextObservation]
    ) -> Set<String> {
        let text = observations.compactMap {
            $0.topCandidates(1).first?.string
        }.joined(separator: " ")
        return Set(
            text.uppercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
    }

    private static func makeHostingView(
        view: AnyView
    ) -> NSHostingView<AnyView> {
        let rootView = AnyView(
            view
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, .dark)
                .frame(
                    width: SyntheticScreenshotCatalog.pointSize.width,
                    height: SyntheticScreenshotCatalog.pointSize.height
                )
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = CGRect(
            origin: .zero,
            size: SyntheticScreenshotCatalog.pointSize
        )
        return hostingView
    }

    private static func bitmapRepresentation() throws -> NSBitmapImageRep {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: SyntheticScreenshotCatalog.pixelWidth,
            pixelsHigh: SyntheticScreenshotCatalog.pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw SyntheticScreenshotError("could not create screenshot bitmap")
        }
        representation.size = SyntheticScreenshotCatalog.pointSize
        return representation
    }

    private static func writeManifest(
        catalog: SyntheticScreenshotCatalog,
        outputDirectory: URL
    ) throws {
        let object: [String: Any] = [
            "fixture_text": catalog.fixtureText.sorted(),
            "files": catalog.outputFileNames,
            "pixel_height": SyntheticScreenshotCatalog.pixelHeight,
            "pixel_width": SyntheticScreenshotCatalog.pixelWidth,
            "point_height": Int(SyntheticScreenshotCatalog.pointSize.height),
            "point_width": Int(SyntheticScreenshotCatalog.pointSize.width),
            "schema_version": 1,
            "session_ids": catalog.sessionIDs.sorted(),
            "states": catalog.stateNames,
            "synthetic": true
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: outputDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }
}

private struct ScreenshotDocument {
    let fileName: String
    let expectedWords: [String]
    let view: AnyView
}

@MainActor
private struct SyntheticStatusOverview: View {
    let fixtures: [SyntheticStatusSnapshot]

    var body: some View {
        VStack(spacing: 9) {
            Text("SYNTHETIC STATUS SIGNALS")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Color.white.opacity(0.82))
            statusRow(Array(fixtures.prefix(3)))
            statusRow(Array(fixtures.dropFirst(3)))
        }
        .padding(14)
        .frame(
            width: SyntheticScreenshotCatalog.pointSize.width,
            height: SyntheticScreenshotCatalog.pointSize.height
        )
        .background(screenshotBackground)
    }

    private func statusRow(
        _ rowFixtures: [SyntheticStatusSnapshot]
    ) -> some View {
        HStack(spacing: 12) {
            ForEach(rowFixtures) { fixture in
                SyntheticStatusCard(fixture: fixture)
            }
        }
    }
}

@MainActor
private struct SyntheticStatusCard: View {
    let label: String
    @StateObject private var model: NotchShellViewModel

    init(fixture: SyntheticStatusSnapshot) {
        label = fixture.label
        _model = StateObject(
            wrappedValue: NotchShellViewModel(snapshot: fixture.snapshot)
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            NotchShellView(model: model)
                .frame(width: 116, height: 38)
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(Color.white.opacity(0.58))
        }
        .frame(width: 116, height: 65)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

@MainActor
private struct SyntheticPanelScene: View {
    @StateObject private var model: NotchShellViewModel

    init(snapshot: NotchShellSnapshot) {
        _model = StateObject(
            wrappedValue: NotchShellViewModel(snapshot: snapshot)
        )
    }

    var body: some View {
        ZStack {
            screenshotBackground
            NotchShellView(model: model)
        }
        .frame(
            width: SyntheticScreenshotCatalog.pointSize.width,
            height: SyntheticScreenshotCatalog.pointSize.height
        )
    }
}

private var screenshotBackground: Color {
    return Color(
        nsColor: NSColor(
            srgbRed: 0.075,
            green: 0.082,
            blue: 0.094,
            alpha: 1
        )
    )
}
