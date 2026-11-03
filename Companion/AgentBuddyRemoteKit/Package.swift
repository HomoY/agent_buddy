// swift-tools-version:5.9
import Foundation
import PackageDescription

/// Agent Buddy Remote's screens are kept off GitHub with the rest of the iPhone
/// and Apple Watch app, so a copy from there builds without them.
let hasRemoteUI = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Sources/AgentBuddyRemoteUI")

// Shared by Agent Buddy on the Mac, which publishes, and Agent Buddy Remote on iPhone
// and Apple Watch, which reads.
let package = Package(
    name: "AgentBuddyRemoteKit",
    platforms: [.iOS(.v16), .watchOS(.v9), .macOS(.v13)],
    products: [
        // The status format, pairing links, reminder tags and the ntfy client.
        .library(name: "AgentBuddyRemoteKit", targets: ["AgentBuddyRemoteKit"]),
        // Agents' answers drawn from Markdown, formulas and code boxes too: on the Mac and the iPhone.
        .library(name: "AgentBuddyMarkdown", targets: ["AgentBuddyMarkdown"]),
    ] + (hasRemoteUI ? [
        // Agent Buddy Remote's screens, its store and the iPhone-to-Watch hand-over.
        .library(name: "AgentBuddyRemoteUI", targets: ["AgentBuddyRemoteUI"]),
    ] : []),
    targets: [
        .target(name: "AgentBuddyRemoteKit"),
        // The page that draws an answer, with KaTeX, marked and highlight.js, bundled.
        .target(name: "AgentBuddyMarkdown", resources: [.copy("Web")]),
    ] + (hasRemoteUI ? [
        .target(name: "AgentBuddyRemoteUI", dependencies: [
            "AgentBuddyRemoteKit",
            // Apple Watch has no WebKit.
            .target(name: "AgentBuddyMarkdown", condition: .when(platforms: [.iOS, .macOS])),
        ]),
    ] : [])
)
