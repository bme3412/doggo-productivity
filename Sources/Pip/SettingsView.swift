import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var calendarSync: CalendarSync
    @State private var apiKey = ""
    @State private var hasKey = Prefs.apiKey != nil
    @State private var model = Prefs.claudeModel
    @State private var sigh = Prefs.sighMinutes
    @State private var fetch = Prefs.fetchMinutes
    @State private var bark = Prefs.barkMinutes
    @State private var redirectsEnabled = Prefs.distractionRedirectsEnabled
    @State private var visitInterval = Prefs.distractionVisitInterval
    @State private var minuteInterval = Prefs.distractionMinuteInterval
    @State private var cooldownMinutes = Prefs.distractionCooldownMinutes
    @State private var smartRedirects = Prefs.smartRedirectSuggestions
    @State private var pace = Prefs.minutesPerMile
    @State private var domains = Prefs.distractingDomains.joined(separator: "\n")
    @State private var goals = Prefs.focusGoals
    @State private var goalReminders = Prefs.goalReminders
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    goalRedirectSettings
                    goalReminderSettings
                    calendarSettings
                    claudeSettings
                    wardenSettings
                    coachSettings
                    siteSettings
                    focusGoalSettings
                }
                .padding(16)
            }
            saveBar
        }
        .labeledContentStyle(SettingsRowStyle())
        .textFieldStyle(.roundedBorder)
        .tint(LibraryColors.accent)
        .background(LibraryColors.paper)
        .frame(width: 520, height: 620)
    }

    private var goalRedirectSettings: some View {
        card("Goal redirects on distracting sites", highlighted: true) {
            LabeledContent("Suggest time-aware goal actions") {
                Toggle("Suggest time-aware goal actions", isOn: $redirectsEnabled)
                    .toggleStyle(.switch).labelsHidden()
            }
            if redirectsEnabled {
                Divider()
                LabeledContent("Every N distracting visits") {
                    Stepper("\(visitInterval) \(visitInterval == 1 ? "visit" : "visits")",
                            value: $visitInterval, in: 1...25)
                        .accessibilityLabel("Every \(visitInterval) distracting visits")
                }
                LabeledContent("Or every N wasted minutes") {
                    Stepper("\(minuteInterval) min", value: $minuteInterval, in: 5...120, step: 5)
                        .accessibilityLabel("Every \(minuteInterval) wasted minutes")
                }
                LabeledContent("Cooldown between bubbles") {
                    Stepper("\(cooldownMinutes) min", value: $cooldownMinutes, in: 1...60)
                        .accessibilityLabel("Cooldown \(cooldownMinutes) minutes")
                }
                Divider()
                LabeledContent("Tailor suggestions with Claude") {
                    Toggle("Tailor suggestions with Claude", isOn: $smartRedirects)
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            Text("Triggers on whichever daily threshold hits first — visits or total wasted minutes — alongside Warden’s continuous streak reminders. Uses your saved goal links and study library first, with optional Claude tailoring when an API key is set.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var goalReminderSettings: some View {
        card("Goal reminders") {
            LabeledContent("Suggest a step once a day") {
                Toggle("Suggest a step once a day", isOn: $goalReminders.automatic)
                    .toggleStyle(.switch).labelsHidden()
            }
            Divider()
            reminderWindow("Weekdays", window: $goalReminders.weekdays)
            reminderWindow("Weekends", window: $goalReminders.weekends)
            Text("Choose the hours you’re available. Doggo waits for these hours for scheduled check-ins too. Set both times the same to skip those days.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var claudeSettings: some View {
        card("Claude") {
            SecureField(hasKey ? "Paste a new key to replace the saved one" : "Anthropic API key (sk-ant-…)", text: $apiKey)
            HStack {
                Button("Save key") {
                    Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "anthropic")
                    apiKey = ""
                    hasKey = Prefs.apiKey != nil
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasKey {
                    Button("Remove key", role: .destructive) {
                        Keychain.set("", account: "anthropic")
                        hasKey = Prefs.apiKey != nil
                    }
                }
                Spacer()
                Text(hasKey ? "Key stored in your Keychain" : "No key yet").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            LabeledContent("Model") {
                TextField("Model", text: $model).labelsHidden().frame(width: 225)
            }
            Text("Get a key at console.anthropic.com. Doggo sends the content needed for transcript organization, library questions, or goal suggestions when you request that action.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var wardenSettings: some View {
        card("Warden reminders") {
            LabeledContent("Strictness") {
                Picker("Warden reminders", selection: $state.level) {
                    ForEach(Strictness.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 225)
            }
            Text(state.level.explanation)
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            reminderThreshold("Sigh after", minutes: $sigh, range: 1...120)
            reminderThreshold("Fetch after", minutes: $fetch, range: 1...180)
            reminderThreshold("Bark (closes the tab) after", minutes: $bark, range: 1...240)
            LabeledContent("Running pace") {
                Stepper("\(Int(pace)) min per mile", value: $pace, in: 5...20, step: 1)
                    .accessibilityLabel("Running pace in minutes per mile")
            }
            Text("Times count continuous minutes on distracting sites. Leaving for less than a minute keeps the streak. Two minutes without keyboard or mouse input resets it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var calendarSettings: some View {
        card("Calendar sync & assistant") {
            LabeledContent("macOS Calendar (iCloud / Google)") {
                if calendarSync.isAuthorized {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.trail)
                } else if calendarSync.status == .denied {
                    Button("Open Privacy Settings") { calendarSync.openPrivacySettings() }
                } else {
                    Button("Connect Calendar") { calendarSync.requestAccess() }
                }
            }
            Divider()
            LabeledContent("Meeting runway & post-meeting capture") {
                Toggle("Meeting runway & post-meeting capture", isOn: $state.calendarAssistant)
                    .toggleStyle(.switch).labelsHidden()
            }
            Text("Syncs any Google, iCloud, or Exchange calendars signed into macOS System Settings › Internet Accounts. Gives a morning schedule brief, 5-minute meeting heads-ups with join links, and quick follow-up capture after meetings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var coachSettings: some View {
        card("Coach reminders") {
            LabeledContent("Posture, stretch, and water check-ins") {
                Toggle("Posture, stretch, and water check-ins", isOn: $state.coachReminders)
                    .toggleStyle(.switch).labelsHidden()
            }
            Text("Doggo checks in while you’re at your Mac, reminds you to stand every hour, and suggests a walk after two hours.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reminderThreshold(_ title: String, minutes: Binding<Int>, range: ClosedRange<Int>) -> some View {
        LabeledContent(title) {
            Stepper("\(minutes.wrappedValue) min", value: minutes, in: range)
                .accessibilityLabel("\(title) \(minutes.wrappedValue) minutes")
        }
    }

    private var siteSettings: some View {
        card("Distracting sites") {
            Text("Enter one site per line. Matches include subdomains.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $domains)
                .accessibilityLabel("Distracting sites")
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(height: 140)
                .background(LibraryColors.shelf, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(LibraryColors.line).allowsHitTesting(false) }
            Text("Walk me redirects distracting tabs for 25 minutes in supported browsers. Manage browser access in System Settings › Privacy & Security › Automation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var focusGoalSettings: some View {
        card("Focus goals") {
            ForEach($goals) { $goal in
                let id = goal.id
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        TextField("Goal, e.g. French practice", text: $goal.name)
                        Button {
                            goals.removeAll { $0.id == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove goal")
                    }
                    HStack {
                        TextField("Units, e.g. Duolingo lessons", text: $goal.units)
                        TextField("Minutes", value: $goal.minutesPerUnit, format: .number.grouping(.never))
                            .frame(width: 52)
                        Text("min each").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Add a goal") { goals.append(FocusGoal()) }
        }
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(LibraryColors.line).frame(height: 1)
            HStack(spacing: 12) {
                Spacer()
                if saved {
                    Label("Saved", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(LibraryColors.accent)
                }
                Button("Save settings") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.trail)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .background(LibraryColors.shelf)
    }

    private func card<Content: View>(_ title: String, highlighted: Bool = false,
                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if highlighted {
                DoggoWindowHeader { Text(title) }
            } else {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .doggoWindowCard()
    }

    private func reminderWindow(_ title: String, window: Binding<GoalReminderSchedule.Window>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                DatePicker("\(title) start time", selection: timeBinding(window.start), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Text("to").foregroundStyle(.secondary).accessibilityHidden(true)
                DatePicker("\(title) end time", selection: timeBinding(window.end), displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            .controlSize(.small)
        }
    }

    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            let now = Date()
            return GoalReminderSchedule.date(at: minutes.wrappedValue, on: now, calendar: .current) ?? now
        } set: { date in
            minutes.wrappedValue = GoalReminderSchedule.minutes(at: date, calendar: .current)
        }
    }

    private func save() {
        Prefs.claudeModel = model.trimmingCharacters(in: .whitespaces)
        Prefs.sighMinutes = sigh
        Prefs.fetchMinutes = max(fetch, sigh)
        Prefs.barkMinutes = max(bark, fetch)
        Prefs.distractionRedirectsEnabled = redirectsEnabled
        Prefs.distractionVisitInterval = visitInterval
        Prefs.distractionMinuteInterval = minuteInterval
        Prefs.distractionCooldownMinutes = cooldownMinutes
        Prefs.smartRedirectSuggestions = smartRedirects
        Prefs.minutesPerMile = pace
        Prefs.goalReminders = goalReminders
        Prefs.distractingDomains = domains
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        state.tracker.syncRedirectMilestones()
        Prefs.focusGoals = goals.map { row in
            FocusGoal(id: row.id, name: row.name.trimmingCharacters(in: .whitespacesAndNewlines),
                      units: row.units.trimmingCharacters(in: .whitespacesAndNewlines),
                      minutesPerUnit: max(1, row.minutesPerUnit))
        }.filter { !$0.name.isEmpty && !$0.units.isEmpty }
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}

private struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}
