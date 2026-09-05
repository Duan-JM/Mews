import AppKit
import SwiftUI

enum SessionListScrollAxis: Equatable {
    case vertical
}

enum SessionListScrollElasticity: Equatable {
    case automatic
    case none
}

struct SessionListScrollConfiguration: Equatable {
    let axis: SessionListScrollAxis
    let showsVerticalScroller: Bool
    let showsHorizontalScroller: Bool
    let verticalElasticity: SessionListScrollElasticity
    let horizontalElasticity: SessionListScrollElasticity
    let preservesScrollPositionOnUpdate: Bool
    let preservesDocumentIdentityOnUpdate: Bool

    static let activeSessions = SessionListScrollConfiguration(
        axis: .vertical,
        showsVerticalScroller: false,
        showsHorizontalScroller: false,
        verticalElasticity: .automatic,
        horizontalElasticity: .none,
        preservesScrollPositionOnUpdate: true,
        preservesDocumentIdentityOnUpdate: true
    )
}

final class SessionListScrollView: NSScrollView {
    private(set) var hostedDocumentView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    // Keep the AppKit event path open for the later gesture foundation.
    // swiftlint:disable:next unneeded_override
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
    }

    func installDocumentView(_ view: NSView) {
        guard hostedDocumentView !== view else {
            return
        }

        hostedDocumentView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        documentView = view
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.widthAnchor.constraint(equalTo: contentView.widthAnchor)
        ])
    }

    @discardableResult
    func updateDocumentView<Content: View>(with rootView: Content) -> Bool {
        guard let hostingView = hostedDocumentView as? NSHostingView<Content> else {
            return false
        }
        hostingView.rootView = rootView
        return true
    }

    private func configure() {
        let configuration = SessionListScrollConfiguration.activeSessions
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = configuration.showsVerticalScroller
        hasHorizontalScroller = configuration.showsHorizontalScroller
        autohidesScrollers = true
        verticalScrollElasticity = nsElasticity(configuration.verticalElasticity)
        horizontalScrollElasticity = nsElasticity(configuration.horizontalElasticity)
        scrollerStyle = .overlay
        contentView.drawsBackground = false
    }

    private func nsElasticity(
        _ elasticity: SessionListScrollElasticity
    ) -> NSScrollView.Elasticity {
        switch elasticity {
        case .automatic:
            return .automatic
        case .none:
            return .none
        }
    }
}

final class SessionListHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Nested hosting views must preserve click-through in the nonactivating panel.
        return true
    }
}

struct SessionListScrollContainer<Content: View>: NSViewRepresentable {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    func makeNSView(context: Context) -> SessionListScrollView {
        let scrollView = SessionListScrollView()
        let hostingView = SessionListHostingView(rootView: content())
        scrollView.installDocumentView(hostingView)
        return scrollView
    }

    func updateNSView(_ scrollView: SessionListScrollView, context: Context) {
        _ = scrollView.updateDocumentView(with: content())
    }
}
