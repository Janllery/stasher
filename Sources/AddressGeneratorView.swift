import SwiftUI

struct AddressGeneratorView: View {
    let accent: Color
    let back: () -> Void
    let copy: (String) throws -> Void
    let use: (WalletRecord) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var country: String = {
        let region = Locale.current.region?.identifier ?? "US"
        return TestAddressGenerator.countryCodes.contains(region) ? region : "US"
    }()
    @State private var count = 1
    @State private var addresses: [WalletRecord] = []
    @State private var feedback: PanelNotice?

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Button("Back", systemImage: "chevron.left", action: back)
                    .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent, compact: true))
                    .accessibilityLabel("Back to addresses")
                Text("Generate Test Addresses")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }

            HStack(alignment: .bottom, spacing: 11) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Country or region")
                        .font(.system(size: 11, weight: .medium))
                    Picker("Country or region", selection: $country) {
                        ForEach(TestAddressGenerator.countryCodes, id: \.self) { code in
                            Text(Country.name(code)).tag(code)
                        }
                    }
                    .labelsHidden()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Quantity")
                        .font(.system(size: 11, weight: .medium))
                    Stepper(value: $count, in: TestAddressGenerator.batchRange) {
                        Text(count.formatted())
                            .monospacedDigit()
                    }
                    .accessibilityLabel("Number of addresses")
                    .accessibilityValue(count.formatted())
                }
                .frame(width: 73)

                Button("Generate", systemImage: "dice", action: generate)
                    .buttonStyle(PanelAction(primary: true, dark: dark, accent: accent, compact: true))
            }

            if addresses.isEmpty {
                Text("Choose a country and quantity to generate fictional test addresses.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(addresses, id: \.summary.id, content: addressRow)
                    }
                }
                .id(addresses.first?.summary.id)
            }

            HStack(spacing: 8) {
                if let feedback {
                    Label(feedback.text, systemImage: feedback.icon)
                        .foregroundStyle(feedback.isError ? .red : accent)
                } else if !addresses.isEmpty {
                    Text(addresses.count == 1 ? "1 fictional test address" : "\(addresses.count) fictional test addresses")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if addresses.count > 1 {
                    Button("Copy All", systemImage: "document.on.document") {
                        copyAddress(addresses.map(\.mailingAddress).joined(separator: "\n\n"), message: "All addresses copied")
                    }
                    .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent, compact: true))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(minHeight: 31)
        }
        .onChange(of: country, clear)
        .onChange(of: count, clear)
    }

    private func addressRow(_ address: WalletRecord) -> some View {
        let mailingAddress = address.mailingAddress
        return HStack(alignment: .top, spacing: 10) {
            Text(mailingAddress)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    ForEach(WalletKind.address.detailFields.filter { !address.value($0).isEmpty }, id: \.self) { field in
                        Button("Copy \(field.title)") {
                            copyAddress(address.value(field), message: "\(field.title) copied")
                        }
                    }
                }
            VStack(alignment: .trailing, spacing: 4) {
                Button("Copy", systemImage: "document.on.document") {
                    copyAddress(mailingAddress, message: "Address copied")
                }
                .accessibilityLabel("Copy address for \(address.summary.label)")
                Button("Use Address") { use(address) }
                    .help("Open this address in the editor")
            }
            .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent, compact: true))
        }
        .padding(10)
        .background(.primary.opacity(dark ? 0.08 : 0.048), in: RoundedRectangle(cornerRadius: 9))
    }

    private func generate() {
        addresses = TestAddressGenerator.generate(country: country, count: count)
        feedback = nil
    }

    private func clear() {
        addresses = []
        feedback = nil
    }

    private func copyAddress(_ text: String, message: String) {
        do {
            try copy(text)
            feedback = PanelNotice(text: message, icon: "checkmark.circle.fill")
        } catch {
            feedback = PanelNotice(text: error.localizedDescription, icon: "exclamationmark.circle", isError: true)
        }
    }
}
