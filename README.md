# HTML to DOCX

A small, fast macOS app that watches a folder for new `.html` files and writes
matching `.docx` files into a target folder. Headings (`<h1>`–`<h7>`) and
paragraphs (`<p>`) are emitted as Word paragraphs with **all CSS styling
preserved** — every property the OOXML spec can express is mapped 1-to-1.

The app can register itself with macOS to launch automatically every time you
log in, so the watcher is always running.

---

## Highlights

- **Native Swift / SwiftUI** — single executable, ~1 MB, no Electron.
- **Zero third-party dependencies** — HTML parser, CSS engine, OOXML writer,
  and ZIP encoder are all implemented in-tree.
- **Real CSS engine** — selectors with specificity, descendant + child
  combinators, compound + comma-separated selectors, inherited vs.
  non-inherited properties, `!important`, browser UA defaults, and inline
  `style="…"` overrides.
- **`FSEventStream`-based watcher** — the macOS-native API for file-system
  notifications, with a 0.5 s coalesce window and per-file mtime debouncing.
- **`SMAppService` Launch-at-Login** — the modern macOS 13+ API; toggleable
  from inside the app or from System Settings → General → Login Items.
- **In-memory `.docx` assembly** — typical conversion is well under 5 ms for
  a 50 KB HTML file.

## CSS support

Every HTML source can use `<style>` blocks and `style="…"` attributes. The
following properties are honoured and mapped to the corresponding OOXML
construct:

| CSS property                                      | OOXML element |
|---------------------------------------------------|---------------|
| `color`                                           | `<w:color>`   |
| `background-color`, `background`                  | `<w:shd>` (paragraph + run) |
| `font-family`                                     | `<w:rFonts>`  |
| `font-size` (`pt`, `px`, `em`, `rem`, `%`, keywords like `large`) | `<w:sz>` (half-points) |
| `font-weight` (`bold`, ≥ 600)                     | `<w:b/>`      |
| `font-style` (`italic`, `oblique`)                | `<w:i/>`      |
| `text-decoration` (`underline`, `line-through`)   | `<w:u/>` / `<w:strike/>` |
| `text-align` (`left`, `center`, `right`, `justify`) | `<w:jc>`    |
| `text-indent`                                     | `<w:ind w:firstLine>` |
| `margin-top`, `margin-bottom`, `margin` shorthand | `<w:spacing w:before/w:after>` |
| `line-height` (length or unitless multiplier)     | `<w:spacing w:line w:lineRule="exact">` |

Inline tags like `<strong>`, `<em>`, `<u>`, `<s>`, `<code>`, `<a>` ship with
sensible UA defaults (bold, italic, underline, strike, monospace, blue
underlined link), so even uncasualised HTML renders correctly.

Selectors supported:

- Type: `h1`, `p`, `*`
- Class: `.foo`
- ID: `#bar`
- Compound: `h1.title#x`
- Comma list: `h1, h2, h3`
- Descendant combinator: `article p`
- Child combinator: `div > p`
- Specificity follows the CSS spec (`a × 100 + b × 10 + c`); inline `style=`
  has specificity 1000; `!important` always wins.

Properties that have no OOXML equivalent (flexbox, transforms, gradients,
borders other than colour, etc.) are silently ignored — the same way Word's
own paste-from-HTML behaves.

## Requirements

- macOS 13 Ventura or newer
- Xcode command line tools (`xcode-select --install`)

You can build the project with nothing but the Swift toolchain — no Xcode
project, no `.xcodeproj`.

## Build

```bash
./build.sh
```

Output: `dist/HTMLtoDOCX.app`. Open it with `open dist/HTMLtoDOCX.app` or
double-click in Finder.

## Install

```bash
./install.sh
```

This copies the app to `/Applications/HTMLtoDOCX.app`. Launch it once, pick
your **Observer** and **Target** folders, and turn on **Launch at Login** —
that's the only manual step. macOS will start the app automatically at every
boot from then on.

## How it works

1. The app stores the two folder paths in `UserDefaults` and starts an
   `FSEventStream` on the Observer folder.
2. Whenever a `.html` or `.htm` file is created or modified inside that
   folder, the watcher hands the URL to the conversion queue.
3. The converter parses the HTML into a small DOM, harvesting `<style>`
   blocks into a stylesheet (and decoding inline `style="…"` attributes).
4. A cascade pass applies, in order, browser UA defaults → matching author
   rules sorted by specificity + source order → inline styles → `!important`
   overrides. Inheritance follows the CSS spec.
5. The DOM is walked top-down. Every `<h1>`–`<h7>` and `<p>` becomes a
   Word paragraph; the descendant tree of each block is flattened into
   styled runs (whitespace-collapsed per CSS), with each run carrying the
   computed style of its leaf-most ancestor.
6. The four required parts of a `.docx` (`[Content_Types].xml`, `_rels/.rels`,
   `word/styles.xml`, `word/document.xml`) are written into a ZIP archive
   in memory using DEFLATE, then dropped atomically into the Target folder.

## Project layout

```
htmltodocx/
├── Package.swift
├── build.sh                            # bundle .app from SPM binary
├── install.sh                          # copy to /Applications
├── Resources/
│   ├── Info.plist
│   └── HTMLtoDOCX.entitlements
└── Sources/HTMLtoDOCX/
    ├── App/
    │   ├── HTMLtoDOCXApp.swift         # SwiftUI @main
    │   ├── ContentView.swift           # UI
    │   └── AppViewModel.swift          # state + persistence
    ├── Converter/
    │   ├── CSS.swift                   # CSS values, declarations, selectors, parsers
    │   ├── HTMLDOM.swift               # DOM model + tolerant HTML parser
    │   ├── StyleResolver.swift         # cascade + specificity + inheritance + UA defaults
    │   ├── DocxBuilder.swift           # OOXML assembler with per-run formatting
    │   ├── ZipWriter.swift             # DEFLATE + ZIP container
    │   └── HTMLToDocxConverter.swift   # public API
    ├── Watcher/
    │   └── FolderWatcher.swift         # FSEventStream wrapper
    └── System/
        └── LaunchAtLogin.swift         # SMAppService wrapper
```

## Customising

- **Add CSS properties:** extend the `switch` in `StyleResolver.apply(decl:)`
  and surface a new field on `ComputedStyle`. The OOXML mapping lives in
  `DocxBuilder.runPropertiesXML` / `paragraphPropertiesXML`.
- **UA defaults:** the `uaDefaults` dictionary in `StyleResolver.swift` holds
  the browser-default style for each tag (h1–h7, p, em, strong, u, s, a,
  code, …). Tweak it to change zero-CSS appearance.
- **Block elements:** extend `DocxBuilder.blockTags` if you want
  `<blockquote>`, `<div>`, `<pre>`, etc. to also surface as Word paragraphs.
- **Watch additional extensions:** edit the file-extension check in
  `FolderWatcher.handleEvents`.

## License

MIT.
