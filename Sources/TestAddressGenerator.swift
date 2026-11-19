import Foundation

enum TestAddressGenerator {
    static let batchRange = 1...20
    static let countryCodes = Country.sortedCodes.filter { formats[$0] != nil }

    static func generate(country: String, count: Int) -> [WalletRecord] {
        guard let format = formats[country], batchRange.contains(count) else { return [] }
        var random = SystemRandomNumberGenerator()
        let houseNumbers = (1...240).shuffled(using: &random).prefix(count)
        return houseNumbers.map { number in
            let locality = format.localities.randomElement(using: &random) ?? format.primary
            let street = format.street.replacingOccurrences(of: "{number}", with: String(number))
            let postalCode = String(locality.postalPattern.map { character in
                switch character {
                case "#": return digits.randomElement(using: &random) ?? "0"
                case "@": return letters.randomElement(using: &random) ?? "A"
                default: return character
                }
            })
            let fields: [WalletField: String] = [
                .country: country, .street: street, .city: locality.city,
                .region: locality.region, .postalCode: postalCode
            ].filter { !$0.value.isEmpty }
            let summary = WalletSummary(id: UUID(), kind: .address,
                                        label: "Test Address · \(Country.name(country)) \(number)", hint: country)
            return WalletRecord(summary: summary, fields: fields)
        }
    }

    private static let digits = Array("0123456789")
    private static let letters = Array("AEHNPRTXY")

    private struct Locality {
        let city: String
        let region: String
        let postalPattern: String

        init(_ city: String, _ region: String, _ postalPattern: String) {
            self.city = city
            self.region = region
            self.postalPattern = postalPattern
        }
    }

    private struct Format {
        let street: String
        let primary: Locality
        let localities: [Locality]

        init(_ street: String, _ primary: Locality, _ alternatives: Locality...) {
            self.street = street
            self.primary = primary
            localities = [primary] + alternatives
        }
    }

    // Street templates are fictional; real locality names and regional postal
    // prefixes exercise ordinary form validation without using customer records.
    private static let formats: [String: Format] = [
        "AT": Format("Musterfarnweg {number}", .init("Wien", "", "10##"), .init("Graz", "", "80##")),
        "AU": Format("{number} Demo Wattle Circuit", .init("Sydney", "NSW", "20##"), .init("Melbourne", "VIC", "30##")),
        "BE": Format("Rue des Fougères d’Essai {number}", .init("Bruxelles", "", "10##"), .init("Liège", "", "40##")),
        "BR": Format("Rua das Acácias de Teste, {number}", .init("São Paulo", "SP", "01###-###"),
                     .init("Rio de Janeiro", "RJ", "20###-###")),
        "CA": Format("{number} Example Maple Lane", .init("Toronto", "ON", "M5V #@#"), .init("Vancouver", "BC", "V6B #@#")),
        "CH": Format("Musterahornweg {number}", .init("Zürich", "", "80##"), .init("Bern", "", "30##")),
        "CN": Format("样例银杏路{number}号", .init("北京市", "北京市", "100###"), .init("上海市", "上海市", "200###")),
        "DE": Format("Probeeichenweg {number}", .init("Berlin", "", "10###"), .init("Hamburg", "", "20###")),
        "ES": Format("Calle de los Helechos de Prueba, {number}", .init("Madrid", "Madrid", "280##"),
                     .init("Barcelona", "Barcelona", "080##")),
        "FR": Format("{number} rue des Tilleuls d’Essai", .init("Paris", "", "750##"), .init("Lyon", "", "690##")),
        "GB": Format("{number} Fixture Fern Lane", .init("London", "", "EC1A #@@"), .init("Manchester", "", "M1 #@@")),
        "HK": Format("樣本木棉道{number}號", .init("中環", "香港島", ""), .init("尖沙咀", "九龍", ""), .init("沙田", "新界", "")),
        "IE": Format("{number} Example Rowan Walk", .init("Dublin", "Dublin", "D02 #@#@"), .init("Galway", "Galway", "H91 #@#@")),
        "IN": Format("{number} Demo Banyan Road", .init("New Delhi", "Delhi", "110###"), .init("Mumbai", "Maharashtra", "400###")),
        "IT": Format("Via dei Tigli di Prova {number}", .init("Roma", "RM", "001##"), .init("Milano", "MI", "201##")),
        "JP": Format("検証の森町1丁目{number}番", .init("新宿区", "東京都", "160-####"), .init("中央区", "大阪府", "540-####")),
        "KR": Format("테스트은행나무로 {number}", .init("종로구", "서울특별시", "03###"), .init("부산진구", "부산광역시", "47###")),
        "MO": Format("樣本蓮花路{number}號", .init("澳門半島", "", ""), .init("氹仔", "", "")),
        "MX": Format("Calle Jacaranda de Prueba {number}", .init("Ciudad de México", "Ciudad de México", "06###"),
                     .init("Guadalajara", "Jalisco", "44###")),
        "NL": Format("Proeflindelaan {number}", .init("Amsterdam", "", "101# AB"), .init("Utrecht", "", "351# CD")),
        "NZ": Format("{number} Demo Kōwhai Lane", .init("Auckland", "", "10##"), .init("Wellington", "", "60##")),
        "PT": Format("Rua das Acácias de Teste, {number}", .init("Lisboa", "", "10##-###"), .init("Porto", "", "40##-###")),
        "SE": Format("Provbjörksvägen {number}", .init("Stockholm", "", "11# ##"), .init("Göteborg", "", "41# ##")),
        "SG": Format("{number} Demo Orchid Walk", .init("Singapore", "", "18####"), .init("Singapore", "", "56####")),
        "TW": Format("樣本木棉路{number}號", .init("臺北市中正區", "", "100###"), .init("高雄市苓雅區", "", "802###")),
        "US": Format("{number} Example Cedar Lane", .init("San Francisco", "CA", "941##"),
                     .init("New York", "NY", "100##"), .init("Seattle", "WA", "981##"))
    ]
}
