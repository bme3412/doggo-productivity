import SwiftUI

struct SettingsView: View {
    @State private var apiKey = ""
    @State private var hasKey = Prefs.apiKey != nil
    @State private var model = Prefs.claudeModel
    @State private var sigh = Prefs.sighMinutes
    @State private var fetch = Prefs.fetchMinutes
    @State private var bark = Prefs.barkMinutes
    @State private var pace = Prefs.minutesPerMile
    @State private var domains = Prefs.distractingDomains.joined(separator: "\n")
    @State private var goals = Prefs.focusGoals
    @State private var goalReminders = Prefs.goalReminders
    @State private var saved = false

    var body: some View {
        Form {
            Section("Claude") {
                SecureField(hasKey ? "Key saved. Paste a new one to replace it" : "Anthropic API key (sk-ant-…)", text: $apiKey)
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
                TextField("Model", text: $model)
                Text("Get a key at console.anthropic.com. Doggo sends the content needed for transcript organization, library questions, or goal suggestions when you request that action.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Goal reminders") {
                Toggle("Suggest a step once a day", isOn: $goalReminders.automatic)
                reminderWindow("Weekdays", window: $goalReminders.weekdays)
                reminderWindow("Weekends", window: $goalReminders.weekends)
                Text("Choose the hours you’re available. Doggo waits for these hours for scheduled check-ins too. Set both times the same to skip those days.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Warden: when the dog reacts") {
                Stepper("Sigh after \(sigh) minutes", value: $sigh, in: 1...120)
                Stepper("Fetch after \(fetch) minutes", value: $fetch, in: 1...180)
                Stepper("Bark (closes the tab) after \(bark) minutes", value: $bark, in: 1...240)
                Stepper("Your running pace: \(Int(pace)) min per mile", value: $pace, in: 5...20, step: 1)
                Text("Times count continuous minutes on distracting sites. Leaving for less than a minute doesn’t reset the streak; 2 minutes with no keyboard or mouse does.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Distracting sites (one per line; subdomains count)") {
                TextEditor(text: $domains)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 140)
                Text("Walk me redirects distracting tabs in supported browsers for 25 minutes. Doggo needs Automation access to the browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Focus goals") {
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

            Section {
                HStack {
                    Text("For browser tracking, allow Doggo to control your browser when macOS asks. You can change this in System Settings › Privacy & Security › Automation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    if saved { Text("Saved").foregroundStyle(.secondary) }
                    Button("Save settings") { save() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
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
        Prefs.minutesPerMile = pace
        Prefs.goalReminders = goalReminders
        Prefs.distractingDomains = domains
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        Prefs.focusGoals = goals.map { row in
            FocusGoal(id: row.id, name: row.name.trimmingCharacters(in: .whitespacesAndNewlines),
                      units: row.units.trimmingCharacters(in: .whitespacesAndNewlines),
                      minutesPerUnit: max(1, row.minutesPerUnit))
        }.filter { !$0.name.isEmpty && !$0.units.isEmpty }
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
