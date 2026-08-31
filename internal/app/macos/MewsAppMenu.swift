import AppKit

@MainActor
extension MewsApp {
    func buildMenu(presentation: SessionPresentation) -> NSMenu {
        let menu = NSMenu()
        addHealth(presentation.health, to: menu)
        addSessions(presentation.menuRows, to: menu)
        addUnscopedEvents(to: menu)
        menu.addItem(NSMenuItem.separator())
        addApplicationCommands(to: menu)
        return menu
    }

    private func addHealth(
        _ health: RuntimeHealthPresentation?,
        to menu: NSMenu
    ) {
        guard let health else {
            return
        }
        menu.addItem(healthMenuItem(health))
        if let recovery = health.recovery {
            menu.addItem(
                copyMenuItem(
                    title: "Copy recovery for \(health.title)",
                    value: recovery
                )
            )
        }
        menu.addItem(NSMenuItem.separator())
    }

    private func addSessions(
        _ rows: [SessionPresentationRow],
        to menu: NSMenu
    ) {
        guard !rows.isEmpty else {
            menu.addItem(
                NSMenuItem(
                    title: "No active sessions",
                    action: nil,
                    keyEquivalent: ""
                )
            )
            return
        }
        for row in rows {
            menu.addItem(sessionMenuItem(for: row))
        }
        guard let row = rows.first(where: { $0.returnCommand != nil }),
              let command = row.returnCommand else {
            return
        }
        menu.addItem(
            copyMenuItem(
                title: "Copy \(row.sourceLabel) return command",
                value: command,
                keyEquivalent: "c"
            )
        )
    }

    private func addUnscopedEvents(to menu: NSMenu) {
        let unscopedEvents = events.reversed().filter {
            SessionIdentity(source: $0.source, sessionID: $0.sessionID) == nil
        }.prefix(3)
        guard !unscopedEvents.isEmpty else {
            return
        }
        menu.addItem(NSMenuItem.separator())
        for event in unscopedEvents {
            menu.addItem(eventMenuItem(for: event))
        }
    }

    private func addApplicationCommands(to menu: NSMenu) {
        let refresh = NSMenuItem(
            title: "Refresh",
            action: #selector(refreshClicked),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(
            title: "Quit Mews",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    private func sessionMenuItem(for row: SessionPresentationRow) -> NSMenuItem {
        guard let context = row.returnContext else {
            return NSMenuItem(
                title: "\(row.menuTitle) [return unavailable]",
                action: nil,
                keyEquivalent: ""
            )
        }
        let item = NSMenuItem(
            title: "\(row.menuTitle) [\(row.returnActionDescription.lowercased())]",
            action: #selector(openCLIContextClicked(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = CLIContextBox(context, identity: row.identity)
        item.setAccessibilityLabel(row.accessibilityLabel)
        return item
    }

    private func healthMenuItem(
        _ health: RuntimeHealthPresentation
    ) -> NSMenuItem {
        let additional = health.additionalCount > 0
            ? " +\(health.additionalCount)"
            : ""
        let item = NSMenuItem(
            title: "\(health.statusCode)  \(health.title)\(additional): \(health.message)",
            action: nil,
            keyEquivalent: ""
        )
        item.setAccessibilityLabel(health.accessibilityLabel)
        return item
    }

    private func eventMenuItem(for event: MewsEvent) -> NSMenuItem {
        guard let context = event.cliContext, context.isActionable() else {
            return NSMenuItem(title: event.summary, action: nil, keyEquivalent: "")
        }
        let item = NSMenuItem(
            title: "\(event.summary) [\(context.codexAppURL == nil ? "return to CLI" : "open in Codex")]",
            action: #selector(openCLIContextClicked(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = CLIContextBox(
            context,
            identity: SessionIdentity(source: event.source, sessionID: event.sessionID)
        )
        return item
    }

    private func copyMenuItem(
        title: String,
        value: String,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(copyReturnCommandClicked(_:)),
            keyEquivalent: keyEquivalent
        )
        item.target = self
        item.representedObject = value
        return item
    }

    @objc private func refreshClicked() {
        reloadEvents()
    }

    @objc private func openCLIContextClicked(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CLIContextBox else {
            appendAppLog("Menu item did not contain CLI context")
            return
        }
        acknowledgeAttention(identity: box.identity)
        contextOpener.open(box.payload)
    }

    @objc private func copyReturnCommandClicked(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else {
            appendAppLog("Menu item did not contain a return command")
            return
        }
        contextOpener.copy(command)
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
