import AppKit

/// Display names for bundle IDs. iPhone apps usually aren't installed on the Mac, so we use a built-in
/// table, then any installed Mac app's name, then a tidied-up bundle id. Add your own overrides to the
/// archive's app_names table.
enum AppNames {
    static let known: [String: String] = [
        "com.apple.mobilesafari": "Safari",
        "com.apple.MobileSMS": "Messages",
        "com.apple.mobilemail": "Mail",
        "com.apple.mobilephone": "Phone",
        "com.apple.facetime": "FaceTime",
        "com.apple.camera": "Camera",
        "com.apple.mobileslideshow": "Photos",
        "com.apple.Maps": "Maps",
        "com.apple.Music": "Music",
        "com.apple.podcasts": "Podcasts",
        "com.apple.mobilenotes": "Notes",
        "com.apple.mobilecal": "Calendar",
        "com.apple.reminders": "Reminders",
        "com.apple.Preferences": "Settings",
        "com.apple.AppStore": "App Store",
        "com.apple.news": "News",
        "com.apple.weather": "Weather",
        "com.apple.mobiletimer": "Clock",
        "com.apple.calculator": "Calculator",
        "com.apple.Health": "Health",
        "com.apple.Fitness": "Fitness",
        "com.apple.DocumentsApp": "Files",
        "com.apple.shortcuts": "Shortcuts",
        "com.apple.tv": "TV",
        "com.apple.iBooks": "Books",
        "com.apple.Passbook": "Wallet",
        "com.apple.findmy": "Find My",
        "com.apple.Home": "Home",
        "com.apple.springboard": "Home Screen",
        "com.apple.InCallService": "Phone Call",
        "com.burbn.instagram": "Instagram",
        "com.burbn.barcelona": "Threads",
        "com.atebits.Tweetie2": "X",
        "com.reddit.Reddit": "Reddit",
        "com.linkedin.LinkedIn": "LinkedIn",
        "com.facebook.Facebook": "Facebook",
        "com.facebook.Messenger": "Messenger",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.zhiliaoapp.musically": "TikTok",
        "com.google.ios.youtube": "YouTube",
        "com.google.chrome.ios": "Chrome",
        "com.google.Gmail": "Gmail",
        "com.google.Maps": "Google Maps",
        "com.spotify.client": "Spotify",
        "com.netflix.Netflix": "Netflix",
        "ph.telegra.Telegraph": "Telegram",
        "org.whispersystems.signal": "Signal",
        "com.toyopagroup.picaboo": "Snapchat",
        "pinterest": "Pinterest",
        "com.hammerandchisel.discord": "Discord",
        "com.tinyspeck.chatlyio": "Slack",
        "com.microsoft.Office.Outlook": "Outlook",
        "com.microsoft.skype.teams": "Teams",
        "us.zoom.videomeetings": "Zoom",
        "com.amazon.Amazon": "Amazon",
        "com.ubercab.UberClient": "Uber",
        "com.openai.chat": "ChatGPT",
        "com.anthropic.claude": "Claude",
        "com.duolingo.DuolingoMobile": "Duolingo",
        "com.strava.stravaride": "Strava",
        "com.apple.PassbookUIService": "Wallet",
        "com.apple.Pages": "Pages",
        "com.google.calendar": "Google Calendar",
        "com.google.gemini": "Gemini",
        "com.audible.iphone": "Audible",
        "com.airbnb.app": "Airbnb",
    ]

    private static var cache: [String: String] = [:]

    static func displayName(for bundleID: String) -> String {
        if let n = known[bundleID] { return n }
        if let n = cache[bundleID] { return n }
        var name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
        } else {
            // com.example.CoolApp -> "CoolApp"; com.example.ios -> "Example"
            let parts = bundleID.split(separator: ".").map(String.init)
            let generic: Set<String> = ["ios", "iphone", "app", "mobile", "client", "prod", "production"]
            let candidate = parts.reversed().first { !generic.contains($0.lowercased()) } ?? bundleID
            name = candidate.prefix(1).uppercased() + candidate.dropFirst()
        }
        cache[bundleID] = name
        return name
    }
}
