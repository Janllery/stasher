import Foundation

enum PasswordGenerator {
    enum Mode: String, CaseIterable {
        case random = "Random"
        case memorable = "Passphrase"
        case pin = "PIN"

        var sizeRange: ClosedRange<Int> {
            switch self {
            case .random: 8...64
            case .memorable: 4...10
            case .pin: 4...12
            }
        }
    }

    struct Options: Equatable {
        var mode = Mode.random
        var includeNumbers = true
        var includeSymbols = true
        private var characterCount = 24
        private var wordCount = 6
        private var digitCount = 6

        var size: Int {
            get {
                switch mode {
                case .random: characterCount
                case .memorable: wordCount
                case .pin: digitCount
                }
            }
            set {
                switch mode {
                case .random: characterCount = newValue
                case .memorable: wordCount = newValue
                case .pin: digitCount = newValue
                }
            }
        }
    }

    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz".utf8)
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
    private static let digits = Array("0123456789".utf8)
    private static let symbols = Array("!@#$%^&*()-_=+?".utf8)

    private static let words: [String] = {
        guard let url = Bundle.main.url(forResource: "eff_large_wordlist", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let words: [String] = contents.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t")
            return fields.count == 2 ? String(fields[1]) : nil
        }
        return words.count == 7776 && Set(words).count == words.count ? words : []
    }()

    static func generate(_ options: Options) -> String? {
        let count = options.size
        guard options.mode.sizeRange.contains(count) else { return nil }
        switch options.mode {
        case .random:
            var groups = [lowercase, uppercase]
            if options.includeNumbers { groups.append(digits) }
            if options.includeSymbols { groups.append(symbols) }
            let alphabet = groups.flatMap { $0 }
            // Sample uniformly from the strings that include each requested character group.
            while true {
                let candidate = draw(count, from: alphabet)
                let characters = Set(candidate)
                if groups.allSatisfy({ !characters.isDisjoint(with: $0) }) {
                    return String(decoding: candidate, as: UTF8.self)
                }
            }
        case .memorable:
            guard !words.isEmpty else { return nil }
            return draw(count, from: words).joined(separator: ".")
        case .pin:
            return String(decoding: draw(count, from: digits), as: UTF8.self)
        }
    }

    private static func draw<Element>(_ count: Int, from options: [Element]) -> [Element] {
        // The Swift system generator uses the operating system's cryptographic randomness on macOS.
        (0..<count).map { _ in options[Int.random(in: options.indices)] }
    }
}
