import Foundation

// MARK: - Color

/// 24-bit RGB. We discard alpha because Word's text colour can't render it.
struct CSSColor: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var hex: String { String(format: "%02X%02X%02X", r, g, b) }

    static let black = CSSColor(r: 0, g: 0, b: 0)
    static let white = CSSColor(r: 255, g: 255, b: 255)

    /// Parses any commonly-used CSS colour: `#abc`, `#aabbcc`, `rgb(...)`,
    /// `rgba(...)`, or one of the named CSS colours we know about.
    static func parse(_ raw: String) -> CSSColor? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return nil }

        if s.hasPrefix("#") {
            let h = String(s.dropFirst())
            if h.count == 3, let v = UInt32(h, radix: 16) {
                let r = (v >> 8) & 0xF, g = (v >> 4) & 0xF, b = v & 0xF
                return CSSColor(r: UInt8(r * 17), g: UInt8(g * 17), b: UInt8(b * 17))
            }
            if h.count == 6, let v = UInt32(h, radix: 16) {
                return CSSColor(r: UInt8((v >> 16) & 0xFF),
                                g: UInt8((v >> 8) & 0xFF),
                                b: UInt8(v & 0xFF))
            }
            return nil
        }

        if s.hasPrefix("rgb") {
            guard let open = s.firstIndex(of: "("),
                  let close = s.firstIndex(of: ")") else { return nil }
            let inner = s[s.index(after: open)..<close]
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count >= 3 else { return nil }
            func channel(_ s: String) -> UInt8 {
                if s.hasSuffix("%") {
                    let pct = Double(s.dropLast()) ?? 0
                    return UInt8(max(0, min(255, pct * 255 / 100)))
                }
                let v = Double(s) ?? 0
                return UInt8(max(0, min(255, v)))
            }
            return CSSColor(r: channel(parts[0]),
                            g: channel(parts[1]),
                            b: channel(parts[2]))
        }

        return named[s]
    }

    /// A working subset of the CSS named colours — covers the ones almost
    /// every page actually uses. Missing entries simply fall through and the
    /// declaration is ignored, which is the same as Word's behaviour for
    /// unknown styles.
    static let named: [String: CSSColor] = [
        "transparent": CSSColor(r: 255, g: 255, b: 255),
        "black":   CSSColor(r: 0,   g: 0,   b: 0),
        "white":   CSSColor(r: 255, g: 255, b: 255),
        "silver":  CSSColor(r: 192, g: 192, b: 192),
        "gray":    CSSColor(r: 128, g: 128, b: 128),
        "grey":    CSSColor(r: 128, g: 128, b: 128),
        "darkgray":CSSColor(r: 169, g: 169, b: 169),
        "lightgray":CSSColor(r: 211, g: 211, b: 211),
        "red":     CSSColor(r: 255, g: 0,   b: 0),
        "darkred": CSSColor(r: 139, g: 0,   b: 0),
        "maroon":  CSSColor(r: 128, g: 0,   b: 0),
        "orange":  CSSColor(r: 255, g: 165, b: 0),
        "yellow":  CSSColor(r: 255, g: 255, b: 0),
        "olive":   CSSColor(r: 128, g: 128, b: 0),
        "lime":    CSSColor(r: 0,   g: 255, b: 0),
        "green":   CSSColor(r: 0,   g: 128, b: 0),
        "darkgreen":CSSColor(r: 0,  g: 100, b: 0),
        "teal":    CSSColor(r: 0,   g: 128, b: 128),
        "cyan":    CSSColor(r: 0,   g: 255, b: 255),
        "aqua":    CSSColor(r: 0,   g: 255, b: 255),
        "blue":    CSSColor(r: 0,   g: 0,   b: 255),
        "navy":    CSSColor(r: 0,   g: 0,   b: 128),
        "darkblue":CSSColor(r: 0,   g: 0,   b: 139),
        "royalblue":CSSColor(r: 65, g: 105, b: 225),
        "skyblue": CSSColor(r: 135, g: 206, b: 235),
        "lightblue":CSSColor(r: 173, g: 216, b: 230),
        "purple":  CSSColor(r: 128, g: 0,   b: 128),
        "violet":  CSSColor(r: 238, g: 130, b: 238),
        "magenta": CSSColor(r: 255, g: 0,   b: 255),
        "fuchsia": CSSColor(r: 255, g: 0,   b: 255),
        "pink":    CSSColor(r: 255, g: 192, b: 203),
        "brown":   CSSColor(r: 165, g: 42,  b: 42),
        "tan":     CSSColor(r: 210, g: 180, b: 140),
        "beige":   CSSColor(r: 245, g: 245, b: 220),
        "gold":    CSSColor(r: 255, g: 215, b: 0)
    ]
}

// MARK: - Length

/// CSS length, normalised to absolute points where possible. Relative units
/// (em, %, rem) are resolved later by the cascade with reference to the
/// inherited font-size.
struct CSSLength: Equatable {
    enum Unit { case pt, px, em, rem, percent }

    var value: Double
    var unit: Unit

    /// Convert to absolute points using the given parent font-size in points.
    /// `relativeTo` is also used as the reference for `%`.
    func points(relativeTo parentPt: Double, rootPt: Double = 16.0) -> Double {
        switch unit {
        case .pt:      return value
        case .px:      return value * 0.75   // 96 DPI: 1px = 0.75pt
        case .em:      return value * parentPt
        case .rem:     return value * rootPt
        case .percent: return value / 100.0 * parentPt
        }
    }

    static func parse(_ raw: String) -> CSSLength? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }
        if s == "0" { return CSSLength(value: 0, unit: .pt) }

        let suffixes: [(String, Unit)] = [
            ("rem", .rem), ("em", .em), ("px", .px), ("pt", .pt), ("%", .percent)
        ]
        for (suffix, unit) in suffixes where s.hasSuffix(suffix) {
            let numPart = s.dropLast(suffix.count)
            if let v = Double(numPart) {
                return CSSLength(value: v, unit: unit)
            }
        }
        if let v = Double(s) {
            return CSSLength(value: v, unit: .px)
        }
        return nil
    }
}

// MARK: - Declarations

struct Declaration: Equatable {
    var property: String     // already lowercased, hyphenated
    var value: String        // raw, trimmed
    var important: Bool
}

/// Parses an inline style attribute value (e.g. `color:red;font-weight:bold`).
enum CSSDeclarationParser {
    static func parse(_ source: String) -> [Declaration] {
        var out: [Declaration] = []
        for chunk in source.split(separator: ";") {
            guard let colon = chunk.firstIndex(of: ":") else { continue }
            let name = chunk[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = chunk[chunk.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var important = false
            if let bangRange = value.range(of: "!important", options: .caseInsensitive) {
                important = true
                value = String(value[..<bangRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !name.isEmpty, !value.isEmpty {
                out.append(Declaration(property: name, value: value, important: important))
            }
        }
        return out
    }
}

// MARK: - Selectors

struct SimpleSelector: Equatable {
    var typeName: String?
    var id: String?
    var classes: [String]
}

struct ComplexSelector: Equatable {
    enum Combinator: Equatable { case descendant, child }
    var parts: [SimpleSelector]            // parts.first is leftmost
    var combinators: [Combinator]          // combinators[i] sits between parts[i] and parts[i+1]

    /// Standard CSS specificity: ID×100 + class×10 + type×1.
    var specificity: Int {
        var spec = 0
        for p in parts {
            if p.id != nil { spec += 100 }
            spec += p.classes.count * 10
            if p.typeName != nil { spec += 1 }
        }
        return spec
    }
}

struct Rule {
    var selectors: [ComplexSelector]
    var declarations: [Declaration]
    var sourceOrder: Int
}

struct Stylesheet {
    var rules: [Rule] = []
}

// MARK: - Stylesheet parser

enum CSSStylesheetParser {
    static func parse(_ source: String, startingOrder: Int = 0) -> Stylesheet {
        var sheet = Stylesheet()
        let scalars = Array(source.unicodeScalars)
        var i = 0
        let n = scalars.count
        var order = startingOrder

        while i < n {
            // Skip whitespace and comments.
            i = skipWhitespaceAndComments(scalars, from: i, end: n)
            if i >= n { break }

            // Skip @-rules (e.g. @media, @import) by reading to the next ; or balanced block.
            if scalars[i] == "@" {
                i = skipAtRule(scalars, from: i, end: n)
                continue
            }

            // Read selector text up to '{'.
            let selectorStart = i
            while i < n, scalars[i] != "{" { i += 1 }
            if i >= n { break }
            let selectorText = String(String.UnicodeScalarView(scalars[selectorStart..<i]))
            i += 1 // consume '{'

            // Read declarations until '}'.
            let declStart = i
            var depth = 1
            while i < n, depth > 0 {
                if scalars[i] == "{" { depth += 1 }
                else if scalars[i] == "}" { depth -= 1; if depth == 0 { break } }
                i += 1
            }
            let declText = String(String.UnicodeScalarView(scalars[declStart..<i]))
            if i < n { i += 1 } // consume '}'

            let selectors = parseSelectorList(selectorText)
            let declarations = CSSDeclarationParser.parse(declText)
            if !selectors.isEmpty, !declarations.isEmpty {
                sheet.rules.append(Rule(selectors: selectors,
                                        declarations: declarations,
                                        sourceOrder: order))
                order += 1
            }
        }
        return sheet
    }

    // MARK: -

    private static func skipWhitespaceAndComments(_ s: [Unicode.Scalar],
                                                  from: Int, end: Int) -> Int {
        var i = from
        while i < end {
            let c = s[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                i += 1
            } else if c == "/", i + 1 < end, s[i + 1] == "*" {
                i += 2
                while i + 1 < end, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                i = min(end, i + 2)
            } else {
                break
            }
        }
        return i
    }

    private static func skipAtRule(_ s: [Unicode.Scalar], from: Int, end: Int) -> Int {
        var i = from
        // skip until `;` or first `{` then balanced `}`.
        while i < end, s[i] != ";", s[i] != "{" { i += 1 }
        if i < end, s[i] == ";" { return i + 1 }
        if i < end, s[i] == "{" {
            var depth = 1
            i += 1
            while i < end, depth > 0 {
                if s[i] == "{" { depth += 1 }
                else if s[i] == "}" { depth -= 1 }
                i += 1
            }
        }
        return i
    }

    static func parseSelectorList(_ raw: String) -> [ComplexSelector] {
        var out: [ComplexSelector] = []
        for part in raw.split(separator: ",") {
            if let sel = parseComplex(String(part)) {
                out.append(sel)
            }
        }
        return out
    }

    private static func parseComplex(_ raw: String) -> ComplexSelector? {
        var parts: [SimpleSelector] = []
        var combinators: [ComplexSelector.Combinator] = []

        // Tokenise on whitespace and `>`. Multiple spaces collapse to one.
        var current = ""
        var pendingCombinator: ComplexSelector.Combinator? = nil
        var sawSpace = false

        func flushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, let s = parseSimple(trimmed) {
                if !parts.isEmpty {
                    combinators.append(pendingCombinator ?? .descendant)
                }
                parts.append(s)
            }
            current = ""
            pendingCombinator = nil
        }

        for ch in raw {
            if ch == ">" {
                flushCurrent()
                pendingCombinator = .child
                sawSpace = false
            } else if ch == " " || ch == "\t" || ch == "\n" {
                if !current.isEmpty { sawSpace = true }
            } else {
                if sawSpace, !current.isEmpty {
                    flushCurrent()
                    if pendingCombinator == nil { pendingCombinator = .descendant }
                    sawSpace = false
                }
                current.append(ch)
            }
        }
        flushCurrent()

        guard !parts.isEmpty else { return nil }
        return ComplexSelector(parts: parts, combinators: combinators)
    }

    /// Parses a single simple selector like `h1`, `.foo`, `#bar`, `h1.foo#bar`.
    private static func parseSimple(_ raw: String) -> SimpleSelector? {
        if raw == "*" { return SimpleSelector(typeName: nil, id: nil, classes: []) }

        var typeName: String? = nil
        var id: String? = nil
        var classes: [String] = []

        var i = raw.startIndex
        let end = raw.endIndex

        // Optional leading type selector.
        var typeBuf = ""
        while i < end {
            let ch = raw[i]
            if ch == "." || ch == "#" || ch == "[" || ch == ":" { break }
            typeBuf.append(ch)
            i = raw.index(after: i)
        }
        if !typeBuf.isEmpty { typeName = typeBuf.lowercased() }

        while i < end {
            let ch = raw[i]
            if ch == "." {
                i = raw.index(after: i)
                var name = ""
                while i < end, raw[i] != ".", raw[i] != "#", raw[i] != "[", raw[i] != ":" {
                    name.append(raw[i]); i = raw.index(after: i)
                }
                if !name.isEmpty { classes.append(name) }
            } else if ch == "#" {
                i = raw.index(after: i)
                var name = ""
                while i < end, raw[i] != ".", raw[i] != "#", raw[i] != "[", raw[i] != ":" {
                    name.append(raw[i]); i = raw.index(after: i)
                }
                if !name.isEmpty { id = name }
            } else {
                // Attribute or pseudo: skip — we don't support them.
                i = raw.index(after: i)
            }
        }

        if typeName == nil, id == nil, classes.isEmpty { return nil }
        return SimpleSelector(typeName: typeName, id: id, classes: classes)
    }
}
