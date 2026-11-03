"use strict";
// An agent's answer, from Markdown: formulas ($…$, $$…$$, \(…\), \[…\]) by
// KaTeX, code in boxes coloured by highlight.js, tables, lists and links. The
// answer's own HTML is shown as text, never run.
(function () {
  const escapeHtml = (text) => String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

  // Double-struck as dsfont's \mathds and bbm's \mathbbm write it (𝟙 for an
  // indicator, ℝ), which KaTeX hasn't: capitals as \mathbb, digits and small
  // letters as Unicode's own double-struck characters.
  function doubleStruck(source) {
    return source.replace(/\\math(?:ds|bbm)(?:\s*\{([^{}]*)\}|\s+([A-Za-z0-9])|([0-9]))/g, (_, group, spaced, digit) => {
      const text = group !== undefined ? group : spaced !== undefined ? spaced : digit;
      return "{" + Array.from(text).map((c) => {
        if (/[A-Z]/.test(c)) return "\\mathbb{" + c + "}";
        if (/[0-9]/.test(c)) return String.fromCodePoint(0x1d7d8 + Number(c));
        if (/[a-z]/.test(c)) return String.fromCodePoint(0x1d552 + c.charCodeAt(0) - 97);
        return c;
      }).join("") + "}";
    });
  }

  function tex(source, display) {
    try {
      const drawn = katex.renderToString(doubleStruck(source), { displayMode: display, throwOnError: false, strict: false, trust: false, output: "htmlAndMathml" });
      // The formula's TeX (what a selection copies) stays as it was written.
      return drawn.replace(/(<annotation encoding="application\/x-tex">)[\s\S]*?(<\/annotation>)/, (_, open, close) => open + escapeHtml(source) + close);
    } catch (error) {
      return "<code>" + escapeHtml(source) + "</code>";
    }
  }

  // A formula on lines of its own.
  const mathBlock = {
    name: "mathBlock",
    level: "block",
    start(src) {
      const index = src.search(/\$\$|\\\[/);
      return index < 0 ? undefined : index;
    },
    tokenizer(src) {
      const match = /^\$\$([\s\S]+?)\$\$[ \t]*(?:\n|$)/.exec(src) || /^\\\[([\s\S]+?)\\\][ \t]*(?:\n|$)/.exec(src);
      if (match) {
        return { type: "mathBlock", raw: match[0], text: match[1].trim() };
      }
    },
    renderer(token) {
      return '<div class="math-block">' + tex(token.text, true) + "</div>";
    },
  };

  // A formula within a line; $…$ only when it doesn't look like money ("$5 and $10").
  const mathInline = {
    name: "mathInline",
    level: "inline",
    start(src) {
      const index = src.search(/\$|\\\(|\\\[/);
      return index < 0 ? undefined : index;
    },
    tokenizer(src) {
      let match = /^\$\$([\s\S]+?)\$\$/.exec(src);
      if (match) return { type: "mathInline", raw: match[0], text: match[1].trim(), display: true };
      match = /^\\\[([\s\S]+?)\\\]/.exec(src);
      if (match) return { type: "mathInline", raw: match[0], text: match[1].trim(), display: true };
      match = /^\\\(([\s\S]+?)\\\)/.exec(src);
      if (match) return { type: "mathInline", raw: match[0], text: match[1], display: false };
      match = /^\$(?![\s$])((?:\\\$|[^$\n])+?)(?<![\s\\])\$(?!\d)/.exec(src);
      if (match) return { type: "mathInline", raw: match[0], text: match[1], display: false };
    },
    renderer(token) {
      return tex(token.text, token.display);
    },
  };

  // A few harmless tags pass; any other HTML shows as text.
  const harmless = /^<\/?(br|sup|sub|kbd|b|i|em|strong|u|s|del|mark|small)\s*\/?>$/i;

  marked.use({
    gfm: true,
    breaks: false,
    extensions: [mathBlock, mathInline],
    renderer: {
      html(token) {
        const text = token.text || token.raw || "";
        return harmless.test(text.trim()) ? text.trim() : escapeHtml(text);
      },
      code(token) {
        const lang = (token.lang || "").trim().split(/\s+/)[0];
        let body = escapeHtml(token.text);
        if (lang && window.hljs && hljs.getLanguage(lang)) {
          try {
            body = hljs.highlight(token.text, { language: lang, ignoreIllegals: true }).value;
          } catch (error) {}
        }
        const label = lang ? '<div class="lang">' + escapeHtml(lang) + "</div>" : "";
        return '<div class="code">' + label + '<pre><code class="hljs">' + body + "</code></pre></div>";
      },
    },
  });

  const root = document.getElementById("answer");
  let lastHeight = 0;

  function postHeight() {
    const height = Math.ceil(root.getBoundingClientRect().height);
    if (height !== lastHeight && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.size) {
      lastHeight = height;
      window.webkit.messageHandlers.size.postMessage(height);
    }
  }

  // A formula wider than the answer shrinks to fit, to about two-thirds of its
  // size; past that it scrolls sideways.
  function fitFormulas() {
    root.querySelectorAll(".katex-display").forEach((box) => {
      const formula = box.querySelector(".katex");
      if (!formula) return;
      formula.style.fontSize = "";
      const ratio = box.clientWidth / box.scrollWidth;
      if (ratio < 1) {
        const math = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--math")) || 1.16;
        formula.style.fontSize = (math * Math.max(0.65, ratio * 0.98)).toFixed(3) + "em";
      }
    });
  }

  function settle() {
    fitFormulas();
    postHeight();
    markSearch(false);
  }

  // Words searched for in the window, marked wherever they show on the page
  // (a CSS highlight: the page itself is left as it is); `reveal` scrolls the
  // window to the first.
  let searched = "";
  window.highlightSearch = function (query, reveal) {
    searched = String(query || "");
    return markSearch(reveal);
  };

  function markSearch(reveal) {
    if (!(window.CSS && CSS.highlights && window.Highlight)) return 0;
    CSS.highlights.delete("search");
    const needle = searched.toLocaleLowerCase();
    if (!needle) return 0;
    const ranges = [];
    // What shows: not a formula's hidden MathML, nor a part folded away.
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (text) => {
        const parent = text.parentElement;
        if (!parent || parent.closest(".katex-mathml")) return NodeFilter.FILTER_REJECT;
        return parent.checkVisibility && !parent.checkVisibility() ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      },
    });
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const text = node.textContent.toLocaleLowerCase();
      if (text.length !== node.textContent.length) continue;
      for (let at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + needle.length)) {
        const range = document.createRange();
        range.setStart(node, at);
        range.setEnd(node, at + needle.length);
        ranges.push(range);
      }
    }
    if (ranges.length) CSS.highlights.set("search", new Highlight(...ranges));
    const handlers = window.webkit && window.webkit.messageHandlers;
    if (reveal && ranges.length && handlers && handlers.reveal) {
      const place = ranges[0].getBoundingClientRect();
      handlers.reveal.postMessage({ top: Math.max(0, place.top + window.scrollY - 60), height: place.height + 120 });
    }
    return ranges.length;
  }

  // Size and typeface: {size: 13, font: "<CSS font family>"}.
  function apply(options) {
    const style = document.documentElement.style;
    style.setProperty("--size", ((options && options.size) || 13) + "px");
    if (options && options.font) {
      style.setProperty("--font", options.font);
    } else {
      style.removeProperty("--font");
    }
  }

  // Each drawn block and the Markdown it was drawn from (its token among the
  // answer's), for a copy to give back what the agent wrote.
  const sources = new WeakMap();

  // A formula on lines of its own ($$ or \\[) straight after a line of text
  // is set apart by a blank line: else a line in it of only = or - reads as
  // the underline of a heading made of the lines above, and the formula
  // breaks in two. Code blocks, and what's inside a formula, are left as they are.
  function apartFormulas(text) {
    const lines = text.split("\n");
    const out = [];
    let fence = null;
    let closing = null;
    for (const line of lines) {
      const trimmed = line.trim();
      if (fence) {
        if (trimmed.startsWith(fence)) fence = null;
      } else if (closing) {
        if (trimmed.includes(closing)) closing = null;
      } else {
        const opensCode = /^(```|~~~)/.exec(trimmed);
        if (opensCode) {
          fence = opensCode[1];
        } else if (trimmed.startsWith("$$") || trimmed.startsWith("\\[")) {
          const close = trimmed.startsWith("$$") ? "$$" : "\\]";
          if (out.length && out[out.length - 1].trim() !== "") out.push("");
          if (!trimmed.slice(2).includes(close)) closing = close;
        }
      }
      out.push(line);
    }
    return out.join("\n");
  }

  function markdownInto(node, markdown) {
    const text = apartFormulas(String(markdown || ""));
    try {
      const tokens = marked.lexer(text);
      node.textContent = "";
      tokens.forEach((token, index) => {
        if (token.type === "space" || token.type === "def") return;
        const one = [token];
        one.links = tokens.links;
        const holder = document.createElement("template");
        holder.innerHTML = marked.parser(one);
        for (const child of Array.from(holder.content.childNodes)) {
          let block = child;
          if (block.nodeType !== Node.ELEMENT_NODE) {
            // An answer's own HTML, drawn as text.
            if (!block.textContent.trim()) continue;
            block = element("p", null, child.textContent);
          }
          block.setAttribute("data-md", "");
          sources.set(block, { tokens: tokens, index: index });
          node.appendChild(block);
        }
      });
    } catch (error) {
      node.textContent = text;
    }
  }

  window.render = function (markdown, options) {
    apply(options);
    drawn = [];
    keep(null);
    markdownInto(root, markdown);
    lastHeight = 0;
    settle();
  };

  // A turn's steps, as the agent's terminal shows them after a ●: what it
  // wrote, in full; its actions, each in a line or two (a run of them that went
  // well folds into one), their outputs a click away; its changes' diffs
  // together at the end, under "View changes".
  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // "Bash(swift build)": the tool, then what it ran on; cut at two lines, all
  // of it when you point at it.
  function call(text) {
    const node = element("div", "call");
    node.title = text;
    const open = text.indexOf("(");
    if (open > 0 && text.endsWith(")")) {
      node.appendChild(element("span", "tool", text.slice(0, open)));
      node.appendChild(element("span", "arg", text.slice(open)));
    } else {
      node.appendChild(element("span", "tool", text));
    }
    return node;
  }

  function lineCount(step) {
    return (step.hunks || []).reduce((total, hunk) => total + (hunk.lines || []).length, 0);
  }

  // A part that opens and folds when its head is clicked.
  function opener(item, head, part) {
    item.classList.add("opens");
    head.appendChild(element("span", "chevron", "›"));
    part.hidden = true;
    head.addEventListener("click", (event) => {
      if (event.target.closest("a")) return;
      part.hidden = !part.hidden;
      item.classList.toggle("open", !part.hidden);
      postHeight();
    });
  }

  function action(step) {
    const item = element("div", "step action " + step.kind + (step.failed ? " failed" : ""));
    item.appendChild(element("span", "dot", "●"));
    const body = element("div", "body");
    const head = element("div", "head");
    head.appendChild(call(step.text || ""));
    body.appendChild(head);
    const change = step.change || 0;
    if (step.outcome || change) {
      const line = element("div", "outcome");
      line.appendChild(element("span", "corner", "⎿"));
      line.appendChild(element("span", "summary", step.outcome || ""));
      if (change) {
        const view = element("a", "view", "View");
        view.addEventListener("click", (event) => {
          event.preventDefault();
          reveal(change);
        });
        line.appendChild(view);
      }
      body.appendChild(line);
    }
    if (step.output) {
      const output = element("div", "output", step.output);
      body.appendChild(output);
      opener(item, head, output);
    }
    item.appendChild(body);
    return item;
  }

  // "Read 2 files, ran 3 commands": a run of actions, folded into one line.
  const wordings = [
    [/^(Bash|Shell)$/, (n) => "ran " + n + (n === 1 ? " command" : " commands")],
    [/^Read$/, (n) => "read " + n + (n === 1 ? " file" : " files")],
    [/^Search$/, (n) => "searched for " + n + (n === 1 ? " pattern" : " patterns")],
    [/^Web Search$/, (n) => "searched the web" + (n === 1 ? "" : " " + n + " times")],
    [/^Fetch$/, (n) => "fetched " + n + (n === 1 ? " page" : " pages")],
    [/^(Task|Agent)$/, (n) => "ran " + n + (n === 1 ? " agent" : " agents")],
    [/^View Image$/, (n) => "viewed " + n + (n === 1 ? " image" : " images")],
  ];
  const otherTools = (n) => "used " + n + (n === 1 ? " tool" : " tools");

  function summary(run) {
    const counts = new Map();
    for (const step of run) {
      const text = step.text || "";
      const name = text.indexOf("(") > 0 ? text.slice(0, text.indexOf("(")) : text;
      const found = wordings.find((entry) => entry[0].test(name));
      const say = found ? found[1] : otherTools;
      counts.set(say, (counts.get(say) || 0) + 1);
    }
    const text = Array.from(counts, ([say, count]) => say(count)).join(", ");
    return text.charAt(0).toUpperCase() + text.slice(1);
  }

  function group(run) {
    const item = element("div", "step group ran");
    item.appendChild(element("span", "dot", "●"));
    const body = element("div", "body");
    const head = element("div", "head");
    head.appendChild(element("div", "call", summary(run)));
    const list = element("div", "actions");
    for (const step of run) list.appendChild(action(step));
    body.appendChild(head);
    body.appendChild(list);
    opener(item, head, list);
    item.appendChild(body);
    return item;
  }

  // A change's lines, numbered as in the file: removed ones by the old file's
  // numbers, the others by the new one's.
  function diff(hunks) {
    const table = element("table", "diff");
    hunks.forEach((hunk, index) => {
      if (index > 0) {
        const gap = element("tr", "gap");
        gap.appendChild(element("td", "num", "⋮"));
        gap.appendChild(element("td", "sign"));
        gap.appendChild(element("td", "text"));
        table.appendChild(gap);
      }
      let before = hunk.oldStart || 0;
      let after = hunk.newStart || 0;
      for (const line of hunk.lines || []) {
        const sign = line.charAt(0);
        const row = element("tr", sign === "+" ? "add" : sign === "-" ? "del" : "keep");
        let number = "";
        if (sign === "-") {
          number = before > 0 ? before++ : "";
        } else if (sign === "+") {
          number = after > 0 ? after++ : "";
        } else {
          number = after > 0 ? after : "";
          if (before > 0) before++;
          if (after > 0) after++;
        }
        row.appendChild(element("td", "num", String(number)));
        row.appendChild(element("td", "sign", sign === " " ? "" : sign));
        row.appendChild(element("td", "text", line.slice(1)));
        table.appendChild(row);
      }
    });
    return table;
  }

  // "View changes": every change's diff, numbered as its line above links to it.
  function changeList(changes) {
    const box = element("details", "changes");
    const files = new Set();
    let added = 0;
    let removed = 0;
    for (const step of changes) {
      files.add(step.text);
      for (const hunk of step.hunks || []) {
        for (const line of hunk.lines || []) {
          if (line.charAt(0) === "+") added++;
          else if (line.charAt(0) === "-") removed++;
        }
      }
    }
    const title = "View changes · " + files.size + (files.size === 1 ? " file" : " files") + ", +" + added + " −" + removed;
    box.appendChild(element("summary", null, title));
    changes.forEach((step, index) => {
      const entry = element("div", "change");
      entry.id = "change-" + (index + 1);
      const head = element("div", "change-head");
      head.appendChild(call(step.text || ""));
      if (step.outcome) head.appendChild(element("div", "summary", step.outcome));
      entry.appendChild(head);
      const count = lineCount(step);
      if (count > 10) {
        // A long change folds away until asked for.
        const fold = element("details", "fold");
        fold.appendChild(element("summary", null, "Show " + count + " lines"));
        fold.appendChild(diff(step.hunks));
        entry.appendChild(fold);
      } else {
        entry.appendChild(diff(step.hunks));
      }
      box.appendChild(entry);
    });
    return box;
  }

  // A change's View: opens it under "View changes", and asks the window to scroll there.
  function reveal(number) {
    const box = root.querySelector("details.changes");
    const entry = document.getElementById("change-" + number);
    if (!box || !entry) return;
    box.open = true;
    const fold = entry.querySelector("details.fold");
    if (fold) fold.open = true;
    postHeight();
    setTimeout(() => {
      const place = entry.getBoundingClientRect();
      const handlers = window.webkit && window.webkit.messageHandlers;
      if (handlers && handlers.reveal) {
        handlers.reveal.postMessage({ top: place.top + window.scrollY, height: Math.min(place.height, 360) });
      }
    }, 120);
  }

  function said(step) {
    const item = element("div", "step said");
    item.appendChild(element("span", "dot", "●"));
    const body = element("div", "body");
    markdownInto(body, step.text);
    item.appendChild(body);
    return item;
  }

  // The page's parts in order: what each is (its key) and how to draw it.
  // Changes are numbered here, so a part drawn before keeps its View link.
  function layout(steps) {
    const parts = [];
    const changes = [];
    for (const step of steps || []) {
      if (lineCount(step) > 0) {
        changes.push(step);
        step.change = changes.length;
      }
    }
    let run = [];
    function flush() {
      const taken = run;
      if (taken.length === 1) parts.push({ key: "a" + JSON.stringify(taken[0]), draw: () => action(taken[0]) });
      else if (taken.length > 1) parts.push({ key: "g" + JSON.stringify(taken), draw: () => group(taken) });
      run = [];
    }
    for (const step of steps || []) {
      if (step.kind === "ran" && !step.failed) {
        run.push(step);
        continue;
      }
      flush();
      if (step.kind === "said") parts.push({ key: "s" + step.text, draw: () => said(step) });
      else parts.push({ key: "a" + JSON.stringify(step), draw: () => action(step) });
    }
    flush();
    if (changes.length) parts.push({ key: "c" + JSON.stringify(changes), draw: () => changeList(changes) });
    return parts;
  }

  // A part and what in it opens: steps (a run; an action, for its output), and <details>.
  function within(node, selector) {
    return (node.matches(selector) ? [node] : []).concat(Array.from(node.querySelectorAll(selector)));
  }

  function openers(node) {
    return within(node, ".step.opens");
  }

  // What's open in a drawn part (a run, an action's output, a <details>), to open again.
  function openings(node) {
    return {
      steps: openers(node).map((step) => step.classList.contains("open")),
      details: within(node, "details").map((part) => part.open),
    };
  }

  function reopen(node, was) {
    openers(node).forEach((step, index) => {
      if (!was.steps[index]) return;
      step.classList.add("open");
      const part = step.querySelector(":scope > .body > .actions, :scope > .body > .output");
      if (part) part.hidden = false;
    });
    within(node, "details").forEach((part, index) => {
      if (was.details[index]) part.open = true;
    });
  }

  // The parts as drawn: a new turn's steps redraw only what changed (the parts
  // after the last unchanged one), so what's on screen stays put, open stays
  // open, and a selection in it stays selected.
  let drawn = [];

  window.renderSteps = function (steps, options) {
    apply(options);
    if (!drawn.length) root.textContent = "";
    const parts = layout(steps);
    let same = 0;
    while (same < parts.length && same < drawn.length && drawn[same].key === parts[same].key) same++;
    const gone = drawn.slice(same);
    gone.forEach((part) => part.node.remove());
    drawn = drawn.slice(0, same);
    parts.slice(same).forEach((part, index) => {
      const node = part.draw();
      // The part it takes the place of, if of its kind: a run that grew, the changes at the end.
      const before = gone[index];
      if (before && before.key.charAt(0) === part.key.charAt(0)) reopen(node, openings(before.node));
      root.appendChild(node);
      drawn.push({ key: part.key, node: node });
    });
    lastHeight = 0;
    settle();
  };

  // Opening or folding a part changes the height.
  root.addEventListener("toggle", postHeight, true);

  // What's selected on the page, told to the window around it (the agent
  // windows offer it with the next prompt): formulas as their TeX, a diff's
  // lines without their numbers.
  function selectedText() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return "";
    const box = document.createElement("div");
    for (let index = 0; index < selection.rangeCount; index++) {
      box.appendChild(selection.getRangeAt(index).cloneContents());
    }
    return plainText(box);
  }

  // Selected parts' text, as it reads: formulas as their TeX, a diff's lines
  // without their numbers.
  function plainText(box) {
    box.querySelectorAll(".katex").forEach((formula) => {
      const tex = formula.querySelector("annotation[encoding='application/x-tex']");
      const display = formula.closest(".katex-display") || formula.classList.contains("katex-display");
      formula.replaceWith(tex ? (display ? "$$" + tex.textContent + "$$" : "$" + tex.textContent + "$") : formula.textContent);
    });
    // A diff's lines as a diff has them, "-" or "+" first; not their numbers.
    // (A selection inside a table copies its rows without the table.)
    box.querySelectorAll("tr").forEach((row) => {
      const text = row.querySelector("td.text");
      if (!text) return;
      const sign = row.querySelector("td.sign");
      text.textContent = row.classList.contains("gap") ? "\u2026" : ((sign && sign.textContent) || " ") + text.textContent;
      row.querySelectorAll("td.num, td.sign").forEach((cell) => cell.remove());
    });
    box.querySelectorAll(".chevron, .dot, .corner").forEach((part) => part.remove());
    // Laid out out of sight, so its text keeps its lines.
    box.style.position = "absolute";
    box.style.left = "-100000px";
    box.style.whiteSpace = "pre-wrap";
    document.body.appendChild(box);
    const text = box.innerText;
    box.remove();
    return text.trim() ? text : "";
  }

  // A copy (⌘C) gives the Markdown the agent wrote: whole blocks as written,
  // part of one as Markdown made from what's selected of it, and a turn's
  // other parts (its actions, their outputs, its changes) as their text.
  function selectedMarkdown() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return "";
    const range = outOfFormulas(selection.getRangeAt(0));
    const pieces = [];
    let run = null;
    const flush = () => {
      if (run) pieces.push(run.tokens.slice(run.first, run.last + 1).map((token) => token.raw).join(""));
      run = null;
    };
    for (const unit of root.querySelectorAll("[data-md], :scope > .step:not(.said), :scope > details.changes")) {
      if (!range.intersectsNode(unit)) continue;
      const source = sources.get(unit);
      if (source && covers(range, unit)) {
        // Blocks next to each other in one answer: the Markdown from the first to the last, spacing and all.
        if (run && run.tokens === source.tokens) run.last = source.index;
        else {
          flush();
          run = { tokens: source.tokens, first: source.index, last: source.index };
        }
        continue;
      }
      flush();
      const part = clipped(range, unit);
      pieces.push(source ? markdownOfPart(part) : plainText(part));
    }
    flush();
    return pieces.map((piece) => piece.replace(/^\n+/, "").replace(/\s+$/, "")).filter((piece) => piece).join("\n\n");
  }

  document.addEventListener("copy", (event) => {
    const markdown = selectedMarkdown();
    if (!markdown || !event.clipboardData) return;
    event.clipboardData.setData("text/plain", markdown);
    event.preventDefault();
  });
  window.copiedMarkdown = selectedMarkdown;

  // A selection that starts or ends inside a formula takes all of it.
  function outOfFormulas(range) {
    const wide = range.cloneRange();
    const formula = (node) => {
      const at = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
      return at && (at.closest(".katex-display") || at.closest(".katex"));
    };
    const first = formula(wide.startContainer);
    if (first) wide.setStartBefore(first);
    const last = formula(wide.endContainer);
    if (last) wide.setEndAfter(last);
    return wide;
  }

  // Whether the range takes all of a block's text, from its first letter to its last.
  function covers(range, node) {
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT, {
      acceptNode: (text) => (text.textContent.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP),
    });
    const first = walker.nextNode();
    if (!first) return true;
    let last = first;
    for (let next = walker.nextNode(); next; next = walker.nextNode()) last = next;
    return range.isPointInRange(first, first.textContent.search(/\S/)) && range.isPointInRange(last, last.textContent.replace(/\s+$/, "").length);
  }

  // What of `node` the range takes, in a copy of `node` itself.
  function clipped(range, node) {
    const part = document.createRange();
    part.selectNodeContents(node);
    if (range.compareBoundaryPoints(Range.START_TO_START, part) > 0) part.setStart(range.startContainer, range.startOffset);
    if (range.compareBoundaryPoints(Range.END_TO_END, part) < 0) part.setEnd(range.endContainer, range.endOffset);
    const holder = node.cloneNode(false);
    holder.appendChild(part.cloneContents());
    return holder;
  }

  // Part of a block, as Markdown: a few words of a heading or a quote as
  // themselves; list items and table rows with their markers; code as it is.
  function markdownOfPart(holder) {
    const tag = holder.tagName.toLowerCase();
    const has = (selector) => Array.from(holder.children).some((child) => child.matches(selector));
    if (holder.classList.contains("code")) {
      const code = holder.querySelector("pre");
      return code ? code.textContent : "";
    }
    if ((tag === "ul" || tag === "ol") && has("li")) return markdownOf(holder);
    if (tag === "table" && holder.querySelector("tr")) return markdownOf(holder);
    return tidy(inlineOf(holder));
  }

  function inlineOf(parent) {
    return Array.from(parent.childNodes).map(markdownOf).join("");
  }

  function tidy(text) {
    return text.replace(/\n{3,}/g, "\n\n").replace(/^\n+/, "").replace(/\s+$/, "");
  }

  // Marks around text, its spaces kept outside ("** bold**" isn't bold).
  function enclosed(mark, text) {
    const parts = /^(\s*)([\s\S]*?)(\s*)$/.exec(text);
    return parts[2] ? parts[1] + mark + parts[2] + mark + parts[3] : text;
  }

  function ticks(text, least) {
    return "`".repeat((text.match(/`+/g) || []).reduce((most, run) => Math.max(most, run.length + 1), least));
  }

  function fenced(code, lang) {
    const fence = ticks(code, 3);
    return fence + (lang || "") + "\n" + code.replace(/\n$/, "") + "\n" + fence;
  }

  function listOf(node) {
    const ordered = node.tagName === "OL";
    let number = Number(node.getAttribute("start")) || 1;
    return Array.from(node.children).filter((item) => item.tagName === "LI").map((item) => {
      const marker = ordered ? number++ + ". " : "- ";
      const lines = tidy(inlineOf(item)).split("\n");
      return marker + lines.map((line, index) => (index === 0 || !line ? line : " ".repeat(marker.length) + line)).join("\n");
    }).join("\n");
  }

  function tableOf(node) {
    const rows = Array.from(node.querySelectorAll("tr"));
    const cell = (cell) => tidy(inlineOf(cell)).replace(/\n+/g, " ").replace(/\|/g, "\\|");
    const lines = rows.map((row) => "| " + Array.from(row.children).map(cell).join(" | ") + " |");
    if (rows.length && rows[0].parentElement.tagName === "THEAD") {
      lines.splice(1, 0, "| " + Array.from(rows[0].children).map(() => "---").join(" | ") + " |");
    }
    return lines.join("\n");
  }

  // Drawn HTML back to Markdown: blocks on lines of their own, formulas as their TeX.
  function markdownOf(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.textContent;
    if (node.nodeType !== Node.ELEMENT_NODE) return "";
    if (node.classList.contains("katex-display") || node.classList.contains("katex")) {
      const tex = node.querySelector("annotation[encoding='application/x-tex']");
      if (!tex) return "";
      return node.classList.contains("katex-display") || node.closest(".katex-display") ? "$$" + tex.textContent + "$$" : "$" + tex.textContent + "$";
    }
    if (node.classList.contains("code")) {
      const code = node.querySelector("pre");
      const lang = node.querySelector(".lang");
      return "\n" + fenced(code ? code.textContent : "", lang ? lang.textContent : "") + "\n\n";
    }
    const tag = node.tagName.toLowerCase();
    switch (tag) {
      case "strong":
      case "b":
        return enclosed("**", inlineOf(node));
      case "em":
      case "i":
        return enclosed("*", inlineOf(node));
      case "del":
      case "s":
        return enclosed("~~", inlineOf(node));
      case "code": {
        const text = node.textContent;
        const fence = ticks(text, 1);
        const pad = text.startsWith("`") || text.endsWith("`") ? " " : "";
        return fence + pad + text + pad + fence;
      }
      case "a": {
        const href = node.getAttribute("href") || "";
        const text = inlineOf(node);
        return !href || text === href ? text : "[" + text + "](" + href + ")";
      }
      case "img":
        return "![" + (node.getAttribute("alt") || "") + "](" + (node.getAttribute("src") || "") + ")";
      case "br":
        return "\n";
      case "input":
        return node.getAttribute("type") === "checkbox" ? (node.hasAttribute("checked") ? "[x] " : "[ ] ") : "";
      case "p":
      case "div":
        return "\n" + tidy(inlineOf(node)) + "\n\n";
      case "h1":
      case "h2":
      case "h3":
      case "h4":
      case "h5":
      case "h6":
        return "\n" + "#".repeat(Number(tag.charAt(1))) + " " + tidy(inlineOf(node)) + "\n\n";
      case "hr":
        return "\n---\n\n";
      case "ul":
      case "ol":
        return "\n" + listOf(node) + "\n\n";
      case "blockquote":
        return "\n" + tidy(inlineOf(node)).split("\n").map((line) => (line ? "> " + line : ">")).join("\n") + "\n\n";
      case "table":
        return "\n" + tableOf(node) + "\n\n";
      case "pre":
        return "\n" + fenced(node.textContent, "") + "\n\n";
      default:
        return inlineOf(node);
    }
  }

  // Moving on (to the message box), WebKit lets go of the page's selection: it
  // stays chosen all the same, and marked, until another is made here, or the
  // window says it's sent or dismissed (clearKept).
  let lastSelected = "";
  let lastRange = null;
  function keep(range) {
    if (!(window.CSS && CSS.highlights && window.Highlight)) return;
    if (range) CSS.highlights.set("kept", new Highlight(range));
    else CSS.highlights.delete("kept");
  }
  window.clearKept = function () {
    keep(null);
  };

  let selectionTimer = 0;
  document.addEventListener("selectionchange", () => {
    const selection = window.getSelection();
    if (selection && selection.rangeCount && !selection.isCollapsed) {
      lastRange = selection.getRangeAt(0).cloneRange();
    }
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => {
      const text = selectedText();
      if (!text && !document.hasFocus()) {
        // Gone because you went elsewhere, not unselected here: kept, and marked.
        if (lastSelected && lastRange) keep(lastRange);
        return;
      }
      keep(null);
      if (text === lastSelected) return;
      lastSelected = text;
      const handlers = window.webkit && window.webkit.messageHandlers;
      if (handlers && handlers.selection) handlers.selection.postMessage(text);
    }, 150);
  });
  window.addEventListener("blur", () => {
    if (lastSelected && lastRange) keep(lastRange);
  });

  new ResizeObserver(postHeight).observe(root);
  let lastWidth = 0;
  window.addEventListener("resize", () => {
    if (window.innerWidth !== lastWidth) {
      lastWidth = window.innerWidth;
      settle();
    }
  });
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(settle);
  }
})();
