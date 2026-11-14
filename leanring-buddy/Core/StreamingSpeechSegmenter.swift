//
//  StreamingSpeechSegmenter.swift
//  leanring-buddy
//
//  Turns a streaming model reply into speakable sentences as they complete, so
//  speech can start on the first sentence instead of after the whole answer.
//  Pure logic (Foundation only) so it can be unit-tested outside the app.
//
//  Rules:
//  - Bracket tags ([POINT:…], [DO:…], [CLIPBOARD: long text], [INFO], …) are never
//    spoken, and a sentence is never cut inside one. While a tag is still open the
//    segmenter waits for it to close.
//  - A sentence ends at . ! ? followed by whitespace, or at a newline.
//  - Very short fragments are held and merged with what follows, so "Okay." and
//    abbreviations don't become their own choppy utterances.
//

import Foundation

struct StreamingSpeechSegmenter {
    /// Fragments shorter than this are merged with the next sentence.
    var minimumSentenceCharacters = 18

    /// How much of the raw reply has been turned into sentences so far.
    private var consumedUTF16Count = 0

    init() {}

    /// Feed the whole reply so far. Returns sentences that just became complete.
    mutating func feed(accumulated: String) -> [String] {
        extract(from: accumulated, isFinal: false)
    }

    /// Call once when the stream ends. Returns whatever is left to say.
    mutating func finish(accumulated: String) -> [String] {
        extract(from: accumulated, isFinal: true)
    }

    private mutating func extract(from accumulated: String, isFinal: Bool) -> [String] {
        let all = Array(accumulated.utf16)
        guard consumedUTF16Count < all.count else { return [] }

        var sentences: [String] = []
        var segmentStart = consumedUTF16Count
        var bracketDepth = 0
        var index = consumedUTF16Count

        let openBracket: UInt16 = 0x5B, closeBracket: UInt16 = 0x5D
        let newline: UInt16 = 0x0A
        let terminators: Set<UInt16> = [0x2E, 0x21, 0x3F, 0x3002, 0xFF01, 0xFF1F]
        let whitespace: Set<UInt16> = [0x20, newline, 0x09, 0x0D]

        func text(_ range: Range<Int>) -> String {
            String(utf16CodeUnits: Array(all[range]), count: range.count)
        }

        while index < all.count {
            let unit = all[index]
            if unit == openBracket {
                bracketDepth += 1
            } else if unit == closeBracket {
                bracketDepth = max(0, bracketDepth - 1)
            } else if bracketDepth == 0 {
                var boundaryEnd: Int?
                if unit == newline {
                    boundaryEnd = index + 1
                } else if terminators.contains(unit) {
                    let isCJKTerminator = unit > 0x7F
                    if isCJKTerminator {
                        boundaryEnd = index + 1
                    } else if index + 1 < all.count, whitespace.contains(all[index + 1]) {
                        boundaryEnd = index + 1
                    }
                }
                if let boundaryEnd {
                    let spoken = Self.speakable(text(segmentStart..<boundaryEnd))
                    if spoken.count >= minimumSentenceCharacters {
                        sentences.append(spoken)
                        segmentStart = boundaryEnd
                    }
                    // Too short: keep scanning; it merges with the next sentence.
                }
            }
            index += 1
        }

        if isFinal {
            var tail = text(segmentStart..<all.count)
            if bracketDepth > 0, let lastOpen = tail.lastIndex(of: "[") {
                // The stream ended inside a tag: never speak a half-written tag.
                tail = String(tail[..<lastOpen])
            }
            let spoken = Self.speakable(tail)
            if !spoken.isEmpty { sentences.append(spoken) }
            consumedUTF16Count = all.count
        } else {
            consumedUTF16Count = segmentStart
        }
        return sentences
    }

    /// Strips tags and markdown so nothing but words reaches the voice.
    static func speakable(_ raw: String) -> String {
        var s = raw
        // [TAG], [/TAG], [TAG: anything] — the tag and its payload are plumbing.
        s = s.replacingOccurrences(of: #"\[/?[A-Za-z_]+(:[^\]]*)?\]"#, with: " ", options: .regularExpression)
        // Markdown links keep their label.
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*+|`+|__+|^#{1,6}\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "→", with: ",")
        s = s.replacingOccurrences(of: "—", with: ", ")
        s = s.replacingOccurrences(of: "…", with: "...")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
