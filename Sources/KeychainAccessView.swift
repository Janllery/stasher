import SwiftUI

struct KeychainAccessView: View {
    @ObservedObject var controller: AppController
    let accent: Color

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if controller.keychainState == .locked {
                Text("Unlock Stasher")
                    .font(.system(size: 19, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Verify your identity with macOS to access your saved records.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if let error = controller.keychainError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Unlock Keychain", action: controller.unlockKeychain)
                        .buttonStyle(PanelAction(primary: true, dark: scheme == .dark, accent: accent))
                        .keyboardShortcut(.defaultAction)
                        .disabled(controller.isBusy)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(controller.keychainState == .authenticating
                         ? "Waiting for macOS verification…" : "Reopening Keychain records…")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
