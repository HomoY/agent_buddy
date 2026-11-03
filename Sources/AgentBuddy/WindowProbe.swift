import AppKit
import AgentBuddyCore
import IOKit

/// `AgentBuddy --probe-window [--app] [SECONDS] (LOG | KEY)...`: opens an agent
/// window for each (a LOG on a copy of it; KEY, a window's "agent|server|session")
/// and says how much CPU (Agent Buddy's, and the programs it runs), memory and GPU
/// they cost together, second by second: sitting there; waiting, each with a
/// prompt as if sent from it and its agent still at work; and streaming, each
/// log (a copy) growing as an agent writes it. With --app, the whole app runs
/// around them, and they open as from the list. They're on screen, so they're
/// drawn as usual, but almost clear, let clicked through, and never take the keyboard.
@MainActor
final class WindowProbe: NSObject, NSApplicationDelegate {
    private let targets: [String]
    private let seconds: TimeInterval
    private let wholeApp: Bool
    private var app: AppDelegate?

    init(targets: [String], seconds: TimeInterval, wholeApp: Bool) {
        self.targets = targets
        self.seconds = seconds
        self.wholeApp = wholeApp
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            exit(await run())
        }
    }

    private func settle(_ seconds: TimeInterval, until done: () -> Bool = { false }) async {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until, !done() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// A window under test: its key, and for a log, its copy and the lines it grows by.
    private struct Probed {
        var key: String
        var copy: URL?
        var lines: [Data] = []
        var next = 0
        var output: URL?
    }

    private func run() async -> Int32 {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory
        // Copies left by a probe stopped before it could remove them.
        for name in (try? manager.contentsOfDirectory(atPath: temporary.path)) ?? [] where name.hasPrefix("AgentBuddy-window-probe-") {
            if let pid = Int32(name.dropFirst("AgentBuddy-window-probe-".count)), kill(pid, 0) != 0 {
                try? manager.removeItem(at: temporary.appendingPathComponent(name))
            }
        }
        let folder = temporary.appendingPathComponent("AgentBuddy-window-probe-\(getpid())")
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }

        // Each log: a copy, under a name of its own (so no window Agent Buddy knows reads the
        // original), all but its last lines; they're written while it streams.
        var probed: [Probed] = []
        var megabytes = 0
        for target in targets {
            guard !target.contains("|") else {
                probed.append(Probed(key: target))
                continue
            }
            guard let data = manager.contents(atPath: target) else {
                print("can't read \(target)")
                return 1
            }
            megabytes += data.count / 1_000_000
            var all = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Data($0) + Data("\n".utf8) }
            if all.last == Data("\n".utf8) {
                all.removeLast()
            }
            let held = min(400, all.count / 3)
            let codex = target.contains("/.codex/")
            let name = (codex ? "rollout-" : "") + UUID().uuidString.lowercased()
            let file = folder.appendingPathComponent(name + ".jsonl")
            manager.createFile(atPath: file.path, contents: all.dropLast(held).reduce(into: Data()) { $0.append($1) })
            let output = folder.appendingPathComponent(name + ".out")
            manager.createFile(atPath: output.path, contents: nil)
            // Only the lines written while it streams are kept (not the probe's own memory in what's measured).
            probed.append(Probed(key: "\(codex ? "codex" : "claude")||\(name)", copy: file, lines: Array(all.suffix(held)), output: output))
        }
        print("\(probed.count) windows, \(megabytes) MB of logs")

        let windows: SessionDetailsController
        if wholeApp {
            let app = AppDelegate()
            self.app = app
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            await settle(3)
            windows = app.sessionWindows
        } else {
            windows = SessionDetailsController()
        }
        windows.offscreen = true
        guard let area = NSScreen.main?.visibleFrame else { return 1 }
        let opening = (cpu: Self.cpuSeconds(), at: Date())
        var opened: [(window: NSWindow, details: SessionDetails)] = []
        for (index, window) in probed.enumerated() {
            if let app {
                app.model?.showWindow(window.key, path: window.copy?.path)
            } else {
                windows.show(key: window.key, info: WindowInfo(title: nil, project: nil, path: window.copy?.path, finished: []))
            }
            guard let open = windows.open(window.key) else {
                print("no window opened for \(window.key)")
                return 1
            }
            open.window.alphaValue = 0.02
            open.window.ignoresMouseEvents = true
            open.window.setFrameOrigin(NSPoint(x: area.minX + 20 + CGFloat(index) * 24, y: area.minY + 20 + CGFloat(index) * 12))
            open.window.orderFrontRegardless()
            opened.append(open)
        }
        // In sight as each phase says (not as other apps' windows happen to cover them).
        var inSight = Array(repeating: true, count: opened.count)
        for (index, open) in opened.enumerated() {
            open.details.isInSight = { inSight[index] }
        }
        await settle(180) { opened.allSatisfy { $0.details.history != nil || $0.details.problem != nil } }
        await settle(20) { opened.allSatisfy { !HistorySelfTest.webViews(in: $0.window.contentView).isEmpty } }
        await settle(3)
        let ready = Self.cpuSeconds()
        print(String(format: "opening them (%.1f s): CPU %.2f s, programs it ran %.2f s", Date().timeIntervalSince(opening.at),
                     ready.own - opening.cpu.own, ready.children - opening.cpu.children))
        print("\(opened.map { $0.details.history?.turns.count ?? 0 }.reduce(0, +)) prompts, "
              + "\(opened.map { HistorySelfTest.webViews(in: $0.window.contentView).count }.reduce(0, +)) pages")

        /// CPU second by second while `during` runs: the mean, the 95th percentile and the worst second.
        func measure(_ what: String, for length: TimeInterval? = nil, during: (_ second: Int) async -> Void) async {
            print("measuring \(what)")
            let gpu = Self.gpuSeconds()
            let first = Self.cpuSeconds()
            var last = first
            var lastAt = Date()
            let start = lastAt
            var each: [Double] = []
            for second in 0..<Int(length ?? seconds) {
                await during(second)
                let now = Self.cpuSeconds()
                let at = Date()
                each.append((now.own - last.own) * 100 / at.timeIntervalSince(lastAt))
                (last, lastAt) = (now, at)
            }
            let elapsed = lastAt.timeIntervalSince(start)
            let sorted = each.sorted()
            print(String(format: "%@: CPU %.1f%% (95%% of seconds under %.1f%%, worst %.1f%%), programs it ran %.1f%%, GPU %.1f ms a second, memory %d MB",
                         what, (last.own - first.own) * 100 / elapsed, sorted[min(sorted.count - 1, sorted.count * 95 / 100)], sorted.last ?? 0,
                         (last.children - first.children) * 100 / elapsed, (Self.gpuSeconds() - gpu) * 1000 / elapsed, Self.footprint()))
            print("  each second: " + each.map { String(format: "%.0f", $0) }.joined(separator: " "))
        }
        await measure("sitting") { _ in await settle(1) }

        // A prompt as if sent from each window, its agent (a process that waits) still at work.
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        agent.arguments = ["3600"]
        try? agent.run()
        defer { agent.terminate() }
        for (index, open) in opened.enumerated() where probed[index].output != nil {
            open.details.showSending(PromptSender.Started(
                agent: open.details.agent, host: nil, pid: agent.processIdentifier, log: probed[index].output!.path, at: Date()),
                text: "Probe: what's next?")
        }
        await settle(2)
        await measure("waiting") { _ in await settle(1) }

        // Each log grows a few lines a second, at its own moments, as each agent writes;
        // the prompt's output with it.
        var handles = probed.map { window in window.copy.flatMap { try? FileHandle(forWritingTo: $0) } }
        var outputs = probed.map { window in window.output.flatMap { try? FileHandle(forWritingTo: $0) } }
        for handle in handles + outputs {
            handle?.seekToEndOfFile()
        }
        func stream() async {
            for tenth in 0..<10 {
                for index in probed.indices where index % 10 == tenth && probed[index].next < probed[index].lines.count {
                    for _ in 0..<3 where probed[index].next < probed[index].lines.count {
                        let line = probed[index].lines[probed[index].next]
                        handles[index]?.write(line)
                        outputs[index]?.write(line)
                        probed[index].next += 1
                    }
                }
                await settle(0.1)
            }
        }
        await measure("streaming") { _ in await stream() }
        // All but one out of sight (as behind other windows), still streaming; then all back.
        if opened.count > 1 {
            for index in opened.indices.dropFirst() {
                inSight[index] = false
            }
            await settle(1)
            await measure("streaming, 1 of \(opened.count) in sight") { _ in await stream() }
            for index in opened.indices.dropFirst() {
                inSight[index] = true
                opened[index].details.cameIntoSight(inFront: false)
            }
            await measure("all back in sight", for: 4) { _ in await settle(1) }
        }
        for handle in handles + outputs {
            try? handle?.close()
        }
        handles = []
        outputs = []
        for open in opened {
            open.window.close()
        }
        app?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        return 0
    }

    /// This process's memory, as Activity Monitor shows it, in megabytes.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Int(info.phys_footprint / 1_000_000)
    }

    /// The GPU time this process has used, as the GPU's driver counts it for Activity Monitor.
    static func gpuSeconds() -> Double {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(accelerators) }
        let me = "pid \(getpid()),"
        var total: UInt64 = 0
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                func property(_ name: String) -> Any? {
                    IORegistryEntryCreateCFProperty(client, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                guard (property("IOUserClientCreator") as? String)?.hasPrefix(me) == true else { continue }
                for usage in property("AppUsage") as? [[String: Any]] ?? [] {
                    total += (usage["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
                }
            }
        }
        return Double(total) / 1e9
    }

    /// CPU time: this process's, and that of the programs it ran that have ended.
    static func cpuSeconds() -> (own: Double, children: Double) {
        func seconds(_ who: Int32) -> Double {
            var usage = rusage()
            getrusage(who, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        return (seconds(RUSAGE_SELF), seconds(RUSAGE_CHILDREN))
    }
}
