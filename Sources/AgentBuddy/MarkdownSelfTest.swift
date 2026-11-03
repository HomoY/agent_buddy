import AppKit
import AgentBuddyCore
import AgentBuddyMarkdown

/// `AgentBuddy --selftest-markdown [PNG]`: draws a sample answer as an agent
/// window does (formulas, code boxes, a table, a link, and HTML that mustn't
/// run) off screen, checks what the page made of it, and writes a picture.
@MainActor
enum MarkdownSelfTest {
    static let sample = #"""
    ## The fix

    The **generator** $\mathcal L_t$ acts on $a_i, a_i^\dagger$, and the cost is $5 and $10, not a formula.

    \[
    \underbrace{\mathcal L_t\text{ has a GKSL form}}_{\text{the generator}} \quad\not\Rightarrow\quad \Phi_{t,s}\text{ exists}
    \]

    $$\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}$$

    ```swift
    func greet(_ name: String) -> String {
        "Hello, \(name)!" // the `$` here: $not math$
    }
    ```

    | Model | Tokens |
    | --- | --- |
    | claude-opus-5-5 | 13.7M |

    - See [the docs](https://example.com) and `inline code`.
    - <img src=x onerror="document.title='ran'"> stays text.
    """#

    /// A turn: what the agent wrote, a command and its output, a short change,
    /// a long one, and a command that failed.
    static let steps: [TurnStep] = [
        TurnStep(kind: .said, text: "The generator is $\\mathcal L = -i[H, \\cdot] + \\mathcal D$; let me check the bound."),
        TurnStep(kind: .ran, text: "Read(proof.tex)", outcome: "Read 120 lines"),
        TurnStep(kind: .ran, text: "Bash(swift build)", output: "Compiling AgentBuddyCore\nCompiling AgentBuddy\nLinking\nSigning\nBuild complete! (2.1 sec)"),
        TurnStep(kind: .changed, text: "Update(proof.tex)", outcome: "1 addition, 1 removal",
                 hunks: [DiffHunk(oldStart: 40, newStart: 40, lines: [" \\begin{lemma}", "-The generator is bounded.", "+The generator is closable.", " \\end{lemma}"])]),
        TurnStep(kind: .changed, text: "Update(notes.tex)", outcome: "12 additions, 1 removal", hunks: longChange),
        TurnStep(kind: .ran, text: "Bash(latexmk paper.tex)", outcome: "! Undefined control sequence.",
                 output: "! Undefined control sequence.\nl.12 \\foo", failed: true),
        // One long line, as a search's links come.
        TurnStep(kind: .ran, text: "Fetch(https://eudml.org/doc/75994)",
                 output: "Links: [" + (1...8).map { "{\"title\":\"Generators for quasi-free completely positive semi-groups \($0)\",\"url\":\"https://eudml.org/doc/\($0)\"}" }.joined(separator: ",") + "]"),
    ]

    /// Fourteen lines in two parts: over ten, so it folds away.
    static let longChange: [DiffHunk] = [
        DiffHunk(oldStart: 1, newStart: 1, lines: (1...8).map { "+Line \($0) of the notes." }),
        DiffHunk(oldStart: 20, newStart: 28, lines: (9...12).map { "+Line \($0) of the notes." } + ["-An old line.", " A kept line."]),
    ]

    static func run(image: URL?) -> Int32 {
        // Kept in an object: the checks inside the task below count too.
        final class Tally {
            var failures = 0
        }
        let tally = Tally()
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
            if !ok {
                tally.failures += 1
            }
        }
        print("Answers in agent windows: Markdown, formulas and code")
        check(MarkdownView.available, "the renderer's files are found: \(MarkdownAssets.folder?.path ?? "none")")
        final class Done: @unchecked Sendable {
            var done = false
        }
        let finished = Done()
        Task { @MainActor in
            defer { finished.done = true }
            let selectors = [".katex", ".katex-display", ".code", ".code .lang", ".hljs-keyword", "table", "a[href]", "img", "h2"]
            guard let result = await MarkdownProbe.render(sample, counting: selectors) else {
                check(false, "the sample answer renders")
                return
            }
            let counts = result.counts
            check(result.height > 200, "it measures its height: \(Int(result.height)) points")
            check(counts[".katex"] == 4 && counts[".katex-display"] == 2,
                  "formulas by KaTeX: \(counts[".katex"] ?? 0), \(counts[".katex-display"] ?? 0) on lines of their own; money and code aren't formulas")
            check(counts[".code"] == 1 && counts[".code .lang"] == 1 && (counts[".hljs-keyword"] ?? 0) > 0,
                  "a code box, labelled, its code coloured")
            check(counts["table"] == 1 && counts["a[href]"] == 1 && counts["h2"] == 1, "a table, a link and a heading")
            check(counts["img"] == 0, "an answer's own HTML shows as text, never runs")
            if let image, let picture = result.image, let tiff = picture.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: image)
                print("  wrote \(image.path)")
            }

            print("Copying an answer: the Markdown the agent wrote")
            let written = sample.trimmingCharacters(in: .whitespacesAndNewlines)
            let all = await MarkdownProbe.render(sample, counting: [], then: "getSelection().selectAllChildren(document.getElementById('answer'))",
                                                 asking: "copiedMarkdown()")
            check(all?.answer == written, "all of it copies as written: \(all?.answer?.prefix(40) ?? "nothing")…")
            // A copy as ⌘C makes it, into a clipboard of its own (not yours).
            let event = await MarkdownProbe.render(
                sample, counting: [], then: "getSelection().selectAllChildren(document.getElementById('answer'))",
                asking: "(() => { const data = new DataTransfer(); document.dispatchEvent(new ClipboardEvent('copy', {clipboardData: data, bubbles: true, cancelable: true})); return data.getData('text/plain'); })()")
            check(event?.answer == written, "⌘C puts that Markdown on the clipboard: \(event?.answer?.prefix(40) ?? "nothing")…")
            let words = await MarkdownProbe.render(sample, counting: [], then: """
                const strong = document.querySelector('#answer p strong');
                const after = document.querySelectorAll('#answer p .katex')[1].nextSibling;
                const range = document.createRange();
                range.setStart(strong.firstChild, 3);
                range.setEnd(after, 9);
                getSelection().removeAllRanges();
                getSelection().addRange(range);
                """, asking: "copiedMarkdown()")
            check(words?.answer == #"**erator** $\mathcal L_t$ acts on $a_i, a_i^\dagger$, and the"#,
                  "part of a paragraph, as Markdown: bold, formulas as their TeX: \(words?.answer ?? "nothing")")
            let across = await MarkdownProbe.render(sample, counting: [], then: """
                const range = document.createRange();
                range.setStart(document.querySelector('#answer h2').firstChild, 4);
                range.setEnd(document.querySelector('#answer li').firstChild, 2);
                getSelection().removeAllRanges();
                getSelection().addRange(range);
                """, asking: "copiedMarkdown()")
            let copied = across?.answer ?? ""
            check(copied.hasPrefix("fix\n\nThe **generator** $\\mathcal L_t$") && copied.contains("\\[\n\\underbrace")
                  && copied.contains("```swift\nfunc greet") && copied.contains("| Model | Tokens |\n| --- | --- |") && copied.hasSuffix("13.7M |\n\n- Se"),
                  "from a heading into a list: the blocks between as written, the ends as Markdown: …\(copied.suffix(30).debugDescription)")

            print("Display formulas Codex and Claude write")
            let pieces = #"""
            -b_{\tilde t}(\alpha)
            =
            \left(i\Omega_{\tilde t}+\tfrac12\Gamma_{\tilde t}\right)\alpha
            +
            \left(i\Lambda_{\tilde t}+\tfrac12\Xi_{\tilde t}\right)\alpha^*
            +i\nu_{\tilde t}.
            """#
            let cases: [(String, String)] = [
                ("on lines of its own, with = on a line", "The drift is\n\n\\[\n" + pieces + "\n\\]\n\nso it's affine."),
                ("right after a line of text", "The drift is\n\\[\n" + pieces + "\n\\]\nso it's affine."),
                ("in a list item, indented", "1. The drift is\n\n   \\[\n   " + pieces.replacingOccurrences(of: "\n", with: "\n   ") + "\n   \\]\n\n2. Next."),
                ("as $$, with = on a line", "The drift is\n\n$$\n" + pieces + "\n$$\n"),
                ("as $$, right after a line of text", "The drift is\n$$\n" + pieces + "\n$$\nso it's affine."),
            ]
            for (name, markdown) in cases {
                let drawn = await MarkdownProbe.render(markdown, counting: [".katex-display", ".katex-error"])
                let shown = drawn?.counts[".katex-display"] ?? -1
                let errors = drawn?.counts[".katex-error"] ?? -1
                check(shown == 1 && errors == 0, "a display formula \(name): drawn (\(shown) drawn, \(errors) errors)")
            }

            print("Searching an answer: the words marked where they show")
            let marked = await MarkdownProbe.render(sample, counting: [], asking: "String(highlightSearch('GENERATOR', false)) + ' ' + String(CSS.highlights.get('search').size)")
            check(marked?.answer == "2 2", "each place the words show is marked, whatever their case: \(marked?.answer ?? "nothing")")
            let none = await MarkdownProbe.render(sample, counting: [], asking: "String(highlightSearch('not in it', false)) + ' ' + String(CSS.highlights.has('search'))")
            check(none?.answer == "0 false", "words it hasn't: nothing marked: \(none?.answer ?? "nothing")")
            let redrawn = await MarkdownProbe.render(sample, counting: [], then: "highlightSearch('generator', false); render('A new generator.', {size: 13})",
                                                     asking: "String(CSS.highlights.get('search').size)")
            check(redrawn?.answer == "1", "drawn anew, still marked: \(redrawn?.answer ?? "nothing")")

            print("A turn's steps, as the agent's terminal shows them")
            let stepSelectors = [".step.said", ".step.group", ".step.action", ".step.failed", ".step .katex", ".step .output",
                                 ".step .output:not([hidden])", ".step.group .actions[hidden]", "details.changes", "details.changes[open]",
                                 ".change", ".change details.fold:not([open])", "a.view", "tr.add", "tr.del", "tr.gap"]
            guard let json = (try? JSONEncoder().encode(Self.steps)).flatMap({ String(data: $0, encoding: .utf8) }),
                  let drawn = await MarkdownProbe.render(stepsJSON: json, counting: stepSelectors, font: .serif)
            else {
                check(false, "the sample steps render")
                return
            }
            let found = drawn.counts
            check(found[".step.said"] == 1 && found[".step .katex"] == 1, "what the agent wrote, whole: Markdown, formulas too")
            check(found[".step.group"] == 1 && found[".step.group .actions[hidden]"] == 1,
                  "a run of actions that went well folds into one line, its actions a click away")
            check(found[".step.action"] == 6 && found[".step.failed"] == 1, "each action in a line or two; a failed one apart, marked")
            check(found[".step .output"] == 3 && found[".step .output:not([hidden])"] == 0, "outputs wait for a click")
            check(found["details.changes"] == 1 && found["details.changes[open]"] == 0 && found[".change"] == 2 && found["a.view"] == 2,
                  "the changes together at the end, under View changes, each linked from its line")
            check(found[".change details.fold:not([open])"] == 1 && found["tr.add"] == 13 && found["tr.del"] == 2 && found["tr.gap"] == 1,
                  "a change over ten lines folds there too; its lines added, removed, and a gap between parts")
            let larger = await MarkdownProbe.render(stepsJSON: json, counting: [], fontSize: 17, font: .serif)
            check((larger?.height ?? 0) > drawn.height * 1.15, "a bigger text size makes it taller: \(Int(drawn.height)) \u{2192} \(Int(larger?.height ?? 0)) points")
            // A step more, as a turn goes on: what's drawn stays drawn, open stays open.
            var more = Self.steps
            more.append(TurnStep(kind: .ran, text: "Bash(swift test)", output: "All tests passed."))
            let grown = (try? JSONEncoder().encode(more)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let kept = await MarkdownProbe.render(
                stepsJSON: json, counting: [".step[data-mark]", ".step.group.open", ".step.action", "details.changes[open]"],
                then: "document.querySelector('.step.said').dataset.mark = '1'; document.querySelector('.step.group .head').click(); "
                    + "document.querySelector('details.changes').open = true; renderSteps(\(grown), {size: 13})")
            check(kept?.counts[".step[data-mark]"] == 1 && kept?.counts[".step.group.open"] == 1 && kept?.counts["details.changes[open]"] == 1
                  && kept?.counts[".step.action"] == 7,
                  "a step more redraws only what changed: the rest stays put, open stays open")
            let opened = await MarkdownProbe.render(stepsJSON: json, counting: ["details.changes[open]", "#change-1 table.diff"],
                                                    then: "document.querySelector('a.view').click()")
            check(opened?.counts["details.changes[open]"] == 1 && opened?.counts["#change-1 table.diff"] == 1,
                  "View opens the changes at that one")
            // Selected on the page: a formula as its TeX; a diff's lines without their numbers.
            let saying = await MarkdownProbe.render(stepsJSON: json, counting: [],
                                                    then: "getSelection().selectAllChildren(document.querySelector('.step.said .body'))",
                                                    asking: "copiedMarkdown()")
            check(saying?.selected?.contains("$\\mathcal L = -i[H, \\cdot] + \\mathcal D$") == true,
                  "what's selected goes to the window, a formula as its TeX: \(saying?.selected?.prefix(60) ?? "nothing")")
            check(saying?.answer == Self.steps[0].text, "and copies as the agent wrote it: \(saying?.answer?.prefix(60) ?? "nothing")")
            let turn = await MarkdownProbe.render(stepsJSON: json, counting: [], then: "getSelection().selectAllChildren(document.getElementById('answer'))",
                                                  asking: "copiedMarkdown()")
            check(turn?.answer?.hasPrefix(Self.steps[0].text + "\n\nRead 1 file, ran 1 command") == true && turn?.answer?.contains("Bash(latexmk paper.tex)") == true,
                  "a whole turn: what it wrote as Markdown, its actions as text: \(turn?.answer?.prefix(120).debugDescription ?? "nothing")")
            // dsfont's and bbm's double-struck letters, which KaTeX hasn't on its own.
            let struck = #"[{"kind":"said","text":"The indicator $\\mathds{1}_{A}(x)$ on $\\mathbbm{R}^n$, and $\\mathds 1 \\in \\mathds{k}$."}]"#
            let indicator = await MarkdownProbe.render(
                stepsJSON: struck, counting: [".katex", ".katex-error", ".katex .mathbb"],
                then: "getSelection().selectAllChildren(document.querySelector('.step.said .body'))")
            check(indicator?.counts[".katex"] == 3 && indicator?.counts[".katex-error"] == 0 && (indicator?.counts[".katex .mathbb"] ?? 0) >= 1,
                  "\\mathds and \\mathbbm draw, double-struck: \(indicator?.counts ?? [:])")
            check(indicator?.selected?.contains("$\\mathds{1}_{A}(x)$") == true && indicator?.selected?.contains("$\\mathbbm{R}^n$") == true,
                  "and a selection copies them as written: \(indicator?.selected?.prefix(80) ?? "nothing")")
            if let image, let picture = indicator?.image, let tiff = picture.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let struckImage = image.deletingPathExtension().appendingPathExtension("struck.png")
                try? png.write(to: struckImage)
                print("  wrote \(struckImage.path)")
            }
            let changing = await MarkdownProbe.render(
                stepsJSON: json, counting: [],
                then: "document.querySelector('details.changes').open = true; getSelection().selectAllChildren(document.querySelector('#change-1 table.diff'))")
            let lines = changing?.selected?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            check(lines.contains("+The generator is closable.") && lines.contains("-The generator is bounded.")
                  && !(changing?.selected ?? "").contains("41"),
                  "a diff's lines with their signs, not their numbers: \(lines.prefix(3))")
            if let image, let picture = drawn.image, let tiff = picture.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let file = image.deletingPathExtension().appendingPathExtension("steps.png")
                try? png.write(to: file)
                print("  wrote \(file.path)")
            }
        }
        let deadline = Date().addingTimeInterval(90)
        while !finished.done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check(finished.done, "it finished in time")
        print(tally.failures == 0 ? "Markdown self-test passed." : "\(tally.failures) Markdown checks failed.")
        return tally.failures == 0 ? 0 : 1
    }
}
