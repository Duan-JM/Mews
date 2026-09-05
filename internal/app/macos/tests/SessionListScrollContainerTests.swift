import AppKit
import Foundation
import SwiftUI

extension MewsAppModelTests {
    static func testSessionListScrollContainer() throws {
        try testScrollConfiguration()
        try testDocumentUpdatePreservesIdentity()
        try testTallContentScrollsVertically()
    }

    private static func testScrollConfiguration() throws {
        let configuration = SessionListScrollConfiguration.activeSessions
        try scrollExpect(configuration.axis == .vertical, "active sessions should scroll vertically")
        try scrollExpect(
            !configuration.showsVerticalScroller && !configuration.showsHorizontalScroller,
            "active sessions should hide both scrollbars"
        )
        try scrollExpect(
            configuration.verticalElasticity == .automatic &&
                configuration.horizontalElasticity == .none,
            "active sessions should keep vertical elasticity without horizontal scrolling"
        )
        try scrollExpect(
            configuration.preservesScrollPositionOnUpdate &&
                configuration.preservesDocumentIdentityOnUpdate,
            "snapshot updates should preserve scroll state and AppKit view identity"
        )

        let scrollView = SessionListScrollView()
        try scrollExpect(!scrollView.hasVerticalScroller, "vertical scrollbar should be hidden")
        try scrollExpect(!scrollView.hasHorizontalScroller, "horizontal scrollbar should be hidden")
        try scrollExpect(
            scrollView.verticalScrollElasticity == .automatic &&
                scrollView.horizontalScrollElasticity == .none,
            "scroll view should configure vertical elasticity only"
        )
    }

    private static func testDocumentUpdatePreservesIdentity() throws {
        let scrollView = SessionListScrollView()
        let originalDocument = SessionListHostingView(
            rootView: ScrollTestContent(marker: "before")
        )
        try scrollExpect(
            originalDocument.acceptsFirstMouse(for: nil),
            "the nested hosting view should accept the first click"
        )
        scrollView.installDocumentView(originalDocument)
        let originalIdentity = ObjectIdentifier(originalDocument)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 17))
        let originalScrollOrigin = scrollView.contentView.bounds.origin
        scrollView.installDocumentView(originalDocument)
        let installedDocument = scrollView.documentView
        try scrollExpect(
            installedDocument.map(ObjectIdentifier.init) == originalIdentity,
            "reinstalling the same document should preserve its identity"
        )
        try scrollExpect(
            scrollView.updateDocumentView(with: ScrollTestContent(marker: "after")),
            "matching hosting content should update in place"
        )
        let updatedDocument = scrollView.hostedDocumentView as? NSHostingView<ScrollTestContent>
        try scrollExpect(
            updatedDocument?.rootView.marker == "after",
            "snapshot content should update the existing hosting view"
        )
        try scrollExpect(
            scrollView.contentView.bounds.origin == originalScrollOrigin,
            "snapshot content should preserve the scroll position"
        )
    }

    private static func testTallContentScrollsVertically() throws {
        let tallScrollView = SessionListScrollView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 84)
        )
        let tallDocument = NSHostingView(rootView: TallScrollTestContent())
        tallScrollView.installDocumentView(tallDocument)
        tallScrollView.layoutSubtreeIfNeeded()
        let documentHeight = tallDocument.frame.height
        let viewportHeight = tallScrollView.contentView.bounds.height
        try scrollExpect(
            documentHeight > viewportHeight,
            "tall session content should exceed the viewport"
        )
        tallScrollView.contentView.scroll(
            to: NSPoint(x: 0, y: documentHeight - viewportHeight)
        )
        tallScrollView.reflectScrolledClipView(tallScrollView.contentView)
        try scrollExpect(
            tallScrollView.contentView.bounds.origin.y > 0,
            "tall session content should scroll vertically"
        )
    }

    private static func scrollExpect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SessionListScrollTestFailure(message: message)
        }
    }
}

private struct ScrollTestContent: View {
    let marker: String

    var body: some View {
        Text(marker)
    }
}

private struct TallScrollTestContent: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { index in
                Text("Session \(index)")
                    .frame(height: 30)
            }
        }
    }
}

private struct SessionListScrollTestFailure: Error {
    let message: String
}
