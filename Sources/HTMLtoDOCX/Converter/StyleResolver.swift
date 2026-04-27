import Foundation

// MARK: - ComputedStyle

enum TextAlign: String { case left, center, right, justify }

/// The fully-resolved style for a single DOM node. We split by inheritance
/// behaviour so children can ask the parent for the inheritable subset.
struct ComputedStyle: Equatable {
    // Inheritable.
    var fontFamily: String? = nil
    var fontSizePt: Double = 11.0
    var bold: Bool = false
    var italic: Bool = false
    var color: CSSColor = .black
    var textAlign: TextAlign? = nil
    var lineHeightPt: Double? = nil

    // Non-inheritable.
    var underline: Bool = false
    var strikethrough: Bool = false
    var background: CSSColor? = nil
    var marginTopPt: Double? = nil
    var marginBottomPt: Double? = nil
    var textIndentPt: Double? = nil

    /// The starting "default" style applied to the document root.
    static let documentRoot = ComputedStyle(
        fontFamily: nil,
        fontSizePt: 11.0,
        bold: false,
        italic: false,
        color: .black,
        textAlign: nil,
        lineHeightPt: nil,
        underline: false,
        strikethrough: false,
        background: nil,
        marginTopPt: nil,
        marginBottomPt: nil,
        textIndentPt: nil
    )
}

// MARK: - User-agent defaults

/// Built-in stylesheet that mirrors what every browser ships with. We only
/// cover the elements we actually care about — h1–h6/h7, p, plus the common
/// inline tags so that bare `<em>`, `<strong>`, `<u>`, `<s>`, and `<a>` look
/// right without the author having to provide CSS.
private struct UADefault {
    var bold: Bool? = nil
    var italic: Bool? = nil
    var underline: Bool? = nil
    var strikethrough: Bool? = nil
    var sizeMultiplier: Double? = nil   // multiplied with the *root* font-size
    var marginEM: (top: Double, bottom: Double)? = nil
    var color: CSSColor? = nil
    var monospace: Bool = false
}

private let uaDefaults: [String: UADefault] = [
    "h1": UADefault(bold: true, sizeMultiplier: 2.00, marginEM: (0.67, 0.67)),
    "h2": UADefault(bold: true, sizeMultiplier: 1.50, marginEM: (0.83, 0.83)),
    "h3": UADefault(bold: true, sizeMultiplier: 1.17, marginEM: (1.00, 1.00)),
    "h4": UADefault(bold: true, sizeMultiplier: 1.00, marginEM: (1.33, 1.33)),
    "h5": UADefault(bold: true, sizeMultiplier: 0.83, marginEM: (1.67, 1.67)),
    "h6": UADefault(bold: true, sizeMultiplier: 0.67, marginEM: (2.33, 2.33)),
    "h7": UADefault(bold: true, sizeMultiplier: 0.60, marginEM: (2.50, 2.50)),
    "p":  UADefault(marginEM: (1.00, 1.00)),
    "b":      UADefault(bold: true),
    "strong": UADefault(bold: true),
    "i":      UADefault(italic: true),
    "em":     UADefault(italic: true),
    "u":      UADefault(underline: true),
    "ins":    UADefault(underline: true),
    "s":      UADefault(strikethrough: true),
    "del":    UADefault(strikethrough: true),
    "strike": UADefault(strikethrough: true),
    "a":      UADefault(underline: true, color: CSSColor(r: 0, g: 0, b: 238)),
    "code":   UADefault(monospace: true),
    "kbd":    UADefault(monospace: true),
    "samp":   UADefault(monospace: true),
    "pre":    UADefault(monospace: true, marginEM: (1.0, 1.0)),
    "tt":     UADefault(monospace: true)
]

// MARK: - StyleResolver

final class StyleResolver {
    let stylesheet: Stylesheet
    private let rootFontSize: Double
    private var cache: [ObjectIdentifier: ComputedStyle] = [:]

    init(stylesheet: Stylesheet, rootFontSize: Double = 11.0) {
        self.stylesheet = stylesheet
        self.rootFontSize = rootFontSize
    }

    /// Returns the fully-resolved style for `node`. Caches per-node so that
    /// asking repeatedly is cheap.
    func compute(for node: DOMNode) -> ComputedStyle {
        let key = ObjectIdentifier(node)
        if let cached = cache[key] { return cached }
        let result = computeUncached(for: node)
        cache[key] = result
        return result
    }

    private func computeUncached(for node: DOMNode) -> ComputedStyle {
        // Root document (or text node directly under root).
        guard let parent = node.parent else {
            var root = ComputedStyle()
            root.fontSizePt = rootFontSize
            return root
        }

        // 1. Start from inheritable parent state.
        let parentStyle = compute(for: parent)
        var style = ComputedStyle(
            fontFamily: parentStyle.fontFamily,
            fontSizePt: parentStyle.fontSizePt,
            bold: parentStyle.bold,
            italic: parentStyle.italic,
            color: parentStyle.color,
            textAlign: parentStyle.textAlign,
            lineHeightPt: parentStyle.lineHeightPt,
            underline: false,
            strikethrough: false,
            background: nil,
            marginTopPt: nil,
            marginBottomPt: nil,
            textIndentPt: nil
        )

        // 2. UA defaults for the element's tag.
        guard case .element(let tag) = node.kind else { return style }
        if let ua = uaDefaults[tag] {
            applyUA(ua, into: &style, parentSize: parentStyle.fontSizePt)
        }

        // 3. Author rules from <style>, ordered by specificity then source order.
        let matching = matchingDeclarations(for: node)
        for decl in matching {
            apply(decl: decl, into: &style, parentSize: parentStyle.fontSizePt)
        }

        // 4. Inline `style` attribute always wins over plain author rules
        //    (specificity 1000), but `!important` from the cascade still
        //    bubbles past it. We re-apply !important author rules on top.
        for decl in node.inlineStyle where !decl.important {
            apply(decl: decl, into: &style, parentSize: parentStyle.fontSizePt)
        }
        for decl in matching where decl.important {
            apply(decl: decl, into: &style, parentSize: parentStyle.fontSizePt)
        }
        for decl in node.inlineStyle where decl.important {
            apply(decl: decl, into: &style, parentSize: parentStyle.fontSizePt)
        }

        return style
    }

    // MARK: - Selector matching

    private func matchingDeclarations(for node: DOMNode) -> [Declaration] {
        // (specificity, sourceOrder, declaration)
        var hits: [(Int, Int, [Declaration])] = []
        for rule in stylesheet.rules {
            for sel in rule.selectors where matches(sel, node: node) {
                hits.append((sel.specificity, rule.sourceOrder, rule.declarations))
            }
        }
        hits.sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        return hits.flatMap { $0.2 }
    }

    private func matches(_ selector: ComplexSelector, node: DOMNode) -> Bool {
        let parts = selector.parts
        guard !parts.isEmpty else { return false }

        // Right-to-left match.
        var current: DOMNode? = node
        for i in stride(from: parts.count - 1, through: 0, by: -1) {
            let part = parts[i]
            if i == parts.count - 1 {
                guard let cur = current, simpleMatches(part, cur) else { return false }
                current = cur.parent
                continue
            }

            let combinator = selector.combinators[i] // between parts[i] and parts[i+1]
            if combinator == .child {
                guard let cur = current, simpleMatches(part, cur) else { return false }
                current = cur.parent
            } else {
                var found: DOMNode? = nil
                var c = current
                while let cc = c {
                    if simpleMatches(part, cc) { found = cc; break }
                    c = cc.parent
                }
                guard let f = found else { return false }
                current = f.parent
            }
        }
        return true
    }

    private func simpleMatches(_ s: SimpleSelector, _ node: DOMNode) -> Bool {
        guard case .element(let tag) = node.kind else { return false }
        if let t = s.typeName, t != tag { return false }
        if let id = s.id, node.id != id { return false }
        if !s.classes.isEmpty {
            let nodeClasses = Set(node.classes)
            for c in s.classes where !nodeClasses.contains(c) { return false }
        }
        return true
    }

    // MARK: - Applying declarations

    private func applyUA(_ ua: UADefault,
                         into style: inout ComputedStyle,
                         parentSize: Double) {
        if let b = ua.bold { style.bold = b }
        if let i = ua.italic { style.italic = i }
        if let u = ua.underline { style.underline = u }
        if let s = ua.strikethrough { style.strikethrough = s }
        if let mult = ua.sizeMultiplier {
            // Browser UA `font-size: 2em` etc. — relative to *parent*, not root.
            style.fontSizePt = parentSize * mult
        }
        // Heading margins are em-relative to the element's own (just-set)
        // font-size, mirroring how browsers compute them.
        if let m = ua.marginEM {
            style.marginTopPt = style.fontSizePt * m.top
            style.marginBottomPt = style.fontSizePt * m.bottom
        }
        if let c = ua.color { style.color = c }
        if ua.monospace, style.fontFamily == nil {
            style.fontFamily = "Menlo, Monaco, Consolas, monospace"
        }
    }

    private func apply(decl: Declaration,
                       into style: inout ComputedStyle,
                       parentSize: Double) {
        let value = decl.value
        // For non-font-size properties, em/% resolve against the element's
        // own (already computed) font-size. For font-size itself, em/%
        // resolve against the parent's size.
        let ownSize = style.fontSizePt

        switch decl.property {
        case "color":
            if let c = CSSColor.parse(value) { style.color = c }
        case "background-color", "background":
            if let c = CSSColor.parse(extractColor(from: value)) { style.background = c }
        case "font-family":
            style.fontFamily = firstFontFamily(from: value)
        case "font-size":
            if let len = CSSLength.parse(value) {
                style.fontSizePt = len.points(relativeTo: parentSize, rootPt: rootFontSize)
            } else if let kw = keywordFontSize(value) {
                style.fontSizePt = kw
            }
        case "font-weight":
            style.bold = isBold(value)
        case "font-style":
            style.italic = (value == "italic" || value == "oblique")
        case "text-decoration", "text-decoration-line":
            style.underline     = value.contains("underline")
            style.strikethrough = value.contains("line-through")
        case "text-align":
            if let a = TextAlign(rawValue: value) { style.textAlign = a }
        case "text-indent":
            if let len = CSSLength.parse(value) {
                style.textIndentPt = len.points(relativeTo: ownSize, rootPt: rootFontSize)
            }
        case "margin-top":
            if let len = CSSLength.parse(value) {
                style.marginTopPt = len.points(relativeTo: ownSize, rootPt: rootFontSize)
            }
        case "margin-bottom":
            if let len = CSSLength.parse(value) {
                style.marginBottomPt = len.points(relativeTo: ownSize, rootPt: rootFontSize)
            }
        case "margin":
            // CSS shorthand: 1 value = all; 2 = vertical/horizontal;
            // 3 = T H B; 4 = T R B L.
            let parts = value.split(separator: " ").map(String.init)
            if parts.isEmpty { break }
            let topRaw = parts[0]
            let bottomRaw: String
            switch parts.count {
            case 1, 2:           bottomRaw = parts[0]
            case 3:              bottomRaw = parts[2]
            default:             bottomRaw = parts[2]
            }
            if let len = CSSLength.parse(topRaw) {
                style.marginTopPt = len.points(relativeTo: ownSize, rootPt: rootFontSize)
            }
            if let len = CSSLength.parse(bottomRaw) {
                style.marginBottomPt = len.points(relativeTo: ownSize, rootPt: rootFontSize)
            }
        case "line-height":
            if let multiplier = Double(value) {
                // Unitless multiplier — resolve against own font-size.
                style.lineHeightPt = ownSize * multiplier
            } else if let len = CSSLength.parse(value) {
                style.lineHeightPt = len.points(relativeTo: ownSize, rootPt: rootFontSize)
            }
        default:
            break
        }
    }

    // MARK: - Tiny value helpers

    private func isBold(_ v: String) -> Bool {
        if v == "bold" || v == "bolder" { return true }
        if let n = Int(v) { return n >= 600 }
        return false
    }

    private func keywordFontSize(_ v: String) -> Double? {
        switch v {
        case "xx-small": return rootFontSize * 0.6
        case "x-small":  return rootFontSize * 0.75
        case "small":    return rootFontSize * 0.875
        case "medium":   return rootFontSize
        case "large":    return rootFontSize * 1.125
        case "x-large":  return rootFontSize * 1.5
        case "xx-large": return rootFontSize * 2.0
        case "smaller":  return rootFontSize * 0.83
        case "larger":   return rootFontSize * 1.2
        default: return nil
        }
    }

    private func firstFontFamily(from raw: String) -> String {
        // Strip quotes, split on comma, take the first non-generic name.
        let parts = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return parts.first ?? raw
    }

    /// `background: red none repeat` → `red`. Picks the first colour-shaped
    /// token from a shorthand `background` value.
    private func extractColor(from raw: String) -> String {
        for token in raw.split(whereSeparator: { $0 == " " }) {
            let t = String(token).trimmingCharacters(in: .whitespaces)
            if CSSColor.parse(t) != nil { return t }
        }
        return raw
    }
}
