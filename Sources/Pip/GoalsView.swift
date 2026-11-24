import SwiftUI

struct GoalsView: View {
    let state: AppState
    @ObservedObject var book: GoalBook

    @State private var selection: UUID?
    @State private var newGoal = ""
    @State private var contexts: [UUID: String] = [:]
    @State private var edit: GoalTextEdit?
    @State private var proposal: GoalProposal?
    @State private var requesting = false
    @State private var requestError: String?

    private var selectedPlan: GoalPlan? {
        book.plans.first(where: { $0.id == selection }) ?? book.plans.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                if let plan = selectedPlan {
                    ScrollView {
                        planDetail(plan).padding(24).frame(maxWidth: 680, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ContentUnavailableView("Set a goal", systemImage: "flag",
                                           description: Text("Start with something you want to do, like going for a run."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error = book.storageError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if selection == nil { selection = book.plans.first?.id } }
        .sheet(item: $edit) { editor in GoalTextEditor(edit: editor) }
        .sheet(item: $proposal) { draft in
            GoalProposalEditor(proposal: draft) { steps in
                book.addSteps(steps, to: draft.goal.id, replacing: draft.original)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("New goal", text: $newGoal).onSubmit(addGoal)
                Button("Add", action: addGoal)
                    .disabled(newGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding([.horizontal, .top], 12)
            List(book.plans, selection: $selection) { plan in
                Label(plan.title, systemImage: "flag").lineLimit(2).tag(plan.id)
            }
            .listStyle(.sidebar)
        }
        .frame(width: 215)
    }

    private func planDetail(_ plan: GoalPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Rename") {
                    edit = GoalTextEdit(title: "Rename goal", text: plan.title) { title, _ in
                        book.renameGoal(plan.id, title: title)
                    }
                }
            }

            TextField("Context for suggestions, e.g. I have ten minutes today", text: Binding(
                get: { contexts[plan.id, default: ""] }, set: { contexts[plan.id] = $0 }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder).lineLimit(1...4)

            HStack(spacing: 10) {
                Button("Suggest steps") { suggest(for: plan) }
                    .buttonStyle(.borderedProminent).disabled(requesting)
                Button("Add a step") {
                    edit = GoalTextEdit(title: "Add a step", text: "", includesEstimate: true) { title, minutes in
                        book.addSteps([GoalStep(title: title, estimatedMinutes: minutes)], to: plan.id)
                    }
                }
                if requesting { ProgressView().controlSize(.small).accessibilityLabel("Preparing suggestions") }
            }
            Text("Goal details go to Claude when you ask for suggestions.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = requestError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            if !plan.steps.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(step, in: plan, index: index)
                        if index < plan.steps.count - 1 { Divider() }
                    }
                }
            }
            if let next = book.next, next.reference.goalID == plan.id {
                Divider()
                GoalCheckInEditor(book: book, next: next).id(next.reference.stepID)
            }
        }
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
                    .foregroundStyle(step.status == .done ? Theme.trail : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(step.status == .pending ? "Mark \(step.title) done" : "Restore \(step.title)")

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).foregroundStyle(step.status == .pending ? .primary : .secondary)
                    .strikethrough(step.status == .done)
                    .fixedSize(horizontal: false, vertical: true)
                if isNext {
                    Label("Next step", systemImage: "pin.fill").font(.caption).foregroundStyle(Theme.trail)
                } else if step.status == .skipped {
                    Text("Skipped").font(.caption).foregroundStyle(.secondary)
                }
                if let estimate = step.estimateLabel {
                    Text(estimate).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if step.status == .pending && !isNext {
                Button("Pick next") { book.pick(ref) }.controlSize(.small)
            }

            Menu {
                Button("Edit step") {
                    edit = GoalTextEdit(title: "Edit step", text: step.title, includesEstimate: true,
                                        estimatedMinutes: step.estimatedMinutes) { title, minutes in
                        book.editStep(ref, title: title, estimatedMinutes: minutes)
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
        .padding(.vertical, 10)
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
    var estimatedMinutes: Int?
    let save: (String, Int?) -> Bool
}

private struct GoalTextEditor: View {
    @Environment(\.dismiss) private var dismiss
    let edit: GoalTextEdit
    @State private var text: String
    @State private var minutes: Int?
    @State private var failed = false

    init(edit: GoalTextEdit) {
        self.edit = edit
        _text = State(initialValue: edit.text)
        _minutes = State(initialValue: edit.estimatedMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(edit.title).font(.headline)
            TextField(edit.title, text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            if edit.includesEstimate {
                LabeledContent("Time estimate") { GoalEstimateField(minutes: $minutes) }
            }
            if failed { Text("Doggo couldn’t save this change. Check the text and try again.").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if edit.save(text, minutes) { dismiss() }
                    else { failed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 360).padding(20)
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
                .keyboardShortcut(.defaultAction)
                .disabled(steps.allSatisfy { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
        .frame(width: 430).padding(20)
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
