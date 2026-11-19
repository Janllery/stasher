import SwiftUI

struct PasswordGeneratorView: View {
    @ObservedObject var controller: AppController
    @Environment(\.colorScheme) private var scheme
    @State private var options = PasswordGenerator.Options()
    @State private var password: String?
    @State private var copied = false
    @State private var copyFailed = false

    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate Password")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Picker("Password type", selection: $options.mode) {
                ForEach(PasswordGenerator.Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: password ?? "Could not generate a password")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .accessibilityLabel("Generated password")
                    .accessibilityValue(password ?? "Could not generate a password")
                Button(action: regenerate) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .accessibilityLabel("Generate again")
                .help("Generate again")
            }
            .padding(10)
            .background(.primary.opacity(scheme == .dark ? 0.08 : 0.048),
                        in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(sizeLabel)
                    Spacer()
                    Text(options.size, format: .number)
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .accessibilityHidden(true)
                Slider(value: Binding(get: { Double(options.size) }, set: { options.size = Int($0) }),
                       in: Double(options.mode.sizeRange.lowerBound)...Double(options.mode.sizeRange.upperBound),
                       step: 1) {
                    Text(sizeLabel)
                }
                .labelsHidden()
            }

            if options.mode == .random {
                HStack(spacing: 18) {
                    Toggle("Include numbers", isOn: $options.includeNumbers)
                    Toggle("Include symbols", isOn: $options.includeSymbols)
                }
                .toggleStyle(.checkbox)
            }

            Spacer(minLength: 0)

            if copyFailed {
                Text("Could not write to the clipboard.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Button("Back", action: controller.closePasswordGenerator)
                    .buttonStyle(PanelAction(primary: false, dark: scheme == .dark, accent: accent))
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "document.on.document",
                       action: copy)
                    .buttonStyle(PanelAction(primary: false, dark: scheme == .dark, accent: accent))
                    .disabled(password == nil)
                Button("Use Password") {
                    if let password { controller.useGeneratedPassword(password) }
                }
                .buttonStyle(PanelAction(primary: true, dark: scheme == .dark, accent: accent))
                .disabled(password == nil)
            }
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
        .onChange(of: options, initial: true) { regenerate() }
    }

    private var sizeLabel: String {
        switch options.mode {
        case .random: "Characters"
        case .memorable: "Words"
        case .pin: "Digits"
        }
    }

    private func regenerate() {
        password = PasswordGenerator.generate(options)
        copied = false
        copyFailed = false
    }

    private func copy() {
        guard let password else { return }
        do {
            try controller.copyGeneratedText(password)
            copied = true
            copyFailed = false
        } catch {
            copied = false
            copyFailed = true
        }
    }
}
