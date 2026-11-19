import Foundation

struct PublicSuffixList: Sendable {
    private let rules: Set<String>

    static let bundled: Self? = {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self(contents)
    }()

    private init(_ contents: String) {
        rules = Set(contents.split(whereSeparator: \.isNewline).compactMap { line in
            guard let rule = line.split(whereSeparator: \.isWhitespace).first, !rule.hasPrefix("//") else {
                return nil
            }
            let prefix: String
            if rule.hasPrefix("!") {
                prefix = "!"
            } else if rule.hasPrefix("*.") {
                prefix = "*."
            } else {
                prefix = ""
            }
            let suffix = rule.dropFirst(prefix.count).lowercased()
            if suffix.utf8.allSatisfy({ $0 < 128 }) { return prefix + suffix }
            guard let host = URL(string: "https://\(suffix)")?.host(percentEncoded: true) else { return nil }
            return prefix + host.lowercased()
        })
    }

    func registrableDomain(for host: String) -> String? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), !host.contains(":"),
              labels.last?.utf8.contains(where: { (97...122).contains($0) }) == true else { return nil }

        // The longest rule wins. An exception instead removes its first label.
        var suffixLength = 1
        for index in labels.indices.reversed() {
            let suffix = labels[index...].joined(separator: ".")
            let length = labels.count - index
            if rules.contains("!" + suffix) {
                suffixLength = length - 1
                break
            }
            if rules.contains(suffix) { suffixLength = max(suffixLength, length) }
            if index > labels.startIndex, rules.contains("*." + suffix) {
                suffixLength = max(suffixLength, length + 1)
            }
        }
        guard labels.count > suffixLength else { return nil }
        return labels.suffix(suffixLength + 1).joined(separator: ".")
    }
}
