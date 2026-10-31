import Foundation

/// Universal standard-compliant LRC parser designed for 0ms overhead,
/// handling standard [mm:ss.xx], colon hundredths [mm:ss:xx], integer seconds [mm:ss],
/// multi-timestamp lines, empty instrumental cues, and [offset:±ms] tags.
struct LRCParser: Sendable {

    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"(?:\[(\d+):(\d+)(?:[\.:](\d+))?\])+"#
    )

    private static let singleTimestampRegex = try! NSRegularExpression(
        pattern: #"\[(\d+):(\d+)(?:[\.:](\d+))?\]"#
    )

    private static let offsetRegex = try! NSRegularExpression(
        pattern: #"\[offset:\s*([+-]?\d+)\s*\]"#,
        options: .caseInsensitive
    )

    private static let wordTagRegex = try! NSRegularExpression(
        pattern: #"<(\d+):(\d+(?:\.\d+)?)>\s*([^<]+)"#
    )

    /// Quick test to determine if a string contains valid LRC time-sync tags
    static func hasTimestamps(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return singleTimestampRegex.firstMatch(in: text, range: range) != nil
    }

    /// Parses an LRC formatted string into an array of chronologically sorted `LyricLine`s
    static func parse(_ lyrics: String) -> [LyricLine] {
        var result: [LyricLine] = []
        var globalOffsetSeconds: Double = 0.0

        let rawLines = lyrics.components(separatedBy: .newlines)

        // Pass 1: Extract global offset tag if present (e.g. [offset:+500] in milliseconds)
        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = offsetRegex.firstMatch(in: trimmed, range: range),
               match.numberOfRanges > 1,
               let numRange = Range(match.range(at: 1), in: trimmed),
               let offsetMs = Double(trimmed[numRange]) {
                globalOffsetSeconds = offsetMs / 1000.0
                break
            }
        }

        // Pass 2: Parse line timestamps & text
        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Skip metadata header tags like [ti:Title], [ar:Artist], [al:Album]
            if isHeaderTag(line) { continue }

            let nsLine = line as NSString
            let lineRange = NSRange(location: 0, length: nsLine.length)
            let timestampMatches = singleTimestampRegex.matches(in: line, range: lineRange)
            guard !timestampMatches.isEmpty else { continue }

            // Extract all timestamps found on this line
            var timestamps: [Double] = []
            for match in timestampMatches {
                guard match.numberOfRanges >= 3,
                      let minRange = Range(match.range(at: 1), in: line),
                      let secRange = Range(match.range(at: 2), in: line),
                      let min = Double(line[minRange]),
                      let sec = Double(line[secRange]) else { continue }

                var fraction = 0.0
                if match.numberOfRanges >= 4 && match.range(at: 3).location != NSNotFound,
                   let fracRange = Range(match.range(at: 3), in: line) {
                    let fracStr = String(line[fracRange])
                    if let val = Double("0." + fracStr) {
                        fraction = val
                    }
                }

                let time = max(0.0, min * 60.0 + sec + fraction + globalOffsetSeconds)
                timestamps.append(time)
            }

            guard !timestamps.isEmpty else { continue }

            // Extract text after removing all leading timestamp tags
            let textWithoutTimestamps = singleTimestampRegex.stringByReplacingMatches(
                in: line,
                range: lineRange,
                withTemplate: ""
            ).trimmingCharacters(in: .whitespaces)

            // Extract word-level sync tags if present (<mm:ss.xx> word)
            var lyricWords: [LyricWord] = []
            if textWithoutTimestamps.contains("<") {
                let nsText = textWithoutTimestamps as NSString
                let textRange = NSRange(location: 0, length: nsText.length)
                let wordMatches = wordTagRegex.matches(in: textWithoutTimestamps, range: textRange)

                for wMatch in wordMatches {
                    if wMatch.numberOfRanges >= 4,
                       let minR = Range(wMatch.range(at: 1), in: textWithoutTimestamps),
                       let secR = Range(wMatch.range(at: 2), in: textWithoutTimestamps),
                       let textR = Range(wMatch.range(at: 3), in: textWithoutTimestamps),
                       let wMin = Double(textWithoutTimestamps[minR]),
                       let wSec = Double(textWithoutTimestamps[secR]) {
                        let wTime = max(0.0, wMin * 60.0 + wSec + globalOffsetSeconds)
                        let wText = String(textWithoutTimestamps[textR]).trimmingCharacters(in: .whitespaces)
                        lyricWords.append(LyricWord(time: wTime, text: wText))
                    }
                }
            }

            let plainText = textWithoutTimestamps
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            // Strictly filter out non-vocal studio staff credits, foreign metadata, and producer tags
            guard !isStudioCreditOrNonLyric(plainText) else { continue }

            // If line text is empty, preserve as an instrumental break marker
            let finalDisplayText = plainText.isEmpty ? "• • •" : plainText

            // Register line for EACH timestamp on multi-timestamp lines (e.g. repeated choruses)
            for t in timestamps {
                result.append(LyricLine(time: t, text: finalDisplayText, words: lyricWords))
            }
        }

        return result.sorted { $0.time < $1.time }
    }

    /// Strips studio credits and metadata tags from plain unsynced lyric text
    static func sanitizePlainText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            return !isHeaderTag(trimmed) && !isStudioCreditOrNonLyric(trimmed)
        }
        return filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Determines whether the parsed line represents studio staff, production credits,
    /// or foreign non-lyric metadata injected by third-party providers.
    static func isStudioCreditOrNonLyric(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "• • •" { return false }
        let lower = trimmed.lowercased()

        // 1. CJK metadata and credit keywords (e.g. NetEase / QQ Music injected credits)
        let cjkCreditKeywords = [
            "作词", "作詞", "作曲", "编曲", "編曲", "制作人", "製作人",
            "制作", "製作", "监制", "監製", "混音", "母带", "母帶",
            "录音", "錄音", "吉他", "贝斯", "貝斯", "鼓手", "键盘",
            "鍵盤", "弦乐", "弦樂", "和声", "和聲", "伴唱", "企划",
            "企劃", "出品", "发行", "發行", "统筹", "統籌",
            "词：", "词:", "曲：", "曲:", "詞：", "詞:", "编：", "编:"
        ]
        for keyword in cjkCreditKeywords {
            if trimmed.contains(keyword) {
                return true
            }
        }

        // 2. English studio / production prefixes and metadata tags
        let creditPrefixes = [
            "producer", "produced by", "co-produced by", "written by",
            "written-by", "composed by", "composed-by", "arranged by",
            "arranged-by", "arranger:", "arranger :", "mixed by",
            "mixing by", "mastered by", "mastering by", "recorded at",
            "recorded by", "recording engineer", "engineered by",
            "audio engineer", "assistant engineer", "lead vocals",
            "backing vocals", "lead & backing vocals", "vocals:", "vocals :",
            "guitar:", "guitar :", "guitars:", "guitars :", "electric guitar",
            "acoustic guitar", "bass:", "bass :", "drums:", "drums :",
            "keyboards:", "keyboards :", "percussion:", "percussion :",
            "saxophone:", "saxophone :", "strings:", "strings :",
            "horns:", "horns :", "synthesizer:", "piano:", "piano :",
            "lyrics by", "music by", "lyricist:", "lyricist :",
            "composer:", "composer :", "by:", "author:", "artist:",
            "title:", "album:"
        ]
        for prefix in creditPrefixes {
            if lower.hasPrefix(prefix) {
                return true
            }
        }

        return false
    }

    private static func isHeaderTag(_ line: String) -> Bool {
        let headers = ["[ti:", "[ar:", "[al:", "[by:", "[re:", "[ve:", "[length:", "[offset:"]
        let lower = line.lowercased()
        return headers.contains { lower.hasPrefix($0) }
    }
}

