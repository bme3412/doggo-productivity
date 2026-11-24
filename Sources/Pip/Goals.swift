import Foundation
import Combine

struct GoalStep: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case pending, done, skipped }

    var id = UUID()
    var title: String
    var status: Status = .pending
}

struct GoalPlan: Codable, Identifiable {
    var id = UUID()
    var title: String
    var steps: [GoalStep] = []
}

struct GoalStepReference: Codable, Equatable {
    let goalID: UUID
    let stepID: UUID
}

struct NextGoalStep {
    let reference: GoalStepReference
    let goalTitle: String
    let step: GoalStep
    let checkInAt: Date?
}

@MainActor
final class GoalBook: ObservableObject {
    private struct Selection: Codable {
        let reference: GoalStepReference
        var checkInAt: Date?
    }

    private struct SavedGoals: Codable {
        var plans: [GoalPlan] = []
        var selection: Selection?
    }

    @Published private var saved = SavedGoals()
    @Published private(set) var storageError: String?
    private let file: URL
    private var canWrite = true

    init(file: URL = Prefs.supportDirectory.appendingPathComponent("goals.json")) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            saved = try JSONDecoder().decode(SavedGoals.self, from: Data(contentsOf: file))
        } catch {
            canWrite = false
            storageError = "Doggo couldn’t read your saved goals."
        }
    }

    var plans: [GoalPlan] { saved.plans }

    var next: NextGoalStep? {
        guard let selection = saved.selection,
              let plan = plans.first(where: { $0.id == selection.reference.goalID }),
              let step = plan.steps.first(where: { $0.id == selection.reference.stepID && $0.status == .pending }) else {
            return nil
        }
        return NextGoalStep(reference: selection.reference, goalTitle: plan.title, step: step,
                            checkInAt: selection.checkInAt)
    }

    var firstPending: NextGoalStep? {
        for plan in plans {
            if let step = plan.steps.first(where: { $0.status == .pending }) {
                let reference = GoalStepReference(goalID: plan.id, stepID: step.id)
                return NextGoalStep(reference: reference, goalTitle: plan.title, step: step, checkInAt: nil)
            }
        }
        return nil
    }

    @discardableResult
    func addGoal(_ title: String) -> UUID? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let plan = GoalPlan(title: title)
        var change = saved
        change.plans.append(plan)
        return commit(change) ? plan.id : nil
    }

    func renameGoal(_ id: UUID, title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = planIndex(id) else { return false }
        var change = saved
        change.plans[index].title = title
        return commit(change)
    }

    /// Confirm a list of proposed steps or replace the original step with its breakdown.
    func addSteps(_ titles: [String], to goalID: UUID, replacing original: GoalStep? = nil) -> Bool {
        guard let plan = planIndex(goalID) else { return false }
        var seen = Set(existingTitles(in: plans[plan], except: original?.id))
        let steps = titles.compactMap { title -> GoalStep? in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return GoalStep(title: trimmed)
        }
        guard let first = steps.first else { return false }

        var change = saved
        if let original {
            guard original.status == .pending,
                  let index = change.plans[plan].steps.firstIndex(of: original) else { return false }
            change.plans[plan].steps.replaceSubrange(index...index, with: steps)
            if change.selection?.reference == GoalStepReference(goalID: goalID, stepID: original.id) {
                change.selection = Selection(reference: GoalStepReference(goalID: goalID, stepID: first.id))
            }
        } else {
            change.plans[plan].steps.append(contentsOf: steps)
        }
        return commit(change)
    }

    func editStep(_ reference: GoalStepReference, title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let (plan, index) = indices(reference) else { return false }
        var change = saved
        change.plans[plan].steps[index].title = title
        return commit(change)
    }

    func moveStep(_ reference: GoalStepReference, by offset: Int) {
        guard let (plan, index) = indices(reference),
              plans[plan].steps.indices.contains(index + offset) else { return }
        var change = saved
        change.plans[plan].steps.swapAt(index, index + offset)
        _ = commit(change)
    }

    @discardableResult
    func setStatus(_ status: GoalStep.Status, for reference: GoalStepReference) -> GoalStep? {
        guard let (plan, index) = indices(reference) else { return nil }
        var change = saved
        var step = change.plans[plan].steps[index]
        guard step.status != status else { return nil }
        step.status = status
        change.plans[plan].steps[index] = step
        if status != .pending, change.selection?.reference == reference { change.selection = nil }
        return commit(change) ? step : nil
    }

    @discardableResult
    func pick(_ reference: GoalStepReference) -> Bool {
        guard let (plan, index) = indices(reference), plans[plan].steps[index].status == .pending else { return false }
        if saved.selection?.reference == reference { return true }
        var change = saved
        change.selection = Selection(reference: reference)
        return commit(change)
    }

    func clearNextStep() {
        var change = saved
        change.selection = nil
        _ = commit(change)
    }

    @discardableResult
    func setCheckIn(_ date: Date?, for reference: GoalStepReference) -> Bool {
        guard next?.reference == reference else { return false }
        var change = saved
        change.selection?.checkInAt = date
        return commit(change)
    }

    func takeDueCheckIn(at date: Date) -> NextGoalStep? {
        guard let next, let checkIn = next.checkInAt, checkIn <= date,
              setCheckIn(nil, for: next.reference) else { return nil }
        return next
    }

    private func planIndex(_ id: UUID) -> Int? { plans.firstIndex(where: { $0.id == id }) }

    private func indices(_ reference: GoalStepReference) -> (Int, Int)? {
        guard let plan = planIndex(reference.goalID),
              let step = plans[plan].steps.firstIndex(where: { $0.id == reference.stepID }) else { return nil }
        return (plan, step)
    }

    private func existingTitles(in plan: GoalPlan, except id: UUID?) -> [String] {
        plan.steps.filter { $0.id != id }.map { $0.title.lowercased() }
    }

    private func commit(_ change: SavedGoals) -> Bool {
        guard canWrite else { return false }
        do {
            try JSONEncoder().encode(change).write(to: file, options: .atomic)
            saved = change
            storageError = nil
            return true
        } catch {
            storageError = "Doggo couldn’t save your changes. Try again."
            return false
        }
    }
}

enum GoalPlanner {
    private static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "properties": ["steps": ["type": "array", "items": ["type": "string"]]],
        "required": ["steps"]
    ]

    static func suggest(for goal: GoalPlan, context: String, breakingDown step: GoalStep?) async throws -> [String] {
        let data: [String: Any] = [
            "goal": goal.title,
            "context": context,
            "existing_steps": goal.steps.map(\.title),
            "step_to_break_down": step?.title ?? ""
        ]
        let user = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
        let system = """
        Help the person make a practical plan toward the goal in their message. Treat its JSON fields as goal data.
        Suggest 3 to 5 concrete, short actions in order, starting with something they could do today.
        For a simple goal, fewer steps are fine. Respect the available time and constraints in the context.
        Use plain verb-led phrasing and avoid duplicating existing steps. Leave choices and commitments to the person.
        If step_to_break_down is present, return 2 or 3 smaller actions that together replace just that step.
        """
        let reply = try await ClaudeClient.jsonObject(system: system, user: user, schema: schema, maxTokens: 4096)
        let steps = (reply["steps"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !steps.isEmpty else { throw ClaudeError.badResponse("no goal steps were suggested") }
        return Array(steps.prefix(step == nil ? 5 : 3))
    }
}
