import AppKit

@MainActor
final class PasswordClipboard {
    private let pasteboard: NSPasteboard
    private let timeout: Duration
    private var expires: Task<Void, Never>?
    private var ownedChange: Int?

    init(pasteboard: NSPasteboard = .general, timeout: Duration = .seconds(30)) {
        self.pasteboard = pasteboard
        self.timeout = timeout
    }

    func copy(_ text: String) throws {
        expires?.cancel()
        ownedChange = pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.setString(text, forType: .string) else {
            clearIfOwned()
            throw KeychainFailure.clipboard
        }
        ownedChange = pasteboard.changeCount
        expires = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.clearIfOwned()
        }
    }

    func clearIfOwned() {
        expires?.cancel()
        expires = nil
        if let ownedChange, pasteboard.changeCount == ownedChange {
            pasteboard.clearContents()
        }
        ownedChange = nil
    }
}
