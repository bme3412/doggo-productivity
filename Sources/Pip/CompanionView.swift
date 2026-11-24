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
    let moveDog: (NSPoint) -> Void
    var alignment: Alignment = .bottomTrailing
    @State private var petting: DogPetting?
    @State private var pettingIndex = 0
    @State private var idleStartedAt = Date()

    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 4

    var body: some View {
        ZStack(alignment: alignment) {
            ZStack {
                overlayContent
                    .transition(.opacity.combined(with: .move(edge: overlayEdge)))
            }
            .padding(Edge.Set(overlayEdge), DogView.canvasSize.height + 6)
            .animation(.easeOut(duration: 0.2), value: state.overlay)
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
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, Self.verticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .onChange(of: appearance.visibleDogs.map(\.id)) { _, _ in petting = nil }
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
                companion(dog, index: index, isGuide: guide == dog.id, idleSince: idleSince)
                    .offset(x: CGFloat(index) * DogView.companionSpacing)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
    }

    private func companion(_ dog: DesktopDog, index: Int, isGuide: Bool, idleSince: Date?) -> some View {
        let interactive = pettingIndex == index ? petting : nil
        let baseMood = isGuide ? state.mood : (tracker.walk == nil ? .nap : .walking)
        let baseChangedAt = isGuide ? state.moodChangedAt : tracker.walk?.start ?? idleStartedAt
        let mood = interactive != nil && baseMood != .highFive && baseMood != .celebrate ? .petting : baseMood
        let alternatePace = idleSince == nil ? dog.id == DesktopDog.black.id : index > 0
        let motion = DogMotion(alternatePace: alternatePace, idleSince: idleSince, walkDelay: isGuide ? 0 : 0.75)
        return DogView(mood: mood, moodChangedAt: mood == .petting ? (interactive?.started ?? baseChangedAt) : baseChangedAt,
                       bandana: bandana, hasTag: state.accessory == .brassTag, petting: interactive,
                       artwork: dog.artwork, motion: motion)
    }

    private func dogIndex(at x: CGFloat, count: Int) -> Int {
        count > 1 && x >= DogView.canvasSize.width ? 1 : 0
    }

    private func tapDog(_ point: CGPoint) {
        let visible = appearance.visibleDogs
        let dog = visible[dogIndex(at: point.x, count: visible.count)]
        if state.mood != .highFive || dog.id == appearance.guide.id { state.dogTapped(dog.id) }
    }

    private func updatePetting(_ point: CGPoint?) {
        guard let point else { petting = nil; return }
        let index = dogIndex(at: point.x, count: appearance.visibleDogs.count)
        let local = CGPoint(x: point.x - CGFloat(index) * DogView.companionSpacing, y: point.y)
        if index != pettingIndex {
            petting = nil
            pettingIndex = index
        }
        let now = Date()
        let scratch = DogView.earArea.contains(local) ? (petting?.scratchStarted ?? now) : nil
        petting = DogPetting(point: local, started: petting?.started ?? now, scratchStarted: scratch)
    }

    private var bandana: Color {
        if state.accessory == .trailBandana { return Theme.trail }
        switch state.persona {
        case .archivist: return Theme.sage
        case .warden: return Theme.amber
        case .coach: return Theme.violet
        }
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
        let speaker = groupOffset + 135 + CGFloat(guide) * DogView.companionSpacing
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
        let center = 135 + CGFloat(index) * DogView.companionSpacing
        let offset = min(width - menuWidth, max(0, center - menuWidth / 2))
        return MenuView(state: state, tracker: tracker, book: state.goalBook, alignment: .center)
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
    @ObservedObject var book: GoalBook
    var alignment: Alignment

    var body: some View {
        ViewThatFits(in: .vertical) {
            actions
            ScrollView { actions.frame(maxWidth: .infinity, alignment: alignment) }
        }
    }

    private var actions: some View {
        let needsGoal = book.plans.isEmpty
        return VStack(alignment: alignment.horizontal, spacing: 7) {
            option(needsGoal ? "Set a goal" : "Next step") { state.perform(needsGoal ? .openGoals : .openNextStep) }
            roleAction
            personaButton
        }
    }

    @ViewBuilder
    private var roleAction: some View {
        switch state.persona {
        case .archivist:
            option("Paste transcript", dark: true) { state.startPaste() }
        case .warden:
            if tracker.walk == nil {
                option("Walk me", dark: true) { state.startFocusWalk() }
            } else {
                option("End walk", dark: true) { state.endFocusWalk() }
            }
        case .coach:
            option("Stretch break", dark: true) { state.perform(.coachBreak) }
        }
    }

    private var personaButton: some View {
        option(state.persona.title, showsCycle: true) { state.persona = state.persona.next }
            .help("Switch to \(state.persona.next.title)")
            .accessibilityLabel("Persona, \(state.persona.title)")
            .accessibilityHint("Switches to \(state.persona.next.title)")
    }

    private func option(_ title: String, dark: Bool = false, showsCycle: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if showsCycle {
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 13, weight: dark ? .semibold : .medium))
            .frame(width: showsCycle ? 92 : nil)
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .foregroundStyle(dark ? Color.white : Theme.ink)
            .background(Capsule().fill(dark ? Theme.ink : Color.white).shadow(color: .black.opacity(0.22), radius: 8, y: 4))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
