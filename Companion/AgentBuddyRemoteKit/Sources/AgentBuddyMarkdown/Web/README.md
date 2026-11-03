Agent Buddy's answer renderer, loaded by `MarkdownView` in a WebKit view: everything here is bundled, nothing is fetched.

- `answer.html`, `answer.css`, `answer.js`: Agent Buddy's own.
- `katex/`: KaTeX 0.19.1 (MIT, see `katex/LICENSE`), its script, style and WOFF2 fonts, from https://cdn.jsdelivr.net/npm/katex@0.19.1/dist/.
- `marked/`: marked 18.1.1 (MIT, see `marked/LICENSE`), from https://cdn.jsdelivr.net/npm/marked@18.1.1/lib/marked.umd.js.
- `highlight/`: highlight.js 11.12.0 (BSD-3-Clause, see `highlight/LICENSE`), its common-languages build and GitHub light and dark styles, from https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.12.0/build/.
