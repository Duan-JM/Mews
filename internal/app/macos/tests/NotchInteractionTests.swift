import Foundation

extension MewsAppModelTests {
    static func testNotchInteractionPolicy() throws {
        try testLogoAndNotchClicks()
        try testHoverTimers()
        try testOutsideClick()
        try testHistoricalPresentationSync()
        try testNeedsInputPeek()
        try testTimedNotificationPeeks()
        try testNotificationPeekDeduplication()
        try testExpandedStatusUpdates()
        try testNotchMotionAndFallbackPolicy()
        try testStatusItemClickPolicy()
    }

    private static func testLogoAndNotchClicks() throws {
        var model = NotchInteractionModel(presentationState: MewsPresentationState(event: nil))

        _ = model.send(.logoPrimaryClick)
        try notchExpect(
            model.state.visibility == .expanded && model.state.openReason == .click,
            "a primary logo click should expand with a click reason"
        )
        _ = model.send(.logoPrimaryClick)
        try notchExpect(model.state.visibility == .closed, "a second primary logo click should close")

        _ = model.send(.notchClick(isPanelControl: false))
        try notchExpect(model.state.visibility == .expanded, "a closed notch click should expand")
        _ = model.send(.notchClick(isPanelControl: true))
        try notchExpect(
            model.state.visibility == .expanded,
            "a panel control inside the notch hit area should not toggle the shell"
        )
        _ = model.send(.notchClick(isPanelControl: false))
        try notchExpect(model.state.visibility == .closed, "a click-opened notch should close on click")

        let needsInput = MewsPresentationState(event: try notchEvent(status: "needs_input"))
        _ = model.send(.presentationChanged(needsInput))
        _ = model.send(.notchClick(isPanelControl: false))
        try notchExpect(
            model.state.visibility == .expanded && model.state.openReason == .click,
            "clicking a notification peek at the notch should expand it"
        )
        _ = model.send(.logoPrimaryClick)

        _ = model.send(.pointerMoved(isInsideNotch: true, isInsideInteractiveSurface: true))
        _ = model.send(.hoverOpenTimerFired)
        _ = model.send(.panelSurfaceClick(isPanelControl: true))
        try notchExpect(
            model.state.visibility == .expanded && model.state.openReason == .click,
            "clicking a control in a hover-opened panel should pin it without closing"
        )
    }

    private static func testHoverTimers() throws {
        var model = NotchInteractionModel(presentationState: MewsPresentationState(event: nil))
        let enterEffects = model.send(
            .pointerMoved(isInsideNotch: true, isInsideInteractiveSurface: true)
        )
        try notchExpect(
            enterEffects == [.scheduleHoverOpen(after: NotchInteractionTiming.hoverOpen)],
            "entering a physical notch should schedule the 450 ms hover delay"
        )
        try notchExpect(model.state.visibility == .closed, "hover should wait before expanding")

        let cancelEffects = model.send(
            .pointerMoved(isInsideNotch: false, isInsideInteractiveSurface: false)
        )
        try notchExpect(
            cancelEffects == [.cancelHoverOpen],
            "leaving the notch before 450 ms should cancel hover opening"
        )
        _ = model.send(.hoverOpenTimerFired)
        try notchExpect(model.state.visibility == .closed, "a cancelled hover timer should stay closed")

        _ = model.send(.pointerMoved(isInsideNotch: true, isInsideInteractiveSurface: true))
        _ = model.send(.hoverOpenTimerFired)
        try notchExpect(
            model.state.visibility == .expanded && model.state.openReason == .hover,
            "the hover timer should expand while the pointer remains in the notch"
        )

        let leaveEffects = model.send(
            .pointerMoved(isInsideNotch: false, isInsideInteractiveSurface: false)
        )
        try notchExpect(
            leaveEffects == [.scheduleHoverClose(after: NotchInteractionTiming.hoverClose)],
            "leaving a hover-opened surface should schedule the 250 ms grace period"
        )
        let reenterEffects = model.send(
            .pointerMoved(isInsideNotch: false, isInsideInteractiveSurface: true)
        )
        try notchExpect(
            reenterEffects == [.cancelHoverClose],
            "re-entering the panel during the grace period should cancel closing"
        )

        _ = model.send(.pointerMoved(isInsideNotch: false, isInsideInteractiveSurface: false))
        _ = model.send(.hoverCloseTimerFired)
        try notchExpect(model.state.visibility == .closed, "the expired hover grace should close")
    }

    private static func testOutsideClick() throws {
        var model = NotchInteractionModel(presentationState: MewsPresentationState(event: nil))
        _ = model.send(.logoPrimaryClick)
        _ = model.send(.outsideClick)
        try notchExpect(model.state.visibility == .closed, "an outside click should close expanded")

        let done = MewsPresentationState(event: try notchEvent(id: "outside-done", status: "done"))
        _ = model.send(.presentationChanged(done))
        _ = model.send(.outsideClick)
        try notchExpect(
            model.state.visibility == .peek,
            "an outside click should not dismiss a noninteractive notification peek"
        )
    }

    private static func testNeedsInputPeek() throws {
        var model = NotchInteractionModel(presentationState: MewsPresentationState(event: nil))
        let needsInput = MewsPresentationState(event: try notchEvent(status: "needs_input"))
        let effects = model.send(.presentationChanged(needsInput))

        try notchExpect(effects.isEmpty, "needs_input should not schedule automatic dismissal")
        try notchExpect(
            model.state.visibility == .peek && model.state.openReason == .notification,
            "needs_input should open a persistent notification peek"
        )
        try notchExpect(
            model.send(.presentationChanged(needsInput)).isEmpty,
            "an unchanged needs_input state should not reopen or restart its peek"
        )

        _ = model.send(.logoPrimaryClick)
        try notchExpect(
            model.state.visibility == .expanded && model.state.openReason == .click,
            "clicking a needs_input peek should expand it"
        )
        let running = MewsPresentationState(event: try notchEvent(status: "running"))
        _ = model.send(.presentationChanged(running))
        try notchExpect(
            model.state.visibility == .expanded,
            "running should not close a panel that the user explicitly expanded"
        )

        var automaticModel = NotchInteractionModel(
            presentationState: MewsPresentationState(event: nil)
        )
        _ = automaticModel.send(.presentationChanged(needsInput))
        let closeEffects = automaticModel.send(.presentationChanged(running))
        try notchExpect(
            closeEffects.isEmpty && automaticModel.state.visibility == .closed,
            "running should close an automatic needs_input peek without opening another surface"
        )
        let idle = MewsPresentationState(event: nil)
        try notchExpect(
            automaticModel.send(.presentationChanged(idle)).isEmpty &&
                automaticModel.state.visibility == .closed,
            "idle should not open a closed shell"
        )
    }

    private static func testHistoricalPresentationSync() throws {
        var needsInputModel = NotchInteractionModel(presentationState: MewsPresentationState(event: nil))
        let historicalNeedsInput = MewsPresentationState(
            event: try notchEvent(id: "historical-input", status: "needs_input")
        )
        try notchExpect(
            needsInputModel.send(.presentationSynchronized(historicalNeedsInput)).isEmpty,
            "historical needs_input state should synchronize without effects"
        )
        try notchExpect(
            needsInputModel.state.visibility == .closed &&
                needsInputModel.state.presentationState == historicalNeedsInput,
            "historical needs_input state should not replay a persistent peek"
        )

        var doneModel = NotchInteractionModel(presentationState: MewsPresentationState(event: nil))
        let historicalDone = MewsPresentationState(
            event: try notchEvent(id: "historical-done", status: "done")
        )
        _ = doneModel.send(.presentationSynchronized(historicalDone))
        try notchExpect(
            doneModel.state.visibility == .closed,
            "historical completion should synchronize without replaying its peek"
        )

        let running = MewsPresentationState(event: try notchEvent(status: "running"))
        _ = doneModel.send(.presentationChanged(running))
        try notchExpect(
            doneModel.send(.presentationChanged(historicalDone)).isEmpty &&
                doneModel.state.visibility == .closed,
            "a synchronized terminal transition should remain deduplicated"
        )

        var activePeekModel = NotchInteractionModel(presentationState: MewsPresentationState(event: nil))
        let liveDone = MewsPresentationState(
            event: try notchEvent(id: "live-done", status: "done")
        )
        _ = activePeekModel.send(.presentationChanged(liveDone))
        try notchExpect(
            activePeekModel.send(.presentationSynchronized(liveDone)).isEmpty &&
                activePeekModel.state.visibility == .peek,
            "a periodic silent sync should not shorten an active live peek"
        )

        let historicalEvent = try notchEvent(id: "history-event", status: "failed")
        try notchExpect(
            !notchTransitionIsNew(latestEvent: historicalEvent, newEvents: []),
            "the initial history scan should not announce a notch transition"
        )
        try notchExpect(
            notchTransitionIsNew(latestEvent: historicalEvent, newEvents: [historicalEvent]),
            "a newly appended latest primary event should announce a notch transition"
        )
    }

    private static func testTimedNotificationPeeks() throws {
        var doneModel = NotchInteractionModel(presentationState: MewsPresentationState(event: nil))
        let done = MewsPresentationState(event: try notchEvent(id: "done-1", status: "done"))
        let doneEffects = doneModel.send(.presentationChanged(done))
        let doneSequence = try notificationSequence(in: doneEffects)

        try notchExpect(
            doneEffects == [
                .scheduleNotificationPeek(
                    sequence: doneSequence,
                    after: NotchInteractionTiming.donePeek
                )
            ],
            "done should schedule a 2.5 second peek"
        )
        _ = doneModel.send(.notificationPeekTimerFired(sequence: doneSequence))
        try notchExpect(doneModel.state.visibility == .closed, "the done peek should expire")

        var failedModel = NotchInteractionModel(presentationState: MewsPresentationState(event: nil))
        let failed = MewsPresentationState(event: try notchEvent(id: "failed-1", status: "failed"))
        let failedEffects = failedModel.send(.presentationChanged(failed))
        let failedSequence = try notificationSequence(in: failedEffects)
        try notchExpect(
            failedEffects == [
                .scheduleNotificationPeek(
                    sequence: failedSequence,
                    after: NotchInteractionTiming.failedPeek
                )
            ],
            "failed should schedule a 4 second peek"
        )

        _ = failedModel.send(.logoPrimaryClick)
        _ = failedModel.send(.notificationPeekTimerFired(sequence: failedSequence))
        try notchExpect(
            failedModel.state.visibility == .expanded,
            "a stale automatic-peek timer should not close an explicitly expanded shell"
        )
    }

    private static func testNotificationPeekDeduplication() throws {
        var model = NotchInteractionModel(presentationState: MewsPresentationState(event: nil))
        let done = MewsPresentationState(event: try notchEvent(id: "same-done", status: "done"))
        _ = model.send(.presentationChanged(done))
        try notchExpect(
            model.send(.presentationChanged(done)).isEmpty,
            "an identical done transition should not restart its peek"
        )

        let running = MewsPresentationState(event: try notchEvent(status: "running"))
        _ = model.send(.presentationChanged(running))
        try notchExpect(
            model.send(.presentationChanged(done)).isEmpty,
            "a previously handled done transition should remain deduplicated"
        )
        try notchExpect(model.state.visibility == .closed, "a deduplicated done event should stay closed")

        let failed = MewsPresentationState(event: try notchEvent(id: "same-failed", status: "failed"))
        _ = model.send(.presentationChanged(failed))
        _ = model.send(.presentationChanged(running))
        try notchExpect(
            model.send(.presentationChanged(failed)).isEmpty,
            "a previously handled failed transition should remain deduplicated"
        )
    }

    private static func testExpandedStatusUpdates() throws {
        var model = NotchInteractionModel(presentationState: MewsPresentationState(event: nil))
        _ = model.send(.logoPrimaryClick)

        for (id, status) in [
            ("expanded-done", "done"),
            ("expanded-failed", "failed"),
            ("expanded-running", "running"),
            ("expanded-idle", "idle")
        ] {
            let presentation = MewsPresentationState(
                event: try notchEvent(id: id, status: status)
            )
            try notchExpect(
                model.send(.presentationChanged(presentation)).isEmpty,
                "expanded status updates should not schedule automatic peeks"
            )
            try notchExpect(
                model.state.visibility == .expanded && model.state.openReason == .click,
                "an explicitly expanded shell should survive \(status)"
            )
        }
    }

    private static func testNotchMotionAndFallbackPolicy() throws {
        try notchExpect(
            NotchShellTransitionStyle.resolved(reduceMotion: false) == .spatial,
            "standard motion should allow spatial shell transitions"
        )
        try notchExpect(
            NotchShellTransitionStyle.resolved(reduceMotion: true) == .opacityOnly,
            "Reduce Motion should select non-spatial shell transitions"
        )
        let standardContrast = NotchContrastPalette.resolved(increaseContrast: false)
        let increasedContrast = NotchContrastPalette.resolved(increaseContrast: true)
        try notchExpect(
            increasedContrast.metadataText > standardContrast.metadataText &&
                increasedContrast.separator > standardContrast.separator &&
                increasedContrast.disabledText > standardContrast.disabledText,
            "Increase Contrast should strengthen secondary text, separators, and disabled controls"
        )
        try notchExpect(
            !NotchPanelPresentationPolicy.isVisible(
                visibility: .closed,
                placementMode: .topCenter
            ),
            "top-center fallback should stay fully hidden while closed"
        )
        try notchExpect(
            NotchPanelPresentationPolicy.isVisible(
                visibility: .peek,
                placementMode: .topCenter
            ),
            "top-center fallback should become visible for a peek"
        )
        try notchExpect(
            !NotchPanelPresentationPolicy.acceptsMouseEvents(visibility: .peek),
            "peek should remain noninteractive"
        )
        try notchExpect(
            NotchPanelPresentationPolicy.acceptsMouseEvents(visibility: .expanded),
            "expanded should accept panel interaction"
        )
    }

    private static func testStatusItemClickPolicy() throws {
        try notchExpect(
            StatusItemClickIntent.resolve(button: .primary, controlPressed: false) == .primaryAction,
            "plain primary clicks should toggle the shell"
        )
        try notchExpect(
            StatusItemClickIntent.resolve(button: .primary, controlPressed: true) == .contextMenu,
            "Control-click should open the context menu"
        )
        try notchExpect(
            StatusItemClickIntent.resolve(button: .secondary, controlPressed: false) == .contextMenu,
            "secondary clicks should open the context menu"
        )
    }

    private static func notificationSequence(
        in effects: [NotchInteractionEffect]
    ) throws -> Int {
        guard case let .scheduleNotificationPeek(sequence, _) = effects.first else {
            throw NotchInteractionTestFailure(message: "notification peek timer was not scheduled")
        }
        return sequence
    }

    private static func notchEvent(
        id: String? = nil,
        status: String
    ) throws -> MewsEvent {
        var object: [String: Any] = [
            "source": "copilot",
            "status": status,
            "agent_scope": "main",
            "timestamp": "2026-07-21T00:00:00Z"
        ]
        if let id {
            object["id"] = id
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MewsEvent.self, from: data)
    }

    private static func notchExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw NotchInteractionTestFailure(message: message)
        }
    }
}

private struct NotchInteractionTestFailure: Error {
    let message: String
}
