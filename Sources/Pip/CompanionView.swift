import SwiftUI
import AppKit

/// Shared look for the floating UI.
enum Theme {
    static let ink = Color(hex: 0x1F2124)
    static let muted = Color(hex: 0x6B6F76)
    static let faint = Color(hex: 0x8A8E95)
    static let field = Color(hex: 0xF4F4F2)
    static let line = Color(hex: 0xE8E8E5)
    static let paper = Color(hex: 0xFCF8F0)
    static let sage = Color(hex: 0x7D9C90)
    static let amber = Color(hex: 0xC08A52)
    static let amberText = Color(hex: 0x8A5F35)
    static let violet = Color(hex: 0x777AA6)
    static let trail = Color(hex: 0x3C776B)
    static let reportHighlight = Color(hex: 0xD3E6B9)
    static let reportGradient = LinearGradient(colors: [Color(hex: 0x305A49), Color(hex: 0x1C3C32)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct PillButton: View {
    var title: String
    var primary = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: primary ? .semibold : .regular))
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .foregroundStyle(primary ? Color.white : Theme.muted)
                .background(primary ? Theme.ink : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The dog and its menu, bubble, or panel.
struct CompanionView: View {
    @ObservedObject var state: AppState
    @ObservedObject var appearance: DogAppearance
    @ObservedObject var tracker: ActivityTracker
    @ObservedObject var dailyTodos: DailyTodos
    @ObservedObject var calendarEvents: CalendarEvents
    @ObservedObject var calendarSync: CalendarSync
    let moveDog: (NSPoint) -> Void
    var alignment: Alignment = .bottomTrailing
    @State private var petting: DogPetting?
    @State private var pettingIndex = 0
    @State private var idleStartedAt = Date()

    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 4
    /// Gap between the dogs and the dock buttons underneath them.
    static let dockSpacing: CGFloat = 8

    static func dockBlock(dock: CompanionDock?, itemCount: Int, eventCount: Int, showsSyncBanner: Bool) -> CGFloat {
        dockSpacing + DailyTodoDock.height(dock: dock, itemCount: itemCount, eventCount: eventCount, showsSyncBanner: showsSyncBanner)
    }

    private var dockBlock: CGFloat {
        let day = calendarEvents.selected
        let eventCount = calendarSync.events(on: day).count + calendarEvents.events(on: day).count
        return Self.dockBlock(dock: state.dock, itemCount: dailyTodos.items.count,
                              eventCount: eventCount, showsSyncBanner: !calendarSync.isAuthorized)
    }

    var body: some View {
        ZStack(alignment: alignment) {
            ZStack {
                overlayContent
                    .transition(.opacity.combined(with: .move(edge: overlayEdge)))
            }
            .padding(Edge.Set(overlayEdge), DogView.canvasSize.height + dockBlock + 6)
            .animation(.easeOut(duration: 0.2), value: state.overlay)
            dogStack
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, Self.verticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .onChange(of: appearance.visibleDogs.map(\.id)) { _, _ in petting = nil }
        .onChange(of: tracker.today.date) { _, _ in dailyTodos.rollIfNeeded() }
    }

    /// Dogs, then the switches underneath them. To-dos and the calendar open on request.
    private var dogStack: some View {
        let count = appearance.visibleDogs.count
        let width = DogView.groupSize(count: count).width
        let dockLeading = min(max(0, DogView.visualMidX(count: count) - DailyTodoDock.width / 2),
                              max(0, width - DailyTodoDock.width))
        return VStack(alignment: .leading, spacing: Self.dockSpacing) {
            dogs
                .overlay(alignment: .topLeading) {
                    FocusWalkProgress(tracker: tracker)
                        .padding(3)
                        .allowsHitTesting(false)
                }
                .overlay {
                    DogMouseArea(onClick: tapDog, onDrag: moveDog, onHover: updatePetting)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state.mood == .highFive ? "High five \(guideName)" : guideName)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { state.dogTapped() }
                .help(state.mood == .highFive ? "Click the raised paw for a high five." : "Click for Doggo’s menu. Hover by his ear to scratch.")
            DailyTodoDock(state: state, todos: dailyTodos, events: calendarEvents, calendarSync: calendarSync)
                .padding(.leading, dockLeading)
        }
        .frame(width: width, alignment: .leading)
    }

    private var overlayEdge: Edge { alignment.vertical == .bottom ? .bottom : .top }
    private var alignEdge: Edge.Set { alignment.horizontal == .trailing ? .trailing : .leading }

    private var guideName: String { appearance.guide.name }

    private var dogs: some View {
        let visible = appearance.visibleDogs
        let guide = appearance.guide.id
        let size = DogView.groupSize(count: visible.count)
        let idleSince = visible.count > 1 ? idleStartedAt : nil
        return ZStack(alignment: .bottomLeading) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, dog in
                let slot = DogView.slot(at: index, count: visible.count)
                companion(dog, index: index, scale: slot.scale, isGuide: guide == dog.id, idleSince: idleSince)
                    .offset(x: slot.offset.x, y: slot.offset.y)
                    .zIndex(slot.zIndex)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
    }

    private func companion(_ dog: DesktopDog, index: Int, scale: CGFloat, isGuide: Bool, idleSince: Date?) -> some View {
        let interactive = pettingIndex == index ? petting : nil
        let isPair = idleSince != nil
        let buddyPettingSince = (isPair && petting != nil && pettingIndex != index) ? petting?.started : nil
        let baseMood = isGuide ? state.mood : companionMood
        let baseChangedAt = isGuide ? state.moodChangedAt : (tracker.walk?.start ?? state.moodChangedAt)
        let mood = interactive != nil && baseMood != .highFive && baseMood != .celebrate ? .petting : baseMood
        let alternatePace = !isPair ? dog.id == DesktopDog.black.id : index > 0
        let side: DogMotion.PairSide = isPair ? (index == 0 ? .left : .right) : .single
        let motion = DogMotion(alternatePace: alternatePace, pairSide: side, idleSince: idleSince,
                               walkDelay: isGuide ? 0 : 0.75, reactionDelay: isGuide ? 0 : 0.45,
                               buddyPettingSince: buddyPettingSince)
        return DogView(mood: mood, moodChangedAt: mood == .petting ? (interactive?.started ?? baseChangedAt) : baseChangedAt,
                       bandana: bandana, hasTag: state.accessory == .brassTag, petting: interactive,
                       artwork: dog.artwork, scale: scale, motion: motion)
    }

    private var companionMood: Mood {
        if tracker.walk != nil { return .walking }
        switch state.mood {
        case .celebrate, .wag, .excited, .happy, .drowsy, .coverEyes, .stretch:
            return state.mood
        case .highFive, .fetch:
            return .wag
        case .bark, .alert:
            return .alert
        default:
            return .nap
        }
    }

    private func dogIndex(at x: CGFloat, count: Int) -> Int {
        count > 1 && x >= DogView.splitX(count: count) ? 1 : 0
    }

    private func tapDog(_ point: CGPoint) {
        let visible = appearance.visibleDogs
        let dog = visible[dogIndex(at: point.x, count: visible.count)]
        if state.mood != .highFive || dog.id == appearance.guide.id { state.dogTapped(dog.id) }
    }

    private func updatePetting(_ point: CGPoint?) {
        guard let point else { petting = nil; return }
        let count = appearance.visibleDogs.count
        let index = dogIndex(at: point.x, count: count)
        let slot = DogView.slot(at: index, count: count)
        let containerHeight = DogView.groupSize(count: count).height
        let dogTop = (containerHeight - DogView.canvasSize.height * slot.scale) + slot.offset.y
        let local = CGPoint(x: (point.x - slot.offset.x) / slot.scale,
                            y: (point.y - dogTop) / slot.scale)
        if index != pettingIndex {
            petting = nil
            pettingIndex = index
        }
        let now = Date()
        let scratch = DogView.earArea.contains(local) ? (petting?.scratchStarted ?? now) : nil
        petting = DogPetting(point: local, started: petting?.started ?? now, scratchStarted: scratch)
    }

    private var bandana: Color {
        state.accessory == .trailBandana ? Theme.trail : Theme.amber
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch state.overlay {
        case .none:
            EmptyView()
        case .bubble(let nudge):
            if nudge.goalStep != nil {
                goalBubble(nudge)
            } else {
                bubble(nudge).padding(alignEdge, 70)
            }
        case .menu:
            anchoredMenu
        case .panel(let page):
            ViewThatFits(in: .vertical) {
                PanelCard(state: state, page: page).fixedSize(horizontal: false, vertical: true)
                ScrollView { PanelCard(state: state, page: page) }
            }
            .padding(alignEdge, 4)
        }
    }

    private func bubble(_ nudge: Nudge, tail: NudgeBubble.Tail? = nil) -> some View {
        let bubble = NudgeBubble(nudge: nudge, tail: tail) { state.perform($0) }
        return ViewThatFits(in: .vertical) {
            bubble.fixedSize(horizontal: false, vertical: true)
            ScrollView { bubble }
        }
    }

    private func goalBubble(_ nudge: Nudge) -> some View {
        let dogs = appearance.visibleDogs
        let guide = dogs.firstIndex { $0.id == appearance.guide.id } ?? 0
        let dogsWidth = DogView.groupSize(count: dogs.count).width
        let width = max(dogsWidth, NudgeBubble.width)
        let groupOffset = alignment.horizontal == .trailing ? width - dogsWidth : 0
        let speaker = groupOffset + DogView.slot(at: guide, count: dogs.count).centerX
        let leading = min(width - NudgeBubble.width, max(0, speaker - NudgeBubble.width / 2))
        let tail = NudgeBubble.Tail(x: speaker - leading, edge: overlayEdge)
        return bubble(nudge, tail: tail)
            .frame(width: NudgeBubble.width)
            .offset(x: leading)
            .frame(width: width, alignment: .leading)
    }

    private var anchoredMenu: some View {
        let dogs = appearance.visibleDogs
        let index = dogs.firstIndex { $0.id == (state.menuDogID ?? appearance.guide.id) } ?? 0
        let width = DogView.groupSize(count: dogs.count).width
        let menuWidth: CGFloat = 148
        let center = DogView.slot(at: index, count: dogs.count).centerX
        let offset = min(width - menuWidth, max(0, center - menuWidth / 2))
        return MenuView(state: state, tracker: tracker, alignment: .center)
            .frame(width: menuWidth)
            .offset(x: offset)
            .animation(.easeInOut(duration: 0.18), value: index)
            .frame(width: width, alignment: .leading)
    }
}

private struct DogMouseArea: NSViewRepresentable {
    let onClick: (CGPoint) -> Void
    let onDrag: (NSPoint) -> Void
    let onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> MouseView { MouseView() }

    func updateNSView(_ view: MouseView, context: Context) {
        view.onClick = onClick
        view.onDrag = onDrag
        view.onHover = onHover
    }

    final class MouseView: NSView {
        var onClick: ((CGPoint) -> Void)?
        var onDrag: ((NSPoint) -> Void)?
        var onHover: ((CGPoint?) -> Void)?
        private var press: (pointer: NSPoint, dog: NSPoint)?
        private var isDragging = false
        private var hoverArea: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            hoverArea = nil
            let dogBody = bounds.insetBy(dx: 0, dy: 6).intersection(
                NSRect(x: 72, y: 0, width: bounds.width, height: bounds.height)
            )
            guard !dogBody.isEmpty else { return }
            let area = NSTrackingArea(rect: dogBody, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) { reportPointer(event) }
        override func mouseMoved(with event: NSEvent) { reportPointer(event) }
        override func mouseExited(with event: NSEvent) { onHover?(nil) }

        private func reportPointer(_ event: NSEvent) {
            guard press == nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            onHover?(CGPoint(x: point.x, y: bounds.height - point.y))
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            press = (window.convertPoint(toScreen: event.locationInWindow),
                     window.convertToScreen(convert(bounds, to: nil)).origin)
            isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let press else { return }
            // Screen coordinates stay stable while the panel itself moves.
            let pointer = NSEvent.mouseLocation
            let dx = pointer.x - press.pointer.x
            let dy = pointer.y - press.pointer.y
            guard isDragging || hypot(dx, dy) >= 4 else { return }
            if !isDragging { onHover?(nil) }
            isDragging = true
            onDrag?(NSPoint(x: press.dog.x + dx, y: press.dog.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            guard press != nil else { return }
            press = nil
            let point = convert(event.locationInWindow, from: nil)
            if !isDragging && bounds.contains(point) { onClick?(point) }
        }
    }
}

struct NudgeBubble: View {
    struct Tail {
        let x: CGFloat
        let edge: Edge
    }

    static let width: CGFloat = 280
    var nudge: Nudge
    var tail: Tail?
    var perform: (NudgeAction) -> Void

    var body: some View {
        let fill = tail == nil ? Color.white : Theme.paper
        VStack(alignment: .leading, spacing: 8) {
            Text(nudge.action).font(.system(size: 11).italic()).foregroundStyle(Theme.muted)
            Text(nudge.text).font(.system(size: 13)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                if let secondary = nudge.secondary {
                    PillButton(title: secondary.label) { perform(secondary.action) }
                }
                PillButton(title: nudge.primary.label, primary: true) { perform(nudge.primary.action) }
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                   bottomTrailingRadius: 4, topTrailingRadius: 16)
                .fill(fill)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        )
        .overlay(alignment: tail?.edge == .top ? .topLeading : .bottomLeading) {
            if let tail {
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: 16, y: 0))
                    path.addLine(to: CGPoint(x: 8, y: 8))
                    path.closeSubpath()
                }
                .fill(fill)
                .frame(width: 16, height: 8)
                .rotationEffect(.degrees(tail.edge == .top ? 180 : 0))
                .offset(x: tail.x - 8, y: tail.edge == .top ? -7 : 7)
                .allowsHitTesting(false)
            }
        }
    }
}

struct MenuView: View {
    @ObservedObject var state: AppState
    @ObservedObject var tracker: ActivityTracker
    var alignment: Alignment

    var body: some View {
        ViewThatFits(in: .vertical) {
            actions
            ScrollView { actions.frame(maxWidth: .infinity, alignment: alignment) }
        }
    }

    private var actions: some View {
        VStack(alignment: alignment.horizontal, spacing: 7) {
            if tracker.walk == nil {
                option("Walk me", dark: true) { state.startFocusWalk() }
            } else {
                option("End walk", dark: true) { state.endFocusWalk() }
            }
            option("Stretch break") { state.perform(.coachBreak) }
            option("Paste transcript") { state.startPaste() }
        }
    }

    private func option(_ title: String, dark: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: dark ? .semibold : .medium))
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .foregroundStyle(dark ? Color.white : Theme.ink)
                .background(Capsule().fill(dark ? Theme.ink : Color.white).shadow(color: .black.opacity(0.22), radius: 8, y: 4))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Switches under the dogs. The to-do list and calendar open only while selected.
struct DailyTodoDock: View {
    static let width: CGFloat = 210
    static let buttonHeight: CGFloat = 36
    static let buttonGap: CGFloat = 8
    static let rowHeight: CGFloat = 28
    static let maxRows = 4
    static let shadowRoom: CGFloat = 8
    static let maxEventRows = 3
    static let eventRowHeight: CGFloat = 36

    @ObservedObject var state: AppState
    @ObservedObject var todos: DailyTodos
    @ObservedObject var events: CalendarEvents
    @ObservedObject var calendarSync: CalendarSync
    @State private var draft = ""

    static func cardHeight(itemCount: Int) -> CGFloat {
        let rows = min(itemCount, maxRows)
        let list: CGFloat = rows == 0 ? 0 : 8 + CGFloat(rows) * rowHeight
        return 20 + 18 + list + 8 + 30
    }

    /// Month grid, then the selected day's date and its saved events.
    static func calendarCardHeight(eventCount: Int, showsSyncBanner: Bool) -> CGFloat {
        let rows = min(max(eventCount, 0), maxEventRows)
        let list: CGFloat = rows == 0 ? (8 + 18) : (8 + CGFloat(rows) * eventRowHeight)
        let banner: CGFloat = showsSyncBanner ? (8 + 26) : 0
        return 204 + 8 + 52 + list + 8 + 30 + banner
    }

    static func height(dock: CompanionDock?, itemCount: Int, eventCount: Int, showsSyncBanner: Bool) -> CGFloat {
        var total = buttonHeight
        switch dock {
        case .todos:
            total += buttonGap + cardHeight(itemCount: itemCount)
        case .calendar:
            total += buttonGap + calendarCardHeight(eventCount: eventCount, showsSyncBanner: showsSyncBanner)
        case nil:
            break
        }
        return total + shadowRoom
    }

    var body: some View {
        VStack(spacing: Self.buttonGap) {
            HStack(spacing: 6) {
                toolButton("To-do", systemImage: "checklist", on: state.dock == .todos) {
                    state.toggleDock(.todos)
                }
                .accessibilityHint(state.dock == .todos ? "Hides today’s to-dos" : "Shows today’s to-dos")
                toolButton("Calendar", systemImage: "calendar", on: state.dock == .calendar) {
                    state.toggleDock(.calendar)
                }
                .accessibilityHint(state.dock == .calendar ? "Hides the calendar" : "Shows the calendar")
            }
            if state.dock == .todos {
                card
            } else if state.dock == .calendar {
                DockCalendar(events: events, sync: calendarSync)
            }
        }
        .frame(width: Self.width)
        .padding(.bottom, Self.shadowRoom)
        .onAppear {
            todos.rollIfNeeded()
            if let pending = state.pendingTodoDraft {
                draft = pending
                state.pendingTodoDraft = nil
            }
        }
        .onChange(of: state.pendingTodoDraft) { _, pending in
            if let pending {
                draft = pending
                state.pendingTodoDraft = nil
            }
        }
    }

    private func toolButton(_ title: String, systemImage: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
            .foregroundStyle(on ? Color.white : Theme.ink)
            .background(Capsule().fill(on ? Theme.ink : Color.white).shadow(color: .black.opacity(0.22), radius: 8, y: 4))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "Shown" : "Hidden")
    }

    private var card: some View {
        let rows = min(todos.items.count, Self.maxRows)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            if rows > 0 {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(todos.items) { item in
                            todoRow(item)
                        }
                    }
                }
                .frame(height: CGFloat(rows) * Self.rowHeight)
                .scrollIndicators(.hidden)
            }
            addField
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        }
    }

    private func todoRow(_ item: DailyTodos.Item) -> some View {
        Button {
            let wasDone = item.done
            todos.toggle(item.id)
            if !wasDone {
                let allDone = !todos.items.isEmpty && todos.items.allSatisfy(\.done)
                state.todoCompleted(allDone: allDone)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? Theme.sage : Theme.faint)
                Text(item.title)
                    .strikethrough(item.done)
                    .lineLimit(1)
                    .foregroundStyle(item.done ? Theme.faint : Theme.ink)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.done ? "Done, \(item.title)" : item.title)
        .accessibilityHint(item.done ? "Marks this to-do as not done" : "Marks this to-do done")
    }

    private var addField: some View {
        HStack(spacing: 6) {
            DockField(text: $draft, placeholder: "Add a to-do", onSubmit: add)
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 22, height: 22)
                    .background(Theme.field, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Add to-do")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Theme.field, in: Capsule())
    }

    private func add() {
        let before = todos.items.count
        todos.add(draft)
        if todos.items.count != before { draft = "" }
    }
}

/// Month grid shown under the dogs while Calendar is selected.
private struct DockCalendar: View {
    @ObservedObject var events: CalendarEvents
    @ObservedObject var sync: CalendarSync
    @State private var month = Date()
    @State private var draft = ""

    private var calendar: Calendar { Calendar.current }
    private var syncedEvents: [CalendarSync.SyncedEvent] { sync.events(on: events.selected) }
    private var localEvents: [CalendarEvents.Event] { events.events(on: events.selected) }
    private var totalCount: Int { syncedEvents.count + localEvents.count }

    var body: some View {
        let rows = min(totalCount, DailyTodoDock.maxEventRows)
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                shiftButton("chevron.left", by: -1, label: "Previous month")
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                shiftButton("chevron.right", by: 1, label: "Next month")
            }
            .frame(height: 22)
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 16)
            .accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    dayCell(day)
                }
            }
            .frame(height: 130)
            dayHeader
            if rows > 0 {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(syncedEvents) { event in
                            syncedRow(event)
                        }
                        ForEach(localEvents) { event in
                            eventRow(event)
                        }
                    }
                }
                .frame(height: CGFloat(rows) * DailyTodoDock.eventRowHeight)
                .scrollIndicators(.hidden)
            } else {
                Text("Nothing planned.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
            }
            addField
            if !sync.isAuthorized {
                syncBanner
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        }
        .onAppear {
            sync.refreshAuthorizationStatus()
            sync.loadMonth(month)
        }
        .onChange(of: events.selected) { _, _ in draft = "" }
        .onChange(of: month) { _, next in sync.loadMonth(next) }
    }

    private var syncBanner: some View {
        Button {
            if sync.status == .denied { sync.openPrivacySettings() }
            else { sync.requestAccess() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text(sync.status == .denied ? "Allow Calendar in Settings" : "Sync Apple / Google Calendar")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.trail)
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
            .background(Theme.trail.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(events.selected.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14, alignment: .leading)
            Text(events.selected.formatted(.dateTime.month(.wide).day().year()))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
            Text(dayMeta)
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var dayMeta: String {
        if totalCount == 0 { return relativeDay }
        let plan = totalCount == 1 ? "1 event" : "\(totalCount) events"
        return "\(relativeDay) · \(plan)"
    }

    private var relativeDay: String {
        let start = calendar.startOfDay(for: events.selected)
        let today = calendar.startOfDay(for: Date())
        let days = calendar.dateComponents([.day], from: today, to: start).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case let n where n > 1: return "In \(n) days"
        default: return "\(-days) days ago"
        }
    }

    private var addField: some View {
        HStack(spacing: 6) {
            DockField(text: $draft, placeholder: sync.isAuthorized ? "Add event (e.g. 3pm Sync)" : "Add an event", onSubmit: add)
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 22, height: 22)
                    .background(Theme.field, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Save event")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Theme.field, in: Capsule())
    }

    private func add() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if sync.isAuthorized && sync.addEvent(trimmed, on: events.selected) {
            draft = ""
            return
        }
        let before = localEvents.count
        events.add(trimmed, on: events.selected)
        if events.events(on: events.selected).count != before { draft = "" }
    }

    private func syncedRow(_ event: CalendarSync.SyncedEvent) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(Color(hex: event.colorHex))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(event.timeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let url = event.meetingURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 20, height: 18)
                        .background(Theme.trail, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Join \(event.title)")
                .accessibilityLabel("Join \(event.title)")
            } else if event.isEditable {
                Button { _ = sync.removeEvent(event) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(event.title)")
            }
        }
        .frame(height: DailyTodoDock.eventRowHeight)
    }

    private func eventRow(_ event: CalendarEvents.Event) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(Theme.sage)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(event.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { events.remove(event.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(event.title)")
        }
        .frame(height: DailyTodoDock.eventRowHeight)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private var days: [Date?] {
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let count = calendar.range(of: .day, in: .month, for: start)?.count else { return Array(repeating: nil, count: 42) }
        let lead = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for offset in 0..<count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: start))
        }
        while cells.count < 42 { cells.append(nil) }
        return cells
    }

    private func shiftButton(_ symbol: String, by months: Int, label: String) -> some View {
        Button {
            if let next = calendar.date(byAdding: .month, value: months, to: month) { month = next }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 22, height: 22)
                .background(Theme.field, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let isToday = calendar.isDateInToday(day)
            let isSelected = calendar.isDate(day, inSameDayAs: events.selected)
            let dotColor: Color? = sync.dotColorHex(on: day).map { Color(hex: $0) }
                ?? (events.hasEvent(on: day) ? Theme.sage : nil)
            Button { events.selected = calendar.startOfDay(for: day) } label: {
                VStack(spacing: 1) {
                    Text(calendar.component(.day, from: day).formatted())
                        .font(.system(size: 11, weight: isToday || isSelected ? .semibold : .regular))
                        .foregroundStyle(isToday ? Color.white : Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16)
                        .background {
                            if isToday {
                                Circle().fill(Theme.ink).frame(width: 16, height: 16)
                            } else if isSelected {
                                Circle().strokeBorder(Theme.ink, lineWidth: 1).frame(width: 16, height: 16)
                            }
                        }
                    Circle()
                        .fill(dotColor ?? Color.clear)
                        .frame(width: 3, height: 3)
                }
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + (dotColor != nil ? ", has events" : ""))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 20)
        }
    }
}

/// Text field that can take keyboard focus inside the nonactivating dog panel.
private struct DockField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> DockTextField {
        let field = DockTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = NSColor(Theme.ink)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ field: DockTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            text.wrappedValue = (obj.object as? NSTextField)?.stringValue ?? ""
        }

        @objc func submit() { onSubmit() }
    }
}

private final class DockTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

struct PanelCard: View {
    @ObservedObject var state: AppState
    var page: PanelPage

    private var isActivityReport: Bool { page == .warden || page == .weeklyReport }

    var title: String {
        switch page {
        case .warden: return "Today so far"
        case .weeklyReport: return "Weekly report"
        case .accessories: return "Accessories"
        case .coach: return "Coach reminders"
        case .nextStep: return "What’s my next step?"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isActivityReport ? 12 : 14) {
            HStack(spacing: 8) {
                Button { state.overlay = .menu } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28).background(Theme.field, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Back")
                Text(title).font(.system(size: isActivityReport ? 17 : 14, weight: .semibold))
                Spacer()
                Button { state.overlay = .none } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.faint).frame(width: 28, height: 28)
                }.buttonStyle(.plain).accessibilityLabel("Close")
            }
            switch page {
            case .warden: WardenPanel(state: state, tracker: state.tracker)
            case .weeklyReport:
                if let report = state.report {
                    WeeklyReportPanel(report: report, changeWeek: { state.showWeeklyReport(previous: !report.isPrevious) },
                                      openWebsites: { state.perform(.openWebsites) })
                }
            case .accessories: AccessoriesPanel(state: state)
            case .coach: CoachPanel(state: state, tracker: state.tracker)
            case .nextStep: NextGoalStepPanel(state: state, book: state.goalBook)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background {
            RoundedRectangle(cornerRadius: 18).fill(isActivityReport ? Theme.paper : .white)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        }
        .foregroundStyle(Theme.ink)
    }
}
