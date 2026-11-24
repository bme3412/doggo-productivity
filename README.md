# Doggo, an ambient dog copilot for your Mac

A small animated dog that lives in the bottom-right corner of your screen.

- **Companion:** wakes with a stretch, greets you on your first session of the day, and gets drowsy late at night. He perks up for a code editor, covers his eyes during long distractions, and wags when he notices you closed a distracting tab.
- **Warden:** tracks time online, sites visited and time per site. When you've been on a distracting site for a while, he **sighs** (15 min), wants to **play fetch** (20 min, "that was a 2-mile run") and finally **barks** and closes the tab (30 min). Thresholds, your running pace and the list of distracting sites are all in Settings.
- **Archivist** organizes transcripts into an overview, practical takeaways, timed sections, and to-dos. Review the summary before filing it in the **Library**, where you can also search by text, browse by topic, and ask questions with cited answers.
- **Coach:** checks in about posture, stretching, and water. He reminds you to stand every hour at your Mac and suggests a walk after two hours.

Everything is stored locally in `~/Library/Application Support/Pip/`. Doggo sends the relevant transcript or goal details to Anthropic when you ask him to organize a transcript, answer a library question, or suggest goal steps.

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode, or just the command-line tools: `xcode-select --install`
- An Anthropic API key (for the Archivist). Screen-time tracking works without one.

## Build and run

```bash
chmod +x build.sh
./build.sh
open Doggo.app
```

Move `Doggo.app` to `/Applications` to keep an installed copy. Add Doggo under System Settings › General › Login Items to start it at login.

## First run

1. A paw icon appears in the menu bar, and the dog appears in the bottom-right corner.
2. Open **Settings** from the paw menu and paste your API key. It's saved in your Keychain.
3. Switch to a browser. When macOS asks, allow Doggo to control the browser so he can read the active tab’s address. You can update that permission under System Settings › Privacy & Security › Automation › Doggo.
4. To see the moods without waiting 20 minutes: paw menu › **Try a mood** › Sigh / Fetch / Bark.

## Using it

- **Click either dog** for a menu above that dog with **Next step**, the current role’s action, and the role switch underneath. **Drag** the dogs to move them and **hover** to pet them. Linger behind an ear to scratch it.
- Open **My Dogs › Manage dogs** from the paw menu to choose Classic Doggo, the black dog, or both. You can also add up to two photos or crop two dogs from a shared photo and adjust their illustrations. When two dogs are on the desktop, choose which gives reminders and high fives. Photo processing and storage stay on your Mac.
- With two dogs on the desktop, each has its own idle routine and animation pace. The other dog joins a focus walk just after the guide.
- **Next step** shows your current goal step and links to **Goals**. **Set a goal** takes its place until you add a goal. You can also open **Goals** from the paw menu to write your own steps or ask Doggo for suggestions. Pick one next step and set a one-time check-in if you want one. Mark a step done and click the guide’s raised paw for a high five.
- **Personas** are available from the dog or paw menu. Click the current persona in the dog’s menu to cycle through Warden, Coach, and Archivist.
- **Walk me** in Warden or the paw menu’s **Screen Time** group starts a 25-minute focus walk. Doggo trots beside the countdown and redirects distracting active tabs in Chrome, Safari, Arc, Brave, or Edge with macOS Automation permission. You can end the walk early from either menu.
- The paw menu’s **Screen Time** group shows **Today** and the **Weekly report**. The report shows time online, top sites, your longest focus stretch, and the comparison with last week. Warden brings it on Sundays after 6 p.m. local time while you're at your Mac.
- Open **Screen Time › Websites** from the paw menu to compare visit counts and time spent. Search for a site, sort by visits or time, and select a site to see its daily breakdown. The Today and Weekly report panels also show visits for top sites.
- **Stretch break** in Coach resets your desk timer and gives Doggo a stretch. Find **Coach reminders** in the paw menu.
- **Focus goals** in Settings let you convert time on distracting sites into units you care about. For example, add French practice with Duolingo lessons at 20 minutes each. The weekly report also keeps the running comparison.
- Open **My Dogs › Accessories** from the paw menu to see your focus streak and wear earned items. A day counts after 25 minutes of tracked focus. The Trail bandana unlocks after 7 days in a row and the brass tag after 14. Doggo’s mood also changes with the balance of focus and distraction across the past week.
- Use **Paste transcript** in the Library, as the Archivist action, or from the paw menu. Press **Organize transcript**, review the title, summary, and topic, then **File transcript**.
- Choose **YouTube** when filing a video transcript. A public video link can fill in the channel, or you can type a name or choose an existing channel. Each channel has its own folder under **YouTube** in the sidebar. Use **Change folder** in the transcript’s actions menu to refile it.
- In the Library, timed captions read as paragraphs. Use **Jump to** or click a section timestamp to open the matching part of the transcript. Select text in either the summary or transcript and click **Highlight** to save it. Open **Highlights** to jump back to your selections.

## How the tracking works

Every 5 seconds Doggo checks the frontmost app. For supported browsers he asks for the active tab's URL and counts the time against that site. No input for 2 minutes counts as away. A distraction streak is time on sites in your distracting list, with a one-minute grace period for leaving. Focus time counts active time away from those sites. Reports use Monday through Sunday and read existing daily activity files. Focus stretches and accessory progress use focus data recorded by this version. Daily stats are saved as JSON in `~/Library/Application Support/Pip/activity/`.

Doggo counts a visit when he sees a site become active. Returning to a site after switching to another site or app, or after being away, counts again. Reloading or browsing consecutive pages on the same host continues the visit. Older activity files show time recorded before visit counting was added. A `+` marks a count that covers only part of the displayed time.

## Project layout

```
Sources/Pip/
  DoggoApp.swift        App entry, floating panel, menu-bar item, windows
  AppState.swift        Moods, nudges, persona, archivist draft
  DogView.swift         The animated dog (SwiftUI Canvas, 30 fps)
  DogAppearance.swift   Saved dog profiles, desktop selection, and guide
  DogPhotoImport.swift  Local photo recognition, cropping, and coat colors
  MyDogsView.swift      Photo review and illustration editing
  CompanionView.swift   Speech bubble, menu, panel shell
  Panels.swift          Warden stats, paste box, review form
  ActivityTracker.swift Screen-time tracking + streak thresholds
  FocusHistory.swift    Focus goals, streaks, weekly reports and Coach timings
  Goals.swift           Goal plans, next steps, check-ins, and Claude suggestions
  GoalsView.swift       Goal editing, suggestion review, and the next-step panel
  CompanionPanels.swift Walk progress, reports, accessories and Coach UI
  BrowserBridge.swift   AppleScript: read / close the active tab
  ClaudeClient.swift    Anthropic Messages API
  Transcript.swift      Record model + organize / answer prompts
  LibraryStore.swift    SQLite + FTS5 storage and search
  LibraryView.swift     Library browser, search, and questions
  TranscriptReader.swift Summary, timed transcript, and saved highlights
  TranscriptImportView.swift Paste, organize, review, and file a transcript
  SettingsView.swift    API key, thresholds, distracting sites
```

## Notes

- Each rebuild changes the ad-hoc signature, so macOS may ask again for Automation or Keychain access. Click Allow.
- The model defaults to `claude-sonnet-5-5`; change it in Settings.
- Search is keyword-based (SQLite FTS5).
