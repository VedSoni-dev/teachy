import Foundation

/// The display number is the one printed beside the voice turn's screenshots,
/// not whichever display happens to contain the pointer when the reply arrives.
struct ScreenAnnotationRequest {
    let instruction: String
    let screenNumber: Int?
    let isValid: Bool

    init(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("screen=") {
            let pieces = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let number = Int(pieces[0].dropFirst(7).trimmingCharacters(in: .whitespaces))
            let body = pieces.count == 2 ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            screenNumber = number
            instruction = body
            isValid = (number ?? 0) > 0 && !body.isEmpty
        } else {
            screenNumber = nil
            instruction = text
            isValid = !text.isEmpty
        }
    }

    func captureIndex(count: Int, cursorIndex: Int?) -> Int? {
        guard isValid, count > 0 else { return nil }
        let index = screenNumber.map { $0 - 1 } ?? cursorIndex ?? 0
        return (0..<count).contains(index) ? index : nil
    }
}

enum ScreenAnnotationCapturePolicy {
    /// Teachy's interactive content can be a target. Pointer/mark overlays and
    /// explicitly private windows (notably the local camera preview) cannot.
    static func includesOwnWindow(ignoresMouseEvents: Bool, isPrivate: Bool) -> Bool {
        !ignoresMouseEvents && !isPrivate
    }
}
