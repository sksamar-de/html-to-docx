import Foundation

/// A minimalist DOM tree: just what the cascade and OOXML emitter need.
final class DOMNode {
    enum Kind {
        case element(tag: String)
        case text(String)
    }

    var kind: Kind
    var attributes: [String: String]
    var children: [DOMNode]
    weak var parent: DOMNode?

    init(kind: Kind, attributes: [String: String] = [:]) {
        self.kind = kind
        self.attributes = attributes
        self.children = []
    }

    var tagName: String? {
        if case .element(let t) = kind { return t }
        return nil
    }

    var classes: [String] {
        guard let raw = attributes["class"] else { return [] }
        return raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    var id: String? { attributes["id"] }

    var inlineStyle: [Declaration] {
        guard let raw = attributes["style"] else { return [] }
        return CSSDeclarationParser.parse(raw)
    }

    func appendChild(_ node: DOMNode) {
        node.parent = self
        children.append(node)
    }

    func walkElements(_ visit: (DOMNode) -> Void) {
        if case .element = kind { visit(self) }
        for c in children { c.walkElements(visit) }
    }
}

struct ParsedHTML {
    var root: DOMNode
    var stylesheet: Stylesheet
}

/// Forgiving HTML parser. Builds a DOM tree, harvests the contents of any
/// `<style>` element into a single stylesheet, and discards `<script>`.
///
/// We don't aim for full HTML5 spec compliance — just the behaviours real
/// pages depend on:
///   * void elements (br, img, hr, …) are auto-closed
///   * `<p>` is auto-closed when a new block-level element opens
///   * unknown / mismatched close tags are ignored gracefully
///   * comments, doctype and processing instructions are skipped
///   * named + numeric character entities are decoded
final class HTMLDOMParser {

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    /// Block-level tags that, when *opened*, implicitly close any open `<p>`.
    private static let blockLevelTags: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "dialog",
        "dd", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "h7",
        "header", "hgroup", "hr", "li", "main", "menu", "nav", "ol", "p",
        "pre", "section", "table", "ul"
    ]

    func parse(_ html: String) -> ParsedHTML {
        let scalars = Array(html.unicodeScalars)
        var i = 0
        let n = scalars.count
        if n > 0, scalars[0] == "\u{FEFF}" { i = 1 }

        let root = DOMNode(kind: .element(tag: "#document"))
        var stack: [DOMNode] = [root]
        var stylesheets: [String] = []

        // Buffer for accumulating text nodes (so consecutive text characters
        // don't each become a new node).
        var textBuffer = String.UnicodeScalarView()

        func flushText() {
            if textBuffer.isEmpty { return }
            let raw = String(textBuffer)
            textBuffer.removeAll(keepingCapacity: true)
            // Resolve `&amp;`, `&copy;`, numeric refs, etc.
            let decoded = HTMLEntities.decode(raw)
            stack.last?.appendChild(DOMNode(kind: .text(decoded)))
        }

        while i < n {
            let c = scalars[i]
            if c != "<" {
                textBuffer.append(c)
                i += 1
                continue
            }

            // We hit '<'. Disambiguate.
            if i + 3 < n, scalars[i + 1] == "!", scalars[i + 2] == "-", scalars[i + 3] == "-" {
                flushText()
                i += 4
                while i + 2 < n, !(scalars[i] == "-" && scalars[i + 1] == "-" && scalars[i + 2] == ">") {
                    i += 1
                }
                i = min(n, i + 3)
                continue
            }
            if i + 1 < n, scalars[i + 1] == "!" || scalars[i + 1] == "?" {
                flushText()
                while i < n, scalars[i] != ">" { i += 1 }
                if i < n { i += 1 }
                continue
            }

            // Closing tag.
            if i + 1 < n, scalars[i + 1] == "/" {
                flushText()
                let nameStart = i + 2
                var j = nameStart
                while j < n, isTagNameChar(scalars[j]) { j += 1 }
                let name = lowercaseASCII(scalars[nameStart..<j])
                while j < n, scalars[j] != ">" { j += 1 }
                if j < n { j += 1 }
                closeTag(named: name, stack: &stack)
                i = j
                continue
            }

            // Opening tag.
            let tagStart = i + 1
            var j = tagStart
            while j < n, isTagNameChar(scalars[j]) { j += 1 }
            if j == tagStart {
                // Stray '<' — treat as text.
                textBuffer.append(c)
                i += 1
                continue
            }
            let tagName = lowercaseASCII(scalars[tagStart..<j])

            // Read attributes up to '>' or '/>'.
            let (attrs, after, selfClosing) = parseAttributes(scalars, from: j, end: n)
            i = after

            flushText()

            // Implicit-close rules for sloppy HTML.
            applyImplicitCloses(opening: tagName, stack: &stack)

            // Special handling for raw-text containers.
            if tagName == "script" || tagName == "style" {
                // Read raw content until the matching close tag.
                let bodyStart = i
                var k = i
                while k < n {
                    if scalars[k] == "<", k + 1 < n, scalars[k + 1] == "/" {
                        let nm = readTagName(scalars, from: k + 2, end: n)
                        if nm.lowercased() == tagName { break }
                    }
                    k += 1
                }
                let body = String(String.UnicodeScalarView(scalars[bodyStart..<k]))
                if tagName == "style" {
                    stylesheets.append(body)
                }
                // Advance past closing tag.
                while k < n, scalars[k] != ">" { k += 1 }
                if k < n { k += 1 }
                i = k
                continue
            }

            // Build the element node.
            let element = DOMNode(kind: .element(tag: tagName), attributes: attrs)
            stack.last?.appendChild(element)

            // Void elements never push onto the stack.
            if !selfClosing, !Self.voidElements.contains(tagName) {
                stack.append(element)
            }
        }
        flushText()

        // Combine all <style> blocks into one stylesheet (preserving order).
        var combined = Stylesheet()
        var order = 0
        for src in stylesheets {
            let s = CSSStylesheetParser.parse(src, startingOrder: order)
            for r in s.rules {
                combined.rules.append(r)
                order = max(order, r.sourceOrder + 1)
            }
        }
        return ParsedHTML(root: root, stylesheet: combined)
    }

    // MARK: - Helpers

    private func closeTag(named name: String, stack: inout [DOMNode]) {
        // Walk down the open-element stack looking for a matching tag and
        // pop everything above it. If we never find it, do nothing (HTML
        // browsers do the same).
        var idx = stack.count - 1
        while idx >= 1 {
            if stack[idx].tagName == name {
                stack.removeSubrange(idx..<stack.count)
                return
            }
            idx -= 1
        }
    }

    private func applyImplicitCloses(opening name: String, stack: inout [DOMNode]) {
        guard Self.blockLevelTags.contains(name) else { return }
        if stack.last?.tagName == "p" {
            stack.removeLast()
            return
        }
        // li closes a sibling li.
        if name == "li", stack.last?.tagName == "li" {
            stack.removeLast()
        }
    }

    private func parseAttributes(_ s: [Unicode.Scalar],
                                 from: Int, end: Int)
        -> (attrs: [String: String], after: Int, selfClosing: Bool)
    {
        var i = from
        var attrs: [String: String] = [:]
        var selfClosing = false

        while i < end {
            // Skip whitespace.
            while i < end, isASCIIWhitespace(s[i]) { i += 1 }
            if i >= end { break }
            if s[i] == ">" { i += 1; break }
            if s[i] == "/" {
                selfClosing = true
                i += 1
                continue
            }

            // Read attribute name.
            let nameStart = i
            while i < end, !isASCIIWhitespace(s[i]),
                  s[i] != "=", s[i] != ">", s[i] != "/" { i += 1 }
            let name = lowercaseASCII(s[nameStart..<i])
            if name.isEmpty {
                i += 1
                continue
            }

            // Skip whitespace.
            while i < end, isASCIIWhitespace(s[i]) { i += 1 }

            var value = ""
            if i < end, s[i] == "=" {
                i += 1
                while i < end, isASCIIWhitespace(s[i]) { i += 1 }
                if i < end, (s[i] == "\"" || s[i] == "'") {
                    let quote = s[i]
                    i += 1
                    let valStart = i
                    while i < end, s[i] != quote { i += 1 }
                    value = String(String.UnicodeScalarView(s[valStart..<i]))
                    if i < end { i += 1 }
                } else {
                    let valStart = i
                    while i < end, !isASCIIWhitespace(s[i]), s[i] != ">" { i += 1 }
                    value = String(String.UnicodeScalarView(s[valStart..<i]))
                }
                value = HTMLEntities.decode(value)
            }

            attrs[name] = value
        }

        return (attrs, i, selfClosing)
    }

    private func readTagName(_ s: [Unicode.Scalar], from: Int, end: Int) -> String {
        var j = from
        while j < end, isTagNameChar(s[j]) { j += 1 }
        return lowercaseASCII(s[from..<j])
    }

    private func isTagNameChar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x30 && v <= 0x39) ||
               (v >= 0x41 && v <= 0x5A) ||
               (v >= 0x61 && v <= 0x7A) ||
               v == 0x2D
    }

    private func isASCIIWhitespace(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "\n" || s == "\r" || s == "\u{000C}"
    }

    private func lowercaseASCII(_ slice: ArraySlice<Unicode.Scalar>) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(slice.count)
        for s in slice {
            let v = s.value
            if v >= 0x41 && v <= 0x5A {
                out.append(Unicode.Scalar(v + 32)!)
            } else {
                out.append(s)
            }
        }
        return String(out)
    }
}

/// Decodes HTML named + numeric character references.
enum HTMLEntities {
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = String.UnicodeScalarView()
        result.reserveCapacity(s.unicodeScalars.count)
        let scalars = Array(s.unicodeScalars)
        var i = 0
        let n = scalars.count
        while i < n {
            if scalars[i] != "&" {
                result.append(scalars[i]); i += 1; continue
            }
            var end = i + 1
            let limit = min(n, i + 10)
            while end < limit, scalars[end] != ";" { end += 1 }
            if end >= n || scalars[end] != ";" {
                result.append(scalars[i]); i += 1; continue
            }
            let entity = String(String.UnicodeScalarView(scalars[(i + 1)..<end]))
            if let scalar = decodeEntity(entity) {
                result.append(scalar)
                i = end + 1
            } else {
                result.append(scalars[i]); i += 1
            }
        }
        return String(result)
    }

    static func decodeEntity(_ entity: String) -> Unicode.Scalar? {
        if entity.hasPrefix("#") {
            let body = entity.dropFirst()
            let cp: UInt32?
            if body.first == "x" || body.first == "X" {
                cp = UInt32(body.dropFirst(), radix: 16)
            } else {
                cp = UInt32(body, radix: 10)
            }
            if let v = cp, let s = Unicode.Scalar(v) { return s }
            return nil
        }
        switch entity {
        case "amp":   return "&"
        case "lt":    return "<"
        case "gt":    return ">"
        case "quot":  return "\""
        case "apos":  return "'"
        case "nbsp":  return Unicode.Scalar(0xA0)
        case "copy":  return Unicode.Scalar(0xA9)
        case "reg":   return Unicode.Scalar(0xAE)
        case "trade": return Unicode.Scalar(0x2122)
        case "hellip":return Unicode.Scalar(0x2026)
        case "mdash": return Unicode.Scalar(0x2014)
        case "ndash": return Unicode.Scalar(0x2013)
        case "lsquo": return Unicode.Scalar(0x2018)
        case "rsquo": return Unicode.Scalar(0x2019)
        case "ldquo": return Unicode.Scalar(0x201C)
        case "rdquo": return Unicode.Scalar(0x201D)
        case "laquo": return Unicode.Scalar(0xAB)
        case "raquo": return Unicode.Scalar(0xBB)
        case "middot":return Unicode.Scalar(0xB7)
        case "bull":  return Unicode.Scalar(0x2022)
        default: return nil
        }
    }
}
