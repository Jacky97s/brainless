import Foundation

struct Correction: Codable, Equatable, Hashable {
    let from: String
    let to: String
}

/// Finds the term-level fixes a user typed over text Brainless just inserted.
enum CorrectionLearner {
    /// `before` is the field's value right before the paste, `after` its value once the user is done editing.
    static func corrections(inserted: String, before: String, after: String) -> [Correction] {
        let b = Array(before), a = Array(after)
        guard a.count < 20_000, inserted.count <= 2_000 else { return [] }
        var pre = 0
        while pre < b.count, pre < a.count, b[pre] == a[pre] { pre += 1 }
        var suf = 0
        while suf < b.count - pre, suf < a.count - pre, b[b.count - 1 - suf] == a[a.count - 1 - suf] { suf += 1 }
        let edited = Array(a[pre..<(a.count - suf)])
        return corrections(inserted: Array(inserted), edited: edited)
    }

    static func corrections(inserted ins: [Character], edited ed: [Character]) -> [Correction] {
        guard !ins.isEmpty, ins != ed else { return [] }
        var hunks = diffHunks(ins, ed).map { expandToWords($0, ins, ed) }
        hunks = merge(hunks, ins)
        let untouched = ins.count - hunks.reduce(0) { $0 + $1.i.count }
        // A rewrite of most of the text says nothing about any single term.
        guard hunks.count <= 4, untouched >= max(2, ins.count / 4) else { return [] }
        var out: [Correction] = []
        for h in hunks {
            let from = trimmed(String(ins[h.i])), to = trimmed(String(ed[h.e]))
            guard !from.isEmpty, (2...30).contains(to.count), from.count <= 30,
                  significant(from) != significant(to),
                  to.contains(where: { $0.isLetter }) else { continue }
            let c = Correction(from: from, to: to)
            if !out.contains(c) { out.append(c) }
        }
        return out
    }

    static let reviewSystem = """
    The user dictated text, then hand-edited one part of it. Decide whether the edit fixes a recognition error for a specific term that should go into their personal dictionary: a proper noun, name, product, brand, technical term, or a homophone or misspelling of one.
    Reject edits that change wording, tone, grammar, or meaning, and corrections to ordinary everyday words.
    Reply with JSON only: {"accept": true or false, "term": "<the corrected term as it should be written>"}
    """

    static func reviewUser(_ c: Correction, context: String) -> String {
        "Context: \(context.prefix(300))\nOriginal: \(c.from)\nEdited to: \(c.to)"
    }

    /// The accepted term, or nil when the model rejected the edit or answered something unparseable.
    static func acceptedTerm(fromReview reply: String) -> String? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              obj["accept"] as? Bool == true,
              let term = (obj["term"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              (2...30).contains(term.count) else { return nil }
        return term
    }

    struct Hunk { var i: Range<Int>; var e: Range<Int> }

    private static func diffHunks(_ x: [Character], _ y: [Character]) -> [Hunk] {
        let n = x.count, m = y.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = x[i] == y[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        var open: (Int, Int)?
        func close() { if let (si, sj) = open { hunks.append(Hunk(i: si..<i, e: sj..<j)); open = nil } }
        while i < n || j < m {
            if i < n, j < m, x[i] == y[j] { close(); i += 1; j += 1; continue }
            if open == nil { open = (i, j) }
            if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] { j += 1 } else { i += 1 }
        }
        close()
        return hunks
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    /// Context outside a hunk is identical in both strings, so both sides grow by the same amount.
    private static func expandToWords(_ h: Hunk, _ x: [Character], _ y: [Character]) -> Hunk {
        var h = h
        while h.i.lowerBound > 0, isWordChar(x[h.i.lowerBound - 1]) {
            h.i = (h.i.lowerBound - 1)..<h.i.upperBound
            h.e = (h.e.lowerBound - 1)..<h.e.upperBound
        }
        while h.i.upperBound < x.count, isWordChar(x[h.i.upperBound]) {
            h.i = h.i.lowerBound..<(h.i.upperBound + 1)
            h.e = h.e.lowerBound..<(h.e.upperBound + 1)
        }
        return h
    }

    /// Joins hunks that overlap or are separated by a single space, so "cloud code" stays one term.
    private static func merge(_ hunks: [Hunk], _ x: [Character]) -> [Hunk] {
        var out: [Hunk] = []
        for h in hunks {
            if let last = out.last {
                let gap = last.i.upperBound..<max(last.i.upperBound, h.i.lowerBound)
                if h.i.lowerBound <= last.i.upperBound || (gap.count == 1 && x[gap.lowerBound] == " ") {
                    out[out.count - 1] = Hunk(i: last.i.lowerBound..<max(last.i.upperBound, h.i.upperBound),
                                              e: last.e.lowerBound..<max(last.e.upperBound, h.e.upperBound))
                    continue
                }
            }
            out.append(h)
        }
        return out
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func significant(_ s: String) -> String {
        String(s.filter { $0.isLetter || $0.isNumber })
    }
}
