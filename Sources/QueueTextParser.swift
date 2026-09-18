import Foundation

/// Text selection and section handling are independent of AX so regressions
/// can be tested without changing the user's Music playback.
enum QueueTextParser {
    struct Row {
        var texts: [String]
        var hasTrackMenu: Bool
    }

    static func firstText(_ candidates: [String?]) -> String? {
        candidates.compactMap { $0 }
            .map { $0.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    static func upcoming(_ rows: [Row]) -> [(title: String, subtitle: String)] {
        var history = false
        var result: [(String, String)] = []
        for row in rows {
            let texts = row.texts.compactMap { firstText([$0]) }
            guard let title = texts.first else { continue }
            // A track named "History" must still be playable queue content.
            if !row.hasTrackMenu {
                let heading = title.lowercased()
                if heading == "履歴" || heading == "history" {
                    history = true
                } else {
                    // Music also uses "再生を続ける" / "Continue Playing",
                    // playlist titles, and AutoPlay as section headings. Any
                    // subsequent section ends History, regardless of locale.
                    history = false
                }
                continue
            }
            guard !history else { continue }
            result.append((title, texts.dropFirst().prefix(2).joined(separator: " — ")))
        }
        return result
    }
}
