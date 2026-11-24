import Foundation

/// Reads (and can close) the active tab of common Mac browsers via AppleScript.
/// The first call for each browser triggers macOS's "Doggo wants to control …" prompt.
enum BrowserBridge {
    struct Browser: Equatable {
        let bundleID: String
        let isChromium: Bool

        var selectedTab: String { isChromium ? "active tab" : "current tab" }
    }

    struct Tab {
        let browser: Browser
        let url: String
        let count: Int
        let id: String?
        let openIDs: Set<String>

        var host: String? { BrowserBridge.host(from: url) }

        func confirmsClosure(of previous: Tab) -> Bool {
            guard browser == previous.browser, count < previous.count, url != previous.url else { return false }
            if let id = previous.id, openIDs.count == count { return !openIDs.contains(id) }
            return true
        }
    }

    static func browser(for bundleID: String) -> Browser? {
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
             "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac":
            return Browser(bundleID: bundleID, isChromium: true)
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return Browser(bundleID: bundleID, isChromium: false)
        default: return nil
        }
    }

    private static var cache: [String: NSAppleScript] = [:]

    private static func run(_ source: String, cacheable: Bool = true) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = cache[source] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            if cacheable { cache[source] = s }
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    static func activeURL(_ browser: Browser) -> String? {
        let source = """
        tell application id "\(browser.bundleID)"
            with timeout of 2 seconds
                if (count of windows) > 0 then return URL of \(browser.selectedTab) of front window
            end timeout
        end tell
        """
        return run(source)?.stringValue
    }

    static func activeTab(_ browser: Browser) -> Tab? {
        let collectIDs = browser.isChromium ? """
        try
            set tabIDs to tabIDs & (id of every tab of aWindow)
        end try
        """ : ""
        let selectedID = browser.isChromium ? """
        try
            set currentID to id of theTab as text
        end try
        """ : ""
        let source = """
        tell application id "\(browser.bundleID)"
            with timeout of 2 seconds
                set totalTabs to 0
                set tabIDs to {}
                repeat with aWindow in windows
                    set totalTabs to totalTabs + (count of tabs of aWindow)
                    \(collectIDs)
                end repeat
                if (count of windows) is 0 then return {"", totalTabs, "", tabIDs}
                set theTab to \(browser.selectedTab) of front window
                set currentURL to URL of theTab
                if currentURL is missing value then set currentURL to ""
                set currentID to ""
                \(selectedID)
                return {currentURL, totalTabs, currentID, tabIDs}
            end timeout
        end tell
        """
        guard let result = run(source), let url = result.atIndex(1)?.stringValue,
              let count = result.atIndex(2)?.int32Value else { return nil }
        let id = result.atIndex(3)?.stringValue
        var openIDs: Set<String> = []
        if let ids = result.atIndex(4), ids.numberOfItems > 0 {
            for index in 1...ids.numberOfItems {
                if let value = ids.atIndex(index)?.stringValue { openIDs.insert(value) }
            }
        }
        return Tab(browser: browser, url: url, count: Int(count), id: id == "" ? nil : id, openIDs: openIDs)
    }

    static func redirectActiveTab(_ browser: Browser, from url: String) {
        changeActiveTab(browser, matching: url, command: "set URL of theTab to \"about:blank\"")
    }

    static func closeActiveTab(_ tab: Tab) {
        changeActiveTab(tab.browser, matching: tab.url, command: "close theTab")
    }

    private static func changeActiveTab(_ browser: Browser, matching url: String, command: String) {
        guard !url.isEmpty, !url.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return }
        let escapedURL = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(browser.bundleID)"
            with timeout of 2 seconds
                if (count of windows) is 0 then return
                set theTab to \(browser.selectedTab) of front window
                considering case
                    if URL of theTab is "\(escapedURL)" then \(command)
                end considering
            end timeout
        end tell
        """
        _ = run(source, cacheable: false)
    }

    /// "https://www.reddit.com/r/all" -> "reddit.com"
    static func host(from urlString: String) -> String? {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
