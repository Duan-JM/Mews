import AppKit
import SwiftUI

@MainActor
final class SessionSwipeRowMarkerView: NSView {
    weak var inputRouter: SessionSwipeInputRouter?
    var request: SessionDismissalRequest?

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRegistration()
    }

    func updateRegistration() {
        guard window != nil,
              let inputRouter,
              let request else {
            inputRouter?.unregister(view: self)
            return
        }
        inputRouter.register(view: self, request: request)
    }
}

struct SessionSwipeRowMarker: NSViewRepresentable {
    let request: SessionDismissalRequest
    let inputRouter: SessionSwipeInputRouter

    func makeNSView(context: Context) -> SessionSwipeRowMarkerView {
        let view = SessionSwipeRowMarkerView()
        view.inputRouter = inputRouter
        view.request = request
        view.updateRegistration()
        return view
    }

    func updateNSView(
        _ view: SessionSwipeRowMarkerView,
        context: Context
    ) {
        view.inputRouter?.unregister(view: view)
        view.inputRouter = inputRouter
        view.request = request
        view.updateRegistration()
    }

    static func dismantleNSView(
        _ view: SessionSwipeRowMarkerView,
        coordinator: Void
    ) {
        view.inputRouter?.unregister(view: view)
    }
}
