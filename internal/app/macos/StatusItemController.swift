import AppKit
import Foundation

@MainActor
final class StatusItemController: NSObject {
    private let statusBar: NSStatusBar
    private let statusItem: NSStatusItem
    private let workspace: NSWorkspace
    private var animationTimer: Timer?
    private var animationPlan: PixelStatusAnimationPlan?
    private var frameIndex = 0
    private var presentationState: MewsPresentationState?
    private var reduceMotion: Bool
    private var lastOneShotTransitionIdentifier: String?

    init(
        statusBar: NSStatusBar = .system,
        workspace: NSWorkspace = .shared
    ) {
        self.statusBar = statusBar
        self.workspace = workspace
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        super.init()

        configureButton()
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        animationTimer?.invalidate()
        workspace.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        statusBar.removeStatusItem(statusItem)
    }

    func update(state: MewsPresentationState, menu: NSMenu) {
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel(state.accessibilityLabel)

        let previousState = presentationState
        presentationState = state
        guard shouldApply(state: state, previousState: previousState) else {
            return
        }
        apply(state: state, keepOneShotStable: false)
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            return
        }
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
    }

    private func shouldApply(
        state: MewsPresentationState,
        previousState: MewsPresentationState?
    ) -> Bool {
        guard let previousState, previousState.status == state.status else {
            return true
        }
        if state.motion.isOneShot {
            return state.transitionIdentifier != lastOneShotTransitionIdentifier
        }
        return false
    }

    private func apply(
        state: MewsPresentationState,
        keepOneShotStable: Bool
    ) {
        stopAnimation()
        let plan = PixelStatusLogo.animationPlan(for: state, reduceMotion: reduceMotion)

        if state.motion.isOneShot {
            lastOneShotTransitionIdentifier = state.transitionIdentifier
        }
        let shouldKeepOneShotStable = keepOneShotStable && state.motion.isOneShot
        if reduceMotion || shouldKeepOneShotStable || plan.frameInterval == nil {
            render(frame: plan.stableFrame)
            return
        }

        animationPlan = plan
        frameIndex = 0
        render(frame: plan.frames[frameIndex])
        startAnimationTimer(interval: plan.frameInterval)
    }

    private func startAnimationTimer(interval: TimeInterval?) {
        guard let interval else {
            return
        }
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(animationTimerDidFire(_:)),
            userInfo: nil,
            repeats: true
        )
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func animationTimerDidFire(_ timer: Timer) {
        guard let plan = animationPlan else {
            stopAnimation()
            return
        }

        let nextIndex = frameIndex + 1
        if nextIndex < plan.frames.count {
            frameIndex = nextIndex
            render(frame: plan.frames[frameIndex])
            if !plan.repeats && frameIndex == plan.frames.count - 1 {
                stopAnimation()
            }
            return
        }

        if plan.repeats {
            frameIndex = 0
            render(frame: plan.frames[frameIndex])
        } else {
            stopAnimation()
        }
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        let updatedReduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        guard reduceMotion != updatedReduceMotion else {
            return
        }
        reduceMotion = updatedReduceMotion
        guard let presentationState else {
            return
        }
        apply(state: presentationState, keepOneShotStable: true)
    }

    private func render(frame: PixelFrame) {
        guard let button = statusItem.button else {
            return
        }
        button.title = ""
        button.image = PixelStatusLogoRenderer.image(for: frame)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationPlan = nil
        frameIndex = 0
    }
}
