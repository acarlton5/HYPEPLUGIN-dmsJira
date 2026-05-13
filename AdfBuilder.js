.pragma library

// Convert plain text to Atlassian Document Format (ADF) for the Jira REST v3
// comment endpoint. Paragraph boundaries on \n\n, hard breaks on single \n.
// URLs are auto-linked.

const URL_RE = /https?:\/\/[^\s<>]+/g

function _inlines(text) {
    // Returns an array of ADF inline nodes for one paragraph (no newlines).
    const out = []
    let last = 0
    let m
    URL_RE.lastIndex = 0
    while ((m = URL_RE.exec(text)) !== null) {
        if (m.index > last) {
            out.push({ type: "text", text: text.substring(last, m.index) })
        }
        out.push({
            type: "text",
            text: m[0],
            marks: [{ type: "link", attrs: { href: m[0] } }]
        })
        last = m.index + m[0].length
    }
    if (last < text.length) {
        out.push({ type: "text", text: text.substring(last) })
    }
    return out
}

function _paragraph(text) {
    // Split single \n boundaries inside a paragraph as hard breaks.
    const lines = text.split("\n")
    const content = []
    for (let i = 0; i < lines.length; i++) {
        if (i > 0) content.push({ type: "hardBreak" })
        const inlines = _inlines(lines[i])
        for (let j = 0; j < inlines.length; j++) content.push(inlines[j])
    }
    return { type: "paragraph", content: content }
}

function fromPlainText(text) {
    const paragraphs = (text || "").split(/\n{2,}/).map(_paragraph)
    return {
        type: "doc",
        version: 1,
        content: paragraphs.length > 0 ? paragraphs : [{ type: "paragraph", content: [] }]
    }
}
