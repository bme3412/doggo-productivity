import SwiftUI

struct GoalsView: View {
    let state: AppState
    @ObservedObject var book: GoalBook

    @State private var selection: UUID?
    @State private var newGoal = ""
    @State private var contexts: [UUID: String] = [:]
    @State private var edit: GoalTextEdit?
    @State private var linkEdit: GoalLinkEdit?
    @State private var proposal: GoalProposal?
    @State private var requesting = false
    @State private var requestError: String?

    private var selectedPlan: GoalPlan? {
        book.plans.first(where: { $0.id == selection }) ?? book.plans.first
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                sidebar
                if let plan = selectedPlan {
                    ScrollView {
                        planDetail(plan).frame(maxWidth: 680, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(plan.id)
                } else {
                    ContentUnavailableView("Set a goal", systemImage: "flag",
                                           description: Text("Start with something you want to do, like going for a run."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .doggoWindowCard()
                }
            }
            if let error = book.storageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(LibraryColors.paper)
        .tint(LibraryColors.accent)
        .onAppear { if selection == nil { selection = book.plans.first?.id } }
        .sheet(item: $edit) { editor in GoalTextEditor(edit: editor) }
        .sheet(item: $linkEdit) { editor in GoalLinkEditor(edit: editor) }
        .sheet(item: $proposal) { draft in
            GoalProposalEditor(proposal: draft) { steps in
                book.addSteps(steps, to: draft.goal.id, replacing: draft.original)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your goals").font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 12)
            HStack(spacing: 6) {
                TextField("New goal", text: $newGoal).textFieldStyle(.roundedBorder).onSubmit(addGoal)
                Button("Add", action: addGoal)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.trail)
                    .disabled(newGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            List(book.plans, selection: $selection) { plan in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title).lineLimit(2)
                        if plan.timeWindow != .anytime || plan.resolvedURL != nil {
                            HStack(spacing: 5) {
                                if plan.timeWindow != .anytime {
                                    Text(plan.timeWindow.title)
                                }
                                if plan.resolvedURL != nil {
                                    Image(systemName: "link")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "flag")
                        .foregroundStyle(selection == plan.id ? Color.primary : LibraryColors.accent)
                }
                .tag(plan.id)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 215)
        .doggoWindowCard()
    }

    private func planDetail(_ plan: GoalPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            planSummary(plan)
            redirectSettingsCard(plan)
            planningControls(plan)
            if !plan.steps.isEmpty { stepsCard(plan) }
            if let next = book.next, next.reference.goalID == plan.id {
                GoalCheckInEditor(book: book, next: next)
                    .id(next.reference.stepID)
                    .padding(14)
                    .doggoWindowCard()
            }
        }
    }

    private func redirectSettingsCard(_ plan: GoalPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Best time to suggest")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Picker("Best time to suggest", selection: Binding(
                    get: { plan.timeWindow },
                    set: { book.updateGoalSchedule(plan.id, timeWindow: $0) }
                )) {
                    ForEach(GoalTimeWindow.allCases) { window in
                        Text("\(window.title) (\(window.detail))").tag(window)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Action link")
                        .font(.system(size: 12, weight: .medium))
                    if let url = plan.resolvedURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label(GoalLink.displayLabel(for: url, customLabel: plan.linkLabel),
                                  systemImage: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(Theme.trail)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help(url.absoluteString)
                    } else {
                        Text("Optional URL Doggo links to in distraction bubbles (e.g. jobs board, workout, AI study guide).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button(plan.resolvedURL == nil ? "Add link" : "Edit link") {
                    linkEdit = GoalLinkEdit(
                        title: "Action link for \(plan.title)",
                        url: plan.actionURL ?? "",
                        label: plan.linkLabel ?? ""
                    ) { url, label in
                        book.updateGoalLink(plan.id, actionURL: url, linkLabel: label)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .doggoWindowCard()
    }

    private func planSummary(_ plan: GoalPlan) -> some View {
        VStack(spacing: 0) {
            DoggoWindowHeader {
                Text(plan.title).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if !plan.steps.isEmpty {
                    let done = plan.steps.filter { $0.status == .done }.count
                    let pending = plan.steps.filter { $0.status == .pending }.count
                    Text("\(done.formatted()) done")
                    Divider().frame(height: 12)
                    Text("\(pending.formatted()) to do")
                }
                Spacer(minLength: 8)
                Button("Rename") {
                    edit = GoalTextEdit(title: "Rename goal", text: plan.title) { title, _, _, _ in
                        book.renameGoal(plan.id, title: title)
                    }
                }
                .controlSize(.small)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(LibraryColors.shelf)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private func planningControls(_ plan: GoalPlan) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("Context for suggestions, e.g. I have ten minutes today", text: Binding(
                get: { contexts[plan.id, default: ""] }, set: { contexts[plan.id] = $0 }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder).lineLimit(1...4)

            HStack(spacing: 10) {
                Button("Suggest steps") { suggest(for: plan) }
                    .buttonStyle(.borderedProminent).tint(Theme.trail).disabled(requesting)
                Button("Add a step") {
                    edit = GoalTextEdit(title: "Add a step", text: "", includesEstimate: true, includesLink: true) { title, minutes, url, label in
                        book.addSteps([GoalStep(title: title, estimatedMinutes: minutes, actionURL: url, linkLabel: label)], to: plan.id)
                    }
                }
                if requesting { ProgressView().controlSize(.small).accessibilityLabel("Preparing suggestions") }
            }
            Text("Goal details go to Claude when you ask for suggestions.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = requestError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(14)
        .doggoWindowCard()
    }

    private func stepsCard(_ plan: GoalPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Steps").font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                Divider().padding(.horizontal, 14)
                stepRow(step, in: plan, index: index)
            }
        }
        .doggoWindowCard()
    }

    private func stepRow(_ step: GoalStep, in plan: GoalPlan, index: Int) -> some View {
        let ref = GoalStepReference(goalID: plan.id, stepID: step.id)
        let isNext = book.next?.reference == ref
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                if step.status == .pending { state.finishGoalStep(ref) }
                else { book.setStatus(.pending, for: ref) }
            } label: {
                Image(systemName: statusIcon(step.status))
                    .foregroundStyle(step.status == .done ? LibraryColors.accent : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(step.status == .pending ? "Mark \(step.title) done" : "Restore \(step.title)")

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).foregroundStyle(step.status == .pending ? .primary : .secondary)
                    .strikethrough(step.status == .done)
                    .fixedSize(horizontal: false, vertical: true)
                if isNext {
                    Label("Next step", systemImage: "pin.fill").font(.caption).foregroundStyle(LibraryColors.accent)
                } else if step.status == .skipped {
                    Text("Skipped").font(.caption).foregroundStyle(.secondary)
                }
                if let estimate = step.estimateLabel {
                    Text(estimate).font(.caption).foregroundStyle(.secondary)
                }
                if let url = step.resolvedURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(GoalLink.displayLabel(for: url, customLabel: step.linkLabel),
                              systemImage: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(Theme.trail)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(url.absoluteString)
                }
            }
            Spacer(minLength: 4)
            if step.status == .pending && !isNext {
                Button("Pick next") { book.pick(ref) }.controlSize(.small)
            }

            Menu {
                Button("Edit step") {
                    edit = GoalTextEdit(title: "Edit step", text: step.title, includesEstimate: true,
                                        includesLink: true, estimatedMinutes: step.estimatedMinutes,
                                        actionURL: step.actionURL ?? "", linkLabel: step.linkLabel ?? "") { title, minutes, url, label in
                        book.editStep(ref, title: title, estimatedMinutes: minutes, actionURL: url, linkLabel: label)
                    }
                }
                Button("Move up") { book.moveStep(ref, by: -1) }.disabled(index == 0)
                Button("Move down") { book.moveStep(ref, by: 1) }.disabled(index == plan.steps.count - 1)
                if step.status == .pending {
                    Button("Make smaller with Claude") { suggest(for: plan, step: step) }.disabled(requesting)
                    Button("Skip step") { book.setStatus(.skipped, for: ref) }
                } else {
                    Button("Restore step") { book.setStatus(.pending, for: ref) }
                }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("Options for \(step.title)")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isNext ? LibraryColors.accent.opacity(0.1) : .clear)
    }

    private func statusIcon(_ status: GoalStep.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func addGoal() {
        guard let id = book.addGoal(newGoal) else { return }
        selection = id
        newGoal = ""
    }

    private func suggest(for plan: GoalPlan, step: GoalStep? = nil) {
        guard !requesting else { return }
        requestError = nil
        requesting = true
        let context = contexts[plan.id, default: ""]
        Task {
            defer { requesting = false }
            do {
                let steps = try await GoalPlanner.suggest(for: plan, context: context, breakingDown: step)
                proposal = GoalProposal(goal: plan, original: step, steps: steps)
            } catch {
                requestError = error.localizedDescription
            }
        }
    }
}

private struct GoalTextEdit: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    var includesEstimate = false
    var includesLink = false
    var estimatedMinutes: Int?
    var actionURL = ""
    var linkLabel = ""
    let save: (String, Int?, String?, String?) -> Bool
}

private struct GoalTextEditor: View {
    @Environment(\.dismiss) private var dismiss
    let edit: GoalTextEdit
    @State private var text: String
    @State private var minutes: Int?
    @State private var actionURL: String
    @State private var linkLabel: String
    @State private var failed = false

    init(edit: GoalTextEdit) {
        self.edit = edit
        _text = State(initialValue: edit.text)
        _minutes = State(initialValue: edit.estimatedMinutes)
        _actionURL = State(initialValue: edit.actionURL)
        _linkLabel = State(initialValue: edit.linkLabel)
    }

    private var trimmedURL: String { actionURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var urlInvalid: Bool { edit.includesLink && !trimmedURL.isEmpty && GoalLink.normalizeURL(trimmedURL) == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(edit.title).font(.headline)
            TextField(edit.title, text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            if edit.includesEstimate {
                LabeledContent("Time estimate") { GoalEstimateField(minutes: $minutes) }
            }
            if edit.includesLink {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Action link (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("https://linkedin.com/jobs or study guide URL", text: $actionURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Button label (optional), e.g. Apply to new roles", text: $linkLabel)
                        .textFieldStyle(.roundedBorder)
                    if urlInvalid {
                        Text("Enter a valid web address like linkedin.com/jobs or https://…")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            if failed { Text("Doggo couldn’t save this change. Check the text and try again.").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if edit.save(text, minutes, trimmedURL.isEmpty ? nil : trimmedURL, linkLabel) { dismiss() }
                    else { failed = true }
                }
                .buttonStyle(.borderedProminent).tint(Theme.trail)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || urlInvalid)
            }
        }
        .frame(width: 380).padding(20)
        .background(LibraryColors.paper)
        .tint(LibraryColors.accent)
    }
}

private struct GoalLinkEdit: Identifiable {
    let id = UUID()
    let title: String
    let url: String
    let label: String
    let save: (String?, String?) -> Bool
}

private struct GoalLinkEditor: View {
    @Environment(\.dismiss) private var dismiss
    let edit: GoalLinkEdit
    @State private var url: String
    @State private var label: String
    @State private var failed = false

    init(edit: GoalLinkEdit) {
        self.edit = edit
        _url = State(initialValue: edit.url)
        _label = State(initialValue: edit.label)
    }

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var urlInvalid: Bool { !trimmedURL.isEmpty && GoalLink.normalizeURL(trimmedURL) == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(edit.title).font(.headline)
            TextField("https://www.linkedin.com/jobs", text: $url)
                .textFieldStyle(.roundedBorder)
            TextField("Short link label (optional), e.g. Apply to new jobs", text: $label)
                .textFieldStyle(.roundedBorder)
            if urlInvalid {
                Text("Enter a valid web address like linkedin.com/jobs or https://…")
                    .font(.caption).foregroundStyle(.red)
            }
            if failed {
                Text("Doggo couldn’t save this link. Try again.").foregroundStyle(.red)
            }
            HStack {
                if !edit.url.isEmpty {
                    Button("Remove link", role: .destructive) {
                        if edit.save(nil, nil) { dismiss() }
                        else { failed = true }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if edit.save(trimmedURL.isEmpty ? nil : trimmedURL, label) { dismiss() }
                    else { failed = true }
                }
                .buttonStyle(.borderedProminent).tint(Theme.trail)
                .keyboardShortcut(.defaultAction)
                .disabled(urlInvalid)
            }
        }
        .frame(width: 390).padding(20)
        .background(LibraryColors.paper)
        .tint(LibraryColors.accent)
    }
}

private struct GoalEstimateField: View {
    @Binding var minutes: Int?

    var body: some View {
        HStack(spacing: 4) {
            TextField("—", value: $minutes, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .accessibilityLabel("Estimated minutes")
                .help("Optional time estimate in minutes")
            Text("min").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

private struct GoalProposal: Identifiable {
    let id = UUID()
    let goal: GoalPlan
    let original: GoalStep?
    let steps: [GoalStep]
}

private struct GoalProposalEditor: View {
    @Environment(\.dismiss) private var dismiss
    let proposal: GoalProposal
    let apply: ([GoalStep]) -> Bool
    @State private var steps: [GoalStep]
    @State private var failed = false

    init(proposal: GoalProposal, apply: @escaping ([GoalStep]) -> Bool) {
        self.proposal = proposal
        self.apply = apply
        _steps = State(initialValue: proposal.steps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(proposal.original == nil ? "Review suggested steps" : "Review smaller steps").font(.headline)
            Text(proposal.original?.title ?? proposal.goal.title).foregroundStyle(.secondary)
            ForEach(steps.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    TextField("Suggested step \(index + 1)", text: $steps[index].title, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    GoalEstimateField(minutes: $steps[index].estimatedMinutes)
                }
            }
            Text("Edit the steps and time estimates before adding them.").font(.caption).foregroundStyle(.secondary)
            if failed { Text("Doggo couldn’t apply these steps. Check your current plan and try again.").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(proposal.original == nil ? "Add to plan" : "Replace step") {
                    if apply(steps) { dismiss() }
                    else { failed = true }
                }
                .buttonStyle(.borderedProminent).tint(Theme.trail)
                .keyboardShortcut(.defaultAction)
                .disabled(steps.allSatisfy { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
        .frame(width: 430).padding(20)
        .background(LibraryColors.paper)
        .tint(LibraryColors.accent)
    }
}

private struct GoalCheckInEditor: View {
    @ObservedObject var book: GoalBook
    let next: NextGoalStep
    @State private var date = Date().addingTimeInterval(30 * 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Next step check-in").font(.headline)
                Spacer()
                Button("Unpin next step") { book.clearNextStep() }
            }
            if let scheduled = next.checkInAt {
                HStack {
                    Text(scheduled.formatted(date: .abbreviated, time: .shortened))
                    Button("Cancel check-in") { book.setCheckIn(nil, for: next.reference) }
                }
            }
            HStack {
                DatePicker("Check in at", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .onAppear { if let scheduled = next.checkInAt, scheduled > Date() { date = scheduled } }
                Button(next.checkInAt == nil ? "Set check-in" : "Reschedule") {
                    book.setCheckIn(date, for: next.reference)
                }
                .disabled(date <= Date())
            }
            Text("Check-ins wait until you’re active and within the hours set under Goal reminders in Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NextGoalStepPanel: View {
    let state: AppState
    @ObservedObject var book: GoalBook

    var body: some View {
        let reminded = state.remindedGoalStep.flatMap { book.pendingStep(for: $0) }
        VStack(alignment: .leading, spacing: 10) {
            if let action = reminded ?? book.next ?? book.firstPending {
                Text(action.goalTitle).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text(action.step.title).font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let estimate = action.step.estimateLabel {
                    Text(estimate).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if let scheduled = action.checkInAt {
                    Text("Check-in \(scheduled.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                let plan = book.plans.first { $0.id == action.reference.goalID }
                if let url = action.step.resolvedURL ?? plan?.resolvedURL {
                    let custom = action.step.resolvedURL != nil ? action.step.linkLabel : plan?.linkLabel
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(GoalLink.displayLabel(for: url, customLabel: custom),
                              systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.trail)
                    }
                    .buttonStyle(.plain)
                    .help(url.absoluteString)
                }
                HStack(spacing: 6) {
                    PillButton(title: "Goals") { state.perform(.openGoals) }
                    Spacer()
                    if reminded != nil || book.next?.reference == action.reference {
                        PillButton(title: "Mark done", primary: true) { state.finishGoalStep(action.reference) }
                    } else {
                        PillButton(title: "Pick this step", primary: true) { book.pick(action.reference) }
                    }
                }
            } else {
                Text("Add a goal and choose a step to work on.").font(.system(size: 13))
                PillButton(title: "Open Goals", primary: true) { state.perform(.openGoals) }
            }
            if let error = book.storageError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
