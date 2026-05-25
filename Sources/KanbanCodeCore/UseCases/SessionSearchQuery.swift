import Foundation

public struct SessionSearchQuery: Sendable, Equatable {
    public let raw: String
    public let terms: [String]
    public let exactPhrases: [String]
    public let prNumbers: [String]
    public let requiresExactMatch: Bool

    public var isEmpty: Bool {
        terms.isEmpty && exactPhrases.isEmpty
    }

    public var snippetTerms: [String] {
        exactPhrases + terms
    }

    public init(_ query: String) {
        raw = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let quoted = Self.extractQuotedPhrases(from: raw)
        var exacts = quoted

        let rawLower = raw.lowercased()
        let candidateParts = rawLower.components(separatedBy: .whitespacesAndNewlines)
        for part in candidateParts {
            let trimmed = part.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>.,;"))
            if trimmed.contains("://github.com/"), trimmed.contains("/pull/") {
                exacts.append(trimmed)
            }
        }

        let parsedPRNumbers = Self.extractPRNumbers(from: rawLower)
        prNumbers = parsedPRNumbers
        for number in parsedPRNumbers {
            exacts.append(contentsOf: [
                "#\(number)",
                "/pull/\(number)",
                "pull/\(number)",
                "pr #\(number)",
                "pr \(number)",
                "pull request \(number)",
                "\"prnumber\":\(number)"
            ])
        }

        exactPhrases = Self.unique(exacts.map { $0.lowercased() }.filter { !$0.isEmpty })
        terms = Self.unique(BM25Scorer.tokenize(raw))
        requiresExactMatch = !quoted.isEmpty
            || rawLower.contains("://github.com/")
            || !parsedPRNumbers.isEmpty
    }

    public func matchToken(_ token: String) -> String? {
        for term in terms {
            if token == term {
                return term
            }
            if !term.allSatisfy(\.isNumber), term.count >= 3, token.hasPrefix(term) {
                return term
            }
        }
        return nil
    }

    public func exactMatchCount(in lowerText: String) -> Int {
        exactPhrases.reduce(0) { count, phrase in
            lowerText.contains(phrase) ? count + 1 : count
        }
    }

    public func snippetScore(in lowerText: String) -> Int {
        let exactScore = exactMatchCount(in: lowerText) * 10
        let termScore = terms.reduce(0) { score, term in
            lowerText.contains(term) ? score + 1 : score
        }
        return exactScore + termScore
    }

    public func score(termsScore: Double, exactMatches: Int, modifiedTime: Date) -> Double {
        let recency = BM25Scorer.recencyBoost(modifiedTime: modifiedTime)
        return termsScore + (Double(exactMatches) * 10_000 * recency)
    }

    private static func extractQuotedPhrases(from query: String) -> [String] {
        var phrases: [String] = []
        var current = ""
        var inQuote = false

        for char in query {
            if char == "\"" {
                if inQuote {
                    let phrase = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !phrase.isEmpty {
                        phrases.append(phrase.lowercased())
                    }
                    current = ""
                    inQuote = false
                } else {
                    inQuote = true
                    current = ""
                }
            } else if inQuote {
                current.append(char)
            }
        }

        return phrases
    }

    private static func extractPRNumbers(from text: String) -> [String] {
        var numbers: [String] = []
        let patterns = [
            #"(?<![a-z0-9])#([0-9]{1,8})(?![0-9])"#,
            #"/pull/([0-9]{1,8})(?![0-9])"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: nsRange) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: text) else { continue }
                numbers.append(String(text[range]))
            }
        }

        return unique(numbers)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
