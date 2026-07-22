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
        for document in screenshotDocuments(catalog: catalog) {
            try render(document: document, outputDirectory: outputDirectory)
        }
        try writeManifest(catalog: catalog, outputDirectory: outputDirectory)
    }

    private static func screenshotDocuments(
        catalog: SyntheticScreenshotCatalog
    ) -> [ScreenshotDocument] {
        return [
            ScreenshotDocument(
                fileName: SyntheticScreenshotCatalog.statusFileName,
                expectedWords: ["IDLE", "RUN", "ASK", "DONE", "FAIL"],
                colorScheme: .dark,
                appearance: .darkAqua,
                view: AnyView(
                    SyntheticStatusOverview(fixtures: catalog.statusSnapshots)
                )
            ),
            ScreenshotDocument(
                fileName: SyntheticScreenshotCatalog.sessionsFileName,
                expectedWords: ["ASK", "FAIL", "DONE", "RETURN", "COPY"],
                colorScheme: catalog.sessionsPanel.colorScheme,
                appearance: appearanceName(
                    for: catalog.sessionsPanel.colorScheme
                ),
                view: AnyView(
                    SyntheticPanelScene(
                        snapshot: catalog.sessionsPanel.snapshot,
                        colorScheme: catalog.sessionsPanel.colorScheme
                    )
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
                colorScheme: catalog.healthPanel.colorScheme,
                appearance: appearanceName(
                    for: catalog.healthPanel.colorScheme
                ),
                view: AnyView(
                    SyntheticPanelScene(
                        snapshot: catalog.healthPanel.snapshot,
                        colorScheme: catalog.healthPanel.colorScheme
                    )
                )
            )
        ]
    }

    private static func appearanceName(
        for colorScheme: ColorScheme
    ) -> NSAppearance.Name {
        return colorScheme == .dark ? .darkAqua : .aqua
    }

    private static func render(
        document: ScreenshotDocument,
        outputDirectory: URL
    ) throws {
        let data = try pngData(
            for: document.view,
            colorScheme: document.colorScheme,
            appearance: document.appearance
        )
        try validateExpectedText(
            in: data,
            expectedWords: document.expectedWords
        )
        try data.write(
            to: outputDirectory.appendingPathComponent(document.fileName),
            options: Data.WritingOptions.atomic
        )
    }

    private static func pngData(
        for view: AnyView,
        colorScheme: ColorScheme,
        appearance: NSAppearance.Name
    ) throws -> Data {
        let hostingView = makeHostingView(
            view: view,
            colorScheme: colorScheme,
            appearance: appearance
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
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
        view: AnyView,
        colorScheme: ColorScheme,
        appearance: NSAppearance.Name
    ) -> NSHostingView<AnyView> {
        let rootView = AnyView(
            view
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, colorScheme)
                .frame(
                    width: SyntheticScreenshotCatalog.pointSize.width,
                    height: SyntheticScreenshotCatalog.pointSize.height
                )
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.appearance = NSAppearance(named: appearance)
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
            "appearances": catalog.appearanceNames,
            "placements": catalog.placementNames,
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
    let colorScheme: ColorScheme
    let appearance: NSAppearance.Name
    let view: AnyView
}

@MainActor
private struct SyntheticStatusOverview: View {
    let fixtures: [SyntheticStatusSnapshot]

    var body: some View {
        VStack(spacing: 9) {
            Text("SYNTHETIC NOTCH SIGNALS")
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
        .background(syntheticDesktopBackground(colorScheme: .dark))
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
    let colorScheme: ColorScheme
    @StateObject private var model: NotchShellViewModel

    init(fixture: SyntheticStatusSnapshot) {
        label = fixture.label
        colorScheme = fixture.colorScheme
        _model = StateObject(
            wrappedValue: NotchShellViewModel(snapshot: fixture.snapshot)
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            NotchShellView(model: model)
                .frame(width: 116, height: 38)
                .environment(\.colorScheme, colorScheme)
            Text("\(label) · \(appearanceLabel)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.35)
                .foregroundStyle(foreground.opacity(0.64))
        }
        .frame(width: 116, height: 65)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(foreground.opacity(0.12), lineWidth: 1)
        )
    }

    private var appearanceLabel: String {
        return colorScheme == .dark ? "DARK" : "LIGHT"
    }

    private var foreground: Color {
        return colorScheme == .dark
            ? .white
            : Color(red: 0.075, green: 0.082, blue: 0.094)
    }

    private var cardBackground: Color {
        return colorScheme == .dark
            ? Color.white.opacity(0.035)
            : Color.white.opacity(0.9)
    }
}

@MainActor
private struct SyntheticPanelScene: View {
    let colorScheme: ColorScheme
    @StateObject private var model: NotchShellViewModel

    init(snapshot: NotchShellSnapshot, colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
        _model = StateObject(
            wrappedValue: NotchShellViewModel(snapshot: snapshot)
        )
    }

    var body: some View {
        ZStack {
            syntheticDesktopBackground(colorScheme: colorScheme)
            NotchShellView(model: model)
                .environment(\.colorScheme, colorScheme)
        }
        .frame(
            width: SyntheticScreenshotCatalog.pointSize.width,
            height: SyntheticScreenshotCatalog.pointSize.height
        )
    }
}

@ViewBuilder
private func syntheticDesktopBackground(
    colorScheme: ColorScheme
) -> some View {
    let isDark = colorScheme == .dark
    ZStack {
        Color(
            red: isDark ? 0.055 : 0.78,
            green: isDark ? 0.063 : 0.84,
            blue: isDark ? 0.078 : 0.91
        )
        Circle()
            .fill(
                Color(
                    red: isDark ? 0.22 : 0.95,
                    green: isDark ? 0.32 : 0.67,
                    blue: isDark ? 0.46 : 0.48
                ).opacity(isDark ? 0.72 : 0.55)
            )
            .frame(width: 250, height: 250)
            .offset(x: -150, y: -70)
        RoundedRectangle(cornerRadius: 48)
            .fill(
                Color(
                    red: isDark ? 0.42 : 0.42,
                    green: isDark ? 0.2 : 0.7,
                    blue: isDark ? 0.18 : 0.86
                ).opacity(isDark ? 0.45 : 0.42)
            )
            .frame(width: 300, height: 150)
            .rotationEffect(.degrees(-14))
            .offset(x: 145, y: 80)
    }
}
