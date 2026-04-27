import Foundation

/// Walks a parsed HTML DOM, asks `StyleResolver` for each node's computed
/// style, and emits the four OOXML parts that make up a `.docx`.
///
/// Only `<h1>`–`<h7>` and `<p>` are emitted as Word paragraphs (matching the
/// original product spec); inside those, every CSS-supported inline
/// formatting is preserved at the run level.
enum DocxBuilder {

    static func buildArchiveFiles(
        from parsed: ParsedHTML,
        resolver: StyleResolver
    ) -> (entries: [(name: String, data: Data)], blockCount: Int) {

        let blocks = collectBlocks(parsed.root)
        let body = documentXML(blocks: blocks, resolver: resolver)

        // The order of parts inside the ZIP doesn't matter to Word, but the
        // relationship graph does: every part declared in
        // `[Content_Types].xml` must be reachable from the package root via
        // a `.rels` chain. We provide the package-root `_rels/.rels` linking
        // to `document.xml`, plus `word/_rels/document.xml.rels` linking
        // `document.xml` to `styles.xml`.
        let entries: [(String, Data)] = [
            ("[Content_Types].xml",        Data(contentTypesXML.utf8)),
            ("_rels/.rels",                Data(rootRelsXML.utf8)),
            ("word/_rels/document.xml.rels", Data(documentRelsXML.utf8)),
            ("word/styles.xml",            Data(stylesXML.utf8)),
            ("word/document.xml",          Data(body.utf8))
        ]
        return (entries, blocks.count)
    }

    // MARK: - Collecting block elements

    private static let blockTags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "h7", "p"
    ]

    private static func collectBlocks(_ root: DOMNode) -> [DOMNode] {
        var out: [DOMNode] = []
        func walk(_ n: DOMNode) {
            if case .element(let tag) = n.kind, blockTags.contains(tag) {
                out.append(n)
                // Don't descend further: we already capture descendants
                // via tokenize() per block.
                return
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        return out
    }

    // MARK: - Static parts

    private static let contentTypesXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
</Types>
"""

    private static let rootRelsXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
"""

    /// Document-scoped relationships. Required by the OPC spec so Word
    /// doesn't treat `styles.xml` as an orphan part.
    private static let documentRelsXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
"""

    /// We push *all* styling into direct formatting on each <w:p>/<w:r>, so
    /// styles.xml only needs to define the implicit Normal style. This is the
    /// minimum Word will accept.
    /// Children of `<w:rPr>` here are in schema order (color before sz).
    private static let stylesXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults>
    <w:rPrDefault><w:rPr><w:color w:val="000000"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault>
    <w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>
  </w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
    <w:name w:val="Normal"/>
  </w:style>
</w:styles>
"""

    // MARK: - document.xml

    private static func documentXML(blocks: [DOMNode], resolver: StyleResolver) -> String {
        var body = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
"""
        if blocks.isEmpty {
            body += "\n    <w:p/>"
        } else {
            for block in blocks {
                body += paragraphXML(block: block, resolver: resolver)
            }
        }
        body += """

    <w:sectPr>
      <w:pgSz w:w="12240" w:h="15840"/>
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
    </w:sectPr>
  </w:body>
</w:document>
"""
        return body
    }

    private static func paragraphXML(block: DOMNode, resolver: StyleResolver) -> String {
        let pStyle = resolver.compute(for: block)
        let tokens = tokenize(block: block, resolver: resolver)
        let runs = collapseWhitespace(tokens: tokens)

        var out = "\n    <w:p>"
        out += paragraphPropertiesXML(pStyle)
        if runs.isEmpty {
            // Empty paragraph still needs a self-closed <w:p/>-equivalent.
            out += "</w:p>"
            return out
        }
        for run in runs {
            out += runXML(run, paragraphStyle: pStyle)
        }
        out += "</w:p>"
        return out
    }

    // MARK: - Inline tokenization

    private struct InlineToken {
        enum Kind { case text(String), lineBreak }
        var kind: Kind
        var style: ComputedStyle
    }

    /// Pre-order walk of the block's descendants, producing a flat sequence
    /// of text fragments and explicit `<br>` markers. Each fragment carries
    /// the computed style of its leaf-most ancestor.
    private static func tokenize(block: DOMNode, resolver: StyleResolver) -> [InlineToken] {
        var tokens: [InlineToken] = []
        func walk(_ node: DOMNode) {
            switch node.kind {
            case .text(let s):
                if s.isEmpty { return }
                guard let parent = node.parent else { return }
                let style = resolver.compute(for: parent)
                tokens.append(InlineToken(kind: .text(s), style: style))
            case .element(let tag):
                if tag == "br" {
                    let style = resolver.compute(for: node)
                    tokens.append(InlineToken(kind: .lineBreak, style: style))
                    return
                }
                for c in node.children { walk(c) }
            }
        }
        for c in block.children { walk(c) }
        return tokens
    }

    private struct RenderRun {
        enum Content { case text(String), lineBreak }
        var content: Content
        var style: ComputedStyle
    }

    /// Applies CSS-style whitespace collapsing across the token stream:
    /// leading/trailing whitespace at the block boundary is dropped, and
    /// internal runs of whitespace collapse to a single space — but the
    /// *style* of the emitted space comes from the surrounding text.
    private static func collapseWhitespace(tokens: [InlineToken]) -> [RenderRun] {
        var runs: [RenderRun] = []
        var lastEndedInSpace = true   // suppress leading whitespace
        for token in tokens {
            switch token.kind {
            case .lineBreak:
                runs.append(RenderRun(content: .lineBreak, style: token.style))
                lastEndedInSpace = true
            case .text(let raw):
                let collapsed = collapse(raw, leadingSpaceAllowed: !lastEndedInSpace)
                if collapsed.isEmpty { continue }
                lastEndedInSpace = collapsed.last == " "
                runs.append(RenderRun(content: .text(collapsed), style: token.style))
            }
        }

        // Trim trailing whitespace on the final text run.
        if let last = runs.indices.last {
            if case .text(var s) = runs[last].content, s.hasSuffix(" ") {
                s.removeLast()
                if s.isEmpty {
                    runs.removeLast()
                } else {
                    runs[last] = RenderRun(content: .text(s), style: runs[last].style)
                }
            }
        }

        // Merge consecutive text runs that share a style.
        var merged: [RenderRun] = []
        for run in runs {
            if case .text(let s) = run.content,
               let prevIdx = merged.indices.last,
               case .text(let prev) = merged[prevIdx].content,
               merged[prevIdx].style == run.style {
                merged[prevIdx] = RenderRun(content: .text(prev + s), style: run.style)
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    private static func collapse(_ s: String, leadingSpaceAllowed: Bool) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        var sawSpace = !leadingSpaceAllowed
        for u in s.unicodeScalars {
            let isWS = (u == " " || u == "\t" || u == "\n" || u == "\r")
            if isWS {
                if !sawSpace, !out.isEmpty || leadingSpaceAllowed {
                    out.append(" ")
                }
                sawSpace = true
            } else {
                out.append(u)
                sawSpace = false
            }
        }
        return String(out)
    }

    // MARK: - OOXML run + paragraph property emission

    /// Children of `<w:pPr>` must appear in CT_PPrBase schema order.
    /// We emit, in order: shd → spacing → ind → jc.
    private static func paragraphPropertiesXML(_ style: ComputedStyle) -> String {
        var pPr = ""

        if let bg = style.background {
            pPr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(bg.hex)\"/>"
        }

        let before = style.marginTopPt.map { Int(($0 * 20).rounded()) }
        let after  = style.marginBottomPt.map { Int(($0 * 20).rounded()) }
        var spacing = ""
        if let b = before { spacing += " w:before=\"\(b)\"" }
        if let a = after  { spacing += " w:after=\"\(a)\"" }
        if let line = style.lineHeightPt {
            let twentieths = Int((line * 20).rounded())
            spacing += " w:line=\"\(twentieths)\" w:lineRule=\"exact\""
        }
        if !spacing.isEmpty {
            pPr += "<w:spacing\(spacing)/>"
        }

        if let indent = style.textIndentPt {
            let twentieths = Int((indent * 20).rounded())
            pPr += "<w:ind w:firstLine=\"\(twentieths)\"/>"
        }

        if let align = style.textAlign {
            pPr += "<w:jc w:val=\"\(align.rawValue)\"/>"
        }

        return pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>"
    }

    private static func runXML(_ run: RenderRun,
                               paragraphStyle: ComputedStyle) -> String {
        var out = "<w:r>"
        out += runPropertiesXML(run.style, paragraphStyle: paragraphStyle)
        switch run.content {
        case .text(let s):
            out += "<w:t xml:space=\"preserve\">\(escapeXML(s))</w:t>"
        case .lineBreak:
            out += "<w:br/>"
        }
        out += "</w:r>"
        return out
    }

    /// Children of `<w:rPr>` must appear in CT_RPr schema order.
    /// We emit, in order: rFonts → b → bCs → i → iCs → strike → color →
    /// sz → szCs → u → shd. Wrong order is the #1 reason Word shows the
    /// "we found a problem with the content" repair dialog.
    private static func runPropertiesXML(_ style: ComputedStyle,
                                         paragraphStyle: ComputedStyle) -> String {
        var rPr = ""

        if let family = style.fontFamily, !family.isEmpty {
            let f = escapeXMLAttribute(family)
            rPr += "<w:rFonts w:ascii=\"\(f)\" w:hAnsi=\"\(f)\" w:cs=\"\(f)\"/>"
        }
        if style.bold {
            rPr += "<w:b/><w:bCs/>"
        }
        if style.italic {
            rPr += "<w:i/><w:iCs/>"
        }
        if style.strikethrough {
            rPr += "<w:strike/>"
        }
        rPr += "<w:color w:val=\"\(style.color.hex)\"/>"
        let halfPoints = max(2, Int((style.fontSizePt * 2).rounded()))
        rPr += "<w:sz w:val=\"\(halfPoints)\"/><w:szCs w:val=\"\(halfPoints)\"/>"
        if style.underline {
            rPr += "<w:u w:val=\"single\"/>"
        }
        if let bg = style.background, paragraphStyle.background != bg {
            rPr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(bg.hex)\"/>"
        }

        return rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"
    }

    // MARK: - XML escaping

    private static func escapeXML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            default:
                let v = ch.value
                if v == 0x09 || v == 0x0A || v == 0x0D ||
                   (v >= 0x20 && v <= 0xD7FF) ||
                   (v >= 0xE000 && v <= 0xFFFD) ||
                   (v >= 0x10000 && v <= 0x10FFFF) {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }

    private static func escapeXMLAttribute(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case "\"": out += "&quot;"
            case "'":  out += "&apos;"
            default:
                let v = ch.value
                if v == 0x09 || v == 0x0A || v == 0x0D ||
                   (v >= 0x20 && v <= 0xD7FF) ||
                   (v >= 0xE000 && v <= 0xFFFD) ||
                   (v >= 0x10000 && v <= 0x10FFFF) {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }
}
