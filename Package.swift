// swift-tools-version:5.9
import Foundation
import PackageDescription

/// The iPhone and Apple Watch app's parts are kept off GitHub; where they're
/// here, the checks build and run their checks too (`#if PHONE_CHECKS`).
let hasPhoneParts = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Companion/AgentBuddyRemoteKit/Sources/AgentBuddyRemoteUI")
    && FileManager.default.fileExists(atPath: Context.packageDirectory + "/Sources/AgentBuddyChecks/PhoneChecks.swift")

let package = Package(
    name: "AgentBuddy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentBuddy", targets: ["AgentBuddy"]),
        .executable(name: "AgentBuddyChecks", targets: ["AgentBuddyChecks"]),
    ],
    dependencies: [
        // Shared with Agent Buddy Remote, the iPhone and Apple Watch app in Companion/.
        .package(path: "Companion/AgentBuddyRemoteKit"),
    ],
    targets: [
        // Quota readers, transcript trackers and the file watcher. No UI.
        .target(name: "AgentBuddyCore"),
        // The menu bar app.
        .executableTarget(name: "AgentBuddy", dependencies: [
            "AgentBuddyCore",
            .product(name: "AgentBuddyRemoteKit", package: "AgentBuddyRemoteKit"),
            // Answers in agent windows: Markdown with formulas and code boxes.
            .product(name: "AgentBuddyMarkdown", package: "AgentBuddyRemoteKit"),
        ]),
        // Self-checks: `swift run AgentBuddyChecks` (fixtures), `--live`, `--replay <file>`.
        // AgentBuddyRemoteUI is built here too, where it's present, so the companion app's code is checked on the Mac.
        .executableTarget(
            name: "AgentBuddyChecks",
            dependencies: [
                "AgentBuddyCore",
                .product(name: "AgentBuddyRemoteKit", package: "AgentBuddyRemoteKit"),
            ] + (hasPhoneParts ? [.product(name: "AgentBuddyRemoteUI", package: "AgentBuddyRemoteKit")] : []),
            swiftSettings: hasPhoneParts ? [.define("PHONE_CHECKS")] : []
        ),
    ]
)
