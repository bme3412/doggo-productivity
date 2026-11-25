import SwiftUI
import AppKit
import Combine

@main
struct DoggoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Doggo lives in the floating panel and the menu bar.
        Settings { EmptyView() }
    }
}

/// Borderless, transparent, always-on-top panel that follows you across Spaces.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var panel: FloatingPanel!
    private var companionHost: NSHostingView<CompanionView>!
    private var dogOrigin: NSPoint?
    private var statusItem: NSStatusItem!
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var goalsWindow: NSWindow?
    private var myDogsWindow: NSWindow?
    private var websitesWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var collapseWork: DispatchWorkItem?

    private let compactSize = NSSize(width: 230, height: 124)
    private let expandedSize = NSSize(width: 450, height: 740)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        state = AppState()
        state.openLibraryWindow = { [weak self] in self?.showLibrary() }
        state.openSettingsWindow = { [weak self] in self?.showSettings() }
        state.openGoalsWindow = { [weak self] in self?.showGoals() }
        state.openMyDogsWindow = { [weak self] in self?.showMyDogs() }
        state.openWebsitesWindow = { [weak self] in self?.showWebsites() }

        panel = FloatingPanel()
        state.canShowGoalReminders = { [weak self] in self?.panel?.isVisible == true }
        companionHost = NSHostingView(rootView: CompanionView(state: state, appearance: state.appearance,
                                                               tracker: state.tracker, dailyTodos: state.dailyTodos,
                                                               calendarEvents: state.calendarEvents,
                                                               calendarSync: state.calendarSync) { [weak self] origin in
            self?.moveDog(to: origin)
        })
        companionHost.sizingOptions = []
        companionHost.wantsLayer = true
        companionHost.layer?.backgroundColor = .clear
        panel.contentView = companionHost
        place(expanded: false)
        panel.orderFrontRegardless()

        // Resize once AppState has committed the new overlay.
        state.$overlay
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] overlay in
                guard let self, self.state.overlay == overlay else { return }
                self.overlayChanged(overlay)
            }
            .store(in: &cancellables)

        state.appearance.objectWillChange
            .receive(on: RunLoop.main)
            .map { [weak self] in self?.state.appearance.visibleDogs.count }
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.place(expanded: self.state.overlay != .none)
            }
            .store(in: &cancellables)

        state.dailyTodos.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.place(expanded: self.state.overlay != .none)
            }
            .store(in: &cancellables)

        state.$dock
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.place(expanded: self.state.overlay != .none)
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            state.calendarEvents.$events.map { _ in () }.eraseToAnyPublisher(),
            state.calendarEvents.$selected.map { _ in () }.eraseToAnyPublisher(),
            state.calendarSync.$events.map { _ in () }.eraseToAnyPublisher(),
            state.calendarSync.$status.map { _ in () }.eraseToAnyPublisher()
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.place(expanded: self.state.overlay != .none)
            }
            .store(in: &cancellables)

        state.tracker.$today
            .map(\.date)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.state.dailyTodos.rollIfNeeded() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.place(expanded: self.state.overlay != .none)
            }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.state.wokeUp() }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.state.sessionBecameActive() }
            .store(in: &cancellables)
        Publishers.Merge(workspace.publisher(for: NSWorkspace.willSleepNotification),
                         workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.state.sessionBecameInactive() }
            .store(in: &cancellables)

        buildStatusItem()
        state.sessionBecameActive()

        if Prefs.apiKey == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, state.overlay == .none else { return }
                state.overlay = .bubble(Nudge(mood: .awake, action: "wakes up and stretches",
                                                    text: "Hi! I’m Doggo. Add your Anthropic API key in Settings so I can organize transcripts. Screen-time tracking works without it.",
                                                    primary: ("Open Settings", .openSettings),
                                                    secondary: ("Later", .dismiss)))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.tracker.save()
    }

    // MARK: - Panel sizing

    private func overlayChanged(_ overlay: Overlay) {
        collapseWork?.cancel()
        if overlay == .none {
            // Let the closing animation finish before shrinking the window.
            let work = DispatchWorkItem { [weak self] in self?.place(expanded: false) }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            place(expanded: true)
        }
    }

    private func moveDog(to origin: NSPoint) {
        dogOrigin = origin
        place(expanded: state.overlay != .none)
    }

    private func place(expanded: Bool) {
        guard let fallbackScreen = NSScreen.main ?? NSScreen.screens.first else { return }
        let graphic = DogView.groupSize(count: state.appearance.visibleDogs.count)
        let selectedDay = state.calendarEvents.selected
        let eventCount = state.calendarSync.events(on: selectedDay).count + state.calendarEvents.events(on: selectedDay).count
        let dock = CompanionView.dockBlock(dock: state.dock, itemCount: state.dailyTodos.items.count,
                                           eventCount: eventCount, showsSyncBanner: !state.calendarSync.isAuthorized)
        let horizontalInset = CompanionView.horizontalInset
        let verticalInset = CompanionView.verticalInset
        let fallback = fallbackScreen.visibleFrame
        let origin = dogOrigin ?? NSPoint(x: fallback.maxX - graphic.width - horizontalInset - 8,
                                          y: fallback.minY + verticalInset + dock + 6)
        let center = NSPoint(x: origin.x + graphic.width / 2, y: origin.y + graphic.height / 2)
        let visibleFrame = NSScreen.screens.first { $0.frame.contains(center) }?.visibleFrame ?? fallback
        let insetFrame = visibleFrame.insetBy(dx: horizontalInset, dy: verticalInset)
        // Keep the switches under the dogs, above the bottom of the screen.
        let graphicY = min(max(origin.y, insetFrame.minY + dock),
                           max(insetFrame.maxY - graphic.height, insetFrame.minY + dock))
        let dog = NSRect(x: min(max(origin.x, insetFrame.minX), insetFrame.maxX - graphic.width),
                         y: graphicY,
                         width: graphic.width, height: graphic.height)
            .insetBy(dx: -horizontalInset, dy: -verticalInset)

        // Grow the panel around the dog, using the other side when space runs out.
        let compactWidth = max(compactSize.width, graphic.width + 2 * horizontalInset)
        let stackHeight = graphic.height + 2 * verticalInset + dock
        let size: NSSize
        if expanded && state.overlay == .menu {
            size = NSSize(width: compactWidth, height: stackHeight + 138)
        } else if expanded {
            size = NSSize(width: expandedSize.width, height: expandedSize.height + dock)
        } else {
            size = NSSize(width: compactWidth, height: stackHeight)
        }
        let left = dog.maxX - visibleFrame.minX
        let right = visibleFrame.maxX - dog.minX
        let upRoom = visibleFrame.maxY - (dog.minY - dock)
        let downRoom = dog.maxY - visibleFrame.minY
        let growsLeft = left >= min(size.width, right)
        let growsUp = upRoom >= min(size.height, downRoom)
        let width = min(size.width, growsLeft ? left : right)
        let height = min(size.height, growsUp ? upRoom : downRoom)
        let alignment = Alignment(horizontal: growsLeft ? .trailing : .leading,
                                  vertical: growsUp ? .bottom : .top)
        if companionHost.rootView.alignment != alignment {
            companionHost.rootView.alignment = alignment
        }

        let frame = NSRect(x: growsLeft ? dog.maxX - width : dog.minX,
                           y: growsUp ? dog.minY - dock : dog.maxY - height,
                           width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Doggo")
        rebuildMenu()
        state.tracker.$walk.map { $0 != nil }.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildMenu() }
        }.store(in: &cancellables)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(item("Goals", #selector(openGoals), key: "g"))
        menu.addItem(item("Paste a transcript…", #selector(pasteTranscript), key: "v"))
        menu.addItem(item("Open library", #selector(openLibrary), key: "l"))
        menu.addItem(group("Screen Time", [
            item("Today", #selector(openWarden), key: "t"),
            item("Weekly report", #selector(openWeeklyReport)),
            item("Websites…", #selector(openWebsites)),
            .separator(),
            item(state.tracker.walk == nil ? "Walk me" : "End focus walk", #selector(toggleWalk))
        ]))
        menu.addItem(item("Coach reminders", #selector(openCoach)))
        menu.addItem(group("My Dogs", [
            item("Manage dogs…", #selector(openMyDogs)),
            item("Accessories", #selector(openAccessories))
        ]))
        menu.addItem(.separator())

        let demoItem = NSMenuItem(title: "Try a mood", action: nil, keyEquivalent: "")
        let demoMenu = NSMenu()
        for (title, kind) in [("Sigh", "sigh"), ("Fetch", "fetch"), ("Bark", "bark")] {
            let i = item(title, #selector(demo(_:)))
            i.representedObject = kind
            demoMenu.addItem(i)
        }
        demoMenu.addItem(.separator())
        demoMenu.addItem(item("Goal redirect", #selector(demoGoalRedirect)))
        demoMenu.addItem(.separator())
        for playKind in PairPlayKind.allCases {
            let playItem = item(playKind.title, #selector(demoPairPlay(_:)))
            playItem.representedObject = playKind.rawValue
            demoMenu.addItem(playItem)
        }
        demoItem.submenu = demoMenu
        menu.addItem(demoItem)

        menu.addItem(.separator())
        menu.addItem(item(panel.isVisible ? "Hide Doggo" : "Show Doggo", #selector(toggleVisible)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Doggo", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func group(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let group = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for item in items { submenu.addItem(item) }
        group.submenu = submenu
        return group
    }

    private func revealCompanion() {
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
        rebuildMenu()
    }

    private func openPanelFromPaw(_ page: PanelPage) {
        revealCompanion()
        state.overlay = .panel(page)
    }

    @objc private func pasteTranscript() { state.startPaste() }
    @objc private func openLibrary() { state.perform(.openLibrary) }
    @objc private func openGoals() { state.perform(.openGoals) }
    @objc private func openMyDogs() { state.perform(.openMyDogs) }
    @objc private func openWarden() { openPanelFromPaw(.warden) }
    @objc private func openWebsites() { state.perform(.openWebsites) }
    @objc private func openWeeklyReport() {
        revealCompanion()
        state.showWeeklyReport()
    }
    @objc private func openAccessories() { openPanelFromPaw(.accessories) }
    @objc private func openCoach() { openPanelFromPaw(.coach) }
    @objc private func openSettings() { state.perform(.openSettings) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleWalk() {
        if state.tracker.walk == nil { state.startFocusWalk() }
        else { state.endFocusWalk() }
    }

    @objc private func demo(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let kind = NudgeKind(rawValue: raw) { state.demo(kind) }
    }

    @objc private func demoGoalRedirect() {
        revealCompanion()
        state.demoGoalRedirect()
    }

    @objc private func demoPairPlay(_ sender: NSMenuItem) {
        revealCompanion()
        let kind = (sender.representedObject as? String).flatMap(PairPlayKind.init(rawValue:))
        state.triggerPairPlay(kind, force: true)
    }

    @objc private func toggleVisible() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        rebuildMenu()
    }

    // MARK: - Windows

    func showWebsites() {
        if websitesWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 545),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Doggo Websites"
            applyWindowPalette(to: window)
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 730, height: 390)
            window.contentView = NSHostingView(rootView: WebsitesView(tracker: state.tracker))
            window.center()
            websitesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        websitesWindow?.makeKeyAndOrderFront(nil)
    }

    func showLibrary() {
        if libraryWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Doggo Library"
            applyWindowPalette(to: w)
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 790, height: 490)
            w.contentView = NSHostingView(rootView: LibraryView(store: state.library, state: state))
            w.center()
            libraryWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    func showGoals() {
        if goalsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 770, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Doggo Goals"
            applyWindowPalette(to: w)
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 660, height: 440)
            w.contentView = NSHostingView(rootView: GoalsView(state: state, book: state.goalBook))
            w.center()
            goalsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        goalsWindow?.makeKeyAndOrderFront(nil)
    }

    func showMyDogs() {
        if myDogsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "My Dogs"
            applyWindowPalette(to: w)
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 660, height: 420)
            w.contentView = NSHostingView(rootView: MyDogsView(store: state.appearance))
            w.center()
            myDogsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        myDogsWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Doggo Settings"
            applyWindowPalette(to: w)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(state: state, calendarSync: state.calendarSync))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func applyWindowPalette(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(LibraryColors.paper)
    }
}
