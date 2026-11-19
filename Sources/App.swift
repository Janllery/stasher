import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct Stasher {
    static func main() {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { app.run() }
    }
}

struct PanelNotice {
    let text: String
    let icon: String
    var isError = false
}

enum CategoryFilter: Hashable {
    case all, uncategorized, named(String)

    var title: String {
        switch self {
        case .all: return "All"
        case .uncategorized: return "Uncategorized"
        case .named(let name): return name
        }
    }

    func includes(_ entry: Credential) -> Bool {
        switch self {
        case .all: return true
        case .uncategorized: return entry.category.isEmpty
        case .named(let name): return entry.category == name
        }
    }
}

enum KeychainState: Equatable {
    case locked, authenticating, unlocked, suspended
}

enum WalletScreen {
    case list
    case details(WalletRecord)
    case editor(WalletSummary?)
    case addressGenerator

    var isEditing: Bool {
        if case .editor = self { return true }
        return false
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    static let width: CGFloat = 448
    static let height: CGFloat = 486

    @Published private(set) var keychainState: KeychainState = .locked
    @Published private(set) var keychainError: String?
    @Published private(set) var entries: [Credential] = []
    @Published var search = "" {
        didSet {
            if search != oldValue { selected = listedEntries.first?.id }
        }
    }
    @Published var categoryFilter = CategoryFilter.all {
        didSet { selected = visibleEntries.first?.id }
    }
    @Published var selected: UUID?
    @Published var draft = CredentialDraft()
    @Published var deletionTarget: Credential?
    @Published private(set) var editing = false
    @Published private(set) var showingPasswordGenerator = false
    @Published private(set) var showsDraftPassword = false
    @Published private(set) var editingEntry: Credential?
    @Published private(set) var invalidWebsite = false
    @Published private(set) var invalidLoginName = false
    @Published private(set) var invalidPassword = false
    @Published private(set) var isBusy = false
    @Published private(set) var loaded = false
    @Published private(set) var notice: PanelNotice?
    @Published private(set) var shortcut: HotKey.Shortcut?
    @Published private(set) var focusRequest = 0
    @Published private(set) var suggestedSite: WebsiteSuggestion?
    @Published private(set) var websitePermissionDenied = false
    @Published private(set) var pinned: Bool
    @Published private(set) var walletKind: WalletKind?
    @Published private(set) var walletScreen: WalletScreen = .list
    @Published private(set) var walletLoaded = false
    @Published var walletSearch = ""
    @Published var walletDraft = WalletDraft(kind: .address)
    @Published var walletDeletionTarget: WalletSummary?
    @Published private var walletItems: [WalletSummary] = []
    @Published private var savedCategories: Set<String>
    @Published private(set) var categoryColorSlots: [String: Int]
    @Published var opacity: Double {
        didSet { defaults.set(opacity, forKey: "panelOpacity") }
    }

    let opacityRange = 0.62...1.0
    private let defaults = UserDefaults.standard
    private let store = CredentialStore()
    private let walletStore = WalletStore()
    private var walletResume: WalletSummary?
    private let clipboard = PasswordClipboard()
    private var keychainGeneration = UUID()
    private var keychainLockTask: Task<Void, Never>?
    private var operationCancellation: CancellationToken?
    private var sleepObserver: NSObjectProtocol?
    private var screenLockObserver: NSObjectProtocol?
    private var passwordPreviewTimer: Task<Void, Never>?
    private var statusItem: NSStatusItem?
    private var panel: ReminderPanel?
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var priorApp: NSRunningApplication?
    private var deferredDismissal: Task<Void, Never>?
    private var websiteMonitor: Task<Void, Never>?
    private var requestingChromePermission = false

    override init() {
        pinned = defaults.bool(forKey: "panelPinned")
        savedCategories = []
        categoryColorSlots = [:]
        let savedOpacity = defaults.object(forKey: "panelOpacity") as? Double ?? 0.94
        opacity = min(1, max(0.62, savedOpacity))
        super.init()
    }

    var visibleEntries: [Credential] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = entries.filter(categoryFilter.includes)
        guard !query.isEmpty else { return matches }
        return matches.filter {
            $0.name.localizedStandardContains(query) || $0.url.absoluteString.localizedStandardContains(query)
                || $0.loginName.localizedStandardContains(query)
        }
    }

    var websiteSuggestions: [Credential] {
        guard search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let suggestedSite else { return [] }
        return suggestedSite.suggestions(from: entries)
    }

    var listedEntries: [Credential] {
        let suggestions = websiteSuggestions
        guard !suggestions.isEmpty else { return visibleEntries }
        let suggestedIDs = Set(suggestions.map(\.id))
        return suggestions + visibleEntries.filter { !suggestedIDs.contains($0.id) }
    }

    var categories: [String] {
        savedCategories.union(entries.map(\.category).filter { !$0.isEmpty })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StasherMark.templateImage()
        item.button?.setAccessibilityLabel("Stasher")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        let registration = HotKey { [weak self] in self?.showPanel() }
        shortcut = registration.start()
        item.button?.toolTip = shortcut.map { "Stasher · \($0.label)" } ?? "Stasher"
        hotKey = registration

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.suspendKeychainInterface() }
        }
        screenLockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.suspendKeychainInterface() }
        }
        showPanel()
        unlockKeychain()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let panel, panel.isVisible, !panel.isKeyWindow {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        hideDraftPassword()
    }

    func applicationWillTerminate(_ notification: Notification) {
        websiteMonitor?.cancel()
        operationCancellation?.cancel()
        hideDraftPassword()
        clipboard.clearIfOwned()
        hotKey?.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let screenLockObserver { DistributedNotificationCenter.default().removeObserver(screenLockObserver) }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem?.button {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Passwords", action: #selector(showFromMenu), keyEquivalent: "").target = self
            menu.addItem(withTitle: pinned ? "Unpin Panel" : "Keep Panel on Top",
                         action: #selector(togglePin), keyEquivalent: "").target = self
            if keychainState != .locked {
                menu.addItem(withTitle: "Lock App", action: #selector(lockApp), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Stasher", action: #selector(quit), keyEquivalent: "q").target = self
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            return
        }
        showFromMenu()
    }

    @objc private func showFromMenu() { showPanel() }

    @objc func quit() { NSApp.terminate(nil) }

    func addCategory() {
        guard keychainState == .unlocked else { return }
        guard !isBusy, let panel else { return }
        isBusy = true
        notice = nil
        Task {
            defer { finishOperation() }
            let alert = NSAlert()
            alert.messageText = "New Category"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 233, height: 24))
            field.placeholderString = "Enter a category name"
            field.setAccessibilityLabel("Category name")
            alert.accessoryView = field
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard await alert.beginSheetModal(for: panel) == .alertFirstButtonReturn, keychainState == .unlocked else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                notice = PanelNotice(text: "Enter a category name.", icon: "exclamationmark.circle", isError: true)
                return
            }
            do {
                try await rememberCategories([name])
                categoryFilter = .named(name)
            } catch { report(error) }
        }
    }

    private func rememberCategories(_ names: [String]) async throws {
        try requireOpenKeychain()
        let previousNames = defaults.stringArray(forKey: "categories") ?? []
        let previousSlots = defaults.dictionary(forKey: "categoryColorSlots") as? [String: Int] ?? [:]
        let slots = try await KeychainDatabase.shared.rememberCategories(names + previousNames,
                                                                        legacySlots: previousSlots)
        if !previousNames.isEmpty || !previousSlots.isEmpty {
            defaults.removeObject(forKey: "categories")
            defaults.removeObject(forKey: "categoryColorSlots")
        }
        try requireOpenKeychain()
        applyCategorySlots(slots)
    }

    private func applyCategorySlots(_ slots: [String: Int]) {
        savedCategories = Set(slots.keys)
        categoryColorSlots = slots
    }

    func importCSV() {
        guard keychainState == .unlocked else { return }
        guard !editing, !isBusy, let panel else { return }
        isBusy = true
        notice = nil
        Task {
            defer { finishOperation() }
            let picker = NSOpenPanel()
            picker.title = "Choose a Password CSV"
            picker.prompt = "Preview Import"
            picker.allowedContentTypes = [.commaSeparatedText]
            guard await picker.beginSheetModal(for: panel) == .OK, keychainState == .unlocked, let url = picker.url else { return }

            let csv: CSVImport
            do {
                csv = try await Task.detached(priority: .userInitiated) {
                    try CSVImport.read(from: url)
                }.value
                guard keychainState == .unlocked else { return }
            } catch {
                guard keychainState == .unlocked else { return }
                let message = (error as? CSVImport.Problem)?.localizedDescription ?? "Could not read the CSV. Select the file again."
                notice = PanelNotice(text: message, icon: "exclamationmark.circle", isError: true)
                return
            }

            do {
                let preview = csv.plan(existing: try await store.list())
                guard keychainState == .unlocked, await confirmImport(preview, in: panel), keychainState == .unlocked else { return }
                let existing = try await store.list()
                guard keychainState == .unlocked else { return }
                let plan = preview.excludingExisting(existing)
                try await saveImport(plan, existing: existing)
            } catch { report(error) }
        }
    }

    private func confirmImport(_ plan: CSVImport.Plan, in window: NSWindow) async -> Bool {
        let alert = NSAlert()
        let hasRows = !plan.ready.isEmpty
        alert.messageText = hasRows ? "Import passwords?" : "No passwords to import"
        var details = hasRows ? "\(plan.ready.count) ready to import. " : ""
        details += plan.skipped + "."
        if !plan.invalidRows.isEmpty {
            let lines = plan.invalidRows.prefix(5).map(String.init).joined(separator: ", ")
            let suffix = plan.invalidRows.count > 5 ? " and others" : ""
            details += "\nCheck the URL, username, and password on rows \(lines)\(suffix)."
        }
        alert.informativeText = details
        alert.addButton(withTitle: hasRows ? "Import" : "Close")
        if hasRows { alert.addButton(withTitle: "Cancel") }
        let response = await alert.beginSheetModal(for: window)
        return hasRows && response == .alertFirstButtonReturn
    }

    private func saveImport(_ plan: CSVImport.Plan, existing: [Credential]) async throws {
        var saved: [Credential] = []
        var failedRow: Int?
        for row in plan.ready {
            guard keychainState == .unlocked else { return }
            do {
                let entry = try await store.add(row.credential, password: row.password)
                guard keychainState == .unlocked else { return }
                saved.append(entry)
            } catch {
                if case KeychainFailure.locked = error { throw error }
                failedRow = row.number
                break
            }
        }
        guard keychainState == .unlocked else { return }
        let imported = Array(saved.reversed()) + existing
        try await rememberCategories(imported.map(\.category))
        entries = imported
        loaded = true
        if !saved.isEmpty {
            search = ""
            categoryFilter = .all
        }
        selected = visibleEntries.first?.id
        focusRequest += 1

        if let failedRow {
            notice = PanelNotice(text: "Imported \(saved.count). Could not save row \(failedRow). Try again.",
                                 icon: "exclamationmark.circle", isError: true)
        } else {
            notice = PanelNotice(text: "Imported \(saved.count). \(plan.skipped).",
                                 icon: "checkmark.circle.fill")
        }
    }

    func exportCSV() {
        guard keychainState == .unlocked else { return }
        guard !editing, !showingPasswordGenerator, !isBusy, let panel else { return }
        isBusy = true
        notice = nil
        Task {
            defer { finishOperation() }
            do {
                let picker = NSSavePanel()
                picker.title = "Export Passwords as CSV"
                picker.message = "The CSV will contain all saved passwords in plain text. Choose a local folder that does not sync."
                picker.prompt = "Export"
                picker.nameFieldStringValue = "Stasher.csv"
                picker.allowedContentTypes = [.commaSeparatedText]
                picker.canCreateDirectories = true
                guard await picker.beginSheetModal(for: panel) == .OK, keychainState == .unlocked, let url = picker.url else { return }

                let cancellation = CancellationToken()
                operationCancellation = cancellation
                defer { operationCancellation = nil }
                let rows = try await store.exportRows(cancellation: cancellation)
                guard keychainState == .unlocked else { return }
                guard !rows.isEmpty else {
                    notice = PanelNotice(text: "There are no passwords to export.", icon: "square.and.arrow.up")
                    return
                }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        var csv = CSVExport()
                        for (entry, password) in rows {
                            csv.append(entry, password: password)
                        }
                        try csv.write(to: url, cancellation: cancellation)
                    }.value
                    guard keychainState == .unlocked else { return }
                    notice = PanelNotice(text: "Exported \(rows.count) to CSV", icon: "checkmark.circle.fill")
                } catch {
                    guard keychainState == .unlocked else { return }
                    notice = PanelNotice(text: "Could not save the CSV. Choose another folder and try again.",
                                         icon: "exclamationmark.circle", isError: true)
                }
            } catch { report(error) }
        }
    }

    @objc func togglePin() {
        pinned.toggle()
        defaults.set(pinned, forKey: "panelPinned")
        applyPin()
    }

    func closePanel() {
        guard !isBusy else { return }
        deferredDismissal?.cancel()
        if editing { endEditing() }
        if walletKind != nil { closeWalletScreen() }
        if notice?.isError == false { notice = nil }
        hidePanel()
        returnToPreviousApp()
    }

    func windowDidResignKey(_ notification: Notification) {
        hideDraftPassword()
        schedulePanelDismissal()
    }

    private func schedulePanelDismissal() {
        deferredDismissal?.cancel()
        deferredDismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, !pinned, !editing, !walletScreen.isEditing, !isBusy,
                  !requestingChromePermission, deletionTarget == nil, walletDeletionTarget == nil,
                  let panel, panel.isVisible, !panel.isKeyWindow else { return }
            hidePanel()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        deferredDismissal?.cancel()
        focusRequest += 1
    }

    func openEditor(_ entry: Credential? = nil) {
        guard keychainState == .unlocked else { return }
        guard !isBusy else { return }
        hideDraftPassword()
        editingEntry = entry
        draft = CredentialDraft(credential: entry)
        if entry == nil, case .named(let name) = categoryFilter { draft.category = name }
        invalidWebsite = false
        invalidLoginName = false
        invalidPassword = false
        notice = nil
        editing = true
        focusRequest += 1
    }

    func endEditing() {
        guard !isBusy else { return }
        hideDraftPassword()
        editing = false
        editingEntry = nil
        draft = CredentialDraft()
        notice = nil
        focusRequest += 1
    }

    func openPasswordGenerator() {
        guard keychainState == .unlocked else { return }
        guard !isBusy, walletKind == nil else { return }
        hideDraftPassword()
        showingPasswordGenerator = true
    }

    func closePasswordGenerator() {
        showingPasswordGenerator = false
        focusRequest += 1
    }

    func useGeneratedPassword(_ password: String) {
        guard keychainState == .unlocked else { return }
        guard showingPasswordGenerator, !isBusy, !password.isEmpty else { return }
        if !editing { openEditor() }
        draft.password = password
        invalidPassword = false
        closePasswordGenerator()
    }

    func copyGeneratedText(_ text: String) throws {
        try requireOpenKeychain()
        try clipboard.copy(text)
    }

    func save() {
        guard keychainState == .unlocked else { return }
        guard editing, !isBusy else { return }
        let website = draft.websiteURL
        let password = draft.password
        invalidWebsite = website == nil
        invalidLoginName = draft.trimmedLoginName.isEmpty
        invalidPassword = editingEntry == nil && password.isEmpty
        guard let website, !invalidLoginName, !invalidPassword else { return }

        let original = editingEntry
        let entry = draft.metadata(id: original?.id ?? UUID(), url: website)
        hideDraftPassword()
        isBusy = true
        notice = nil
        Task {
            defer { finishOperation() }
            do {
                let saved: Credential
                if let original {
                    saved = try await store.update(entry, password: password.isEmpty ? nil : password,
                                                   expectedModifiedAt: original.modifiedAt)
                } else {
                    saved = try await store.add(entry, password: password)
                }

                guard keychainState == .unlocked else { return }
                editing = false
                editingEntry = nil
                draft = CredentialDraft()
                search = ""
                entries.removeAll { $0.id == saved.id }
                entries.insert(saved, at: 0)
                if !categoryFilter.includes(saved) { categoryFilter = .all }
                selected = saved.id
                loaded = true
                notice = PanelNotice(text: original == nil ? "Password added" : "Changes saved",
                                     icon: "checkmark.circle.fill")
                focusRequest += 1
                try await rememberCategories([saved.category])
            } catch { report(error) }
        }
    }

    func refresh() {
        guard keychainState == .unlocked else { return }
        guard !isBusy else { return }
        isBusy = true
        notice = nil
        Task {
            defer { finishOperation() }
            do {
                let records = try await store.list()
                guard keychainState == .unlocked else { return }
                try await rememberCategories(records.map(\.category))
                entries = records
                loaded = true
                if !listedEntries.contains(where: { $0.id == selected }) {
                    selected = listedEntries.first?.id
                }
            } catch { report(error) }
        }
    }

    func copySelected() {
        guard keychainState == .unlocked else { return }
        let entries = listedEntries
        if let entry = entries.first(where: { $0.id == selected }) ?? entries.first {
            copy(entry)
        }
    }

    func copyLoginName(_ entry: Credential) {
        guard keychainState == .unlocked else { return }
        guard !isBusy, !entry.loginName.isEmpty else { return }
        do {
            try finishCopy(entry.loginName, message: "Username copied")
        } catch { report(error) }
    }

    func copy(_ entry: Credential, includingLoginName: Bool = false) {
        guard keychainState == .unlocked else { return }
        guard !isBusy, !includingLoginName || !entry.loginName.isEmpty else { return }
        isBusy = true
        notice = nil
        Task {
            defer { finishOperation() }
            do {
                let password = try await store.password(for: entry)
                guard keychainState == .unlocked else { return }
                if includingLoginName {
                    try finishCopy("\(entry.loginName)\n\(password)", message: "Username and password copied")
                } else {
                    try finishCopy(password, message: "Password copied")
                }
            } catch { report(error) }
        }
    }

    func toggleDraftPassword() {
        guard keychainState == .unlocked else { return }
        guard editing, editingEntry == nil, !showingPasswordGenerator, !isBusy,
              panel?.isKeyWindow == true else { return }
        if showsDraftPassword {
            hideDraftPassword()
            return
        }
        showsDraftPassword = true
        passwordPreviewTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.hideDraftPassword()
        }
    }

    private func hideDraftPassword() {
        passwordPreviewTimer?.cancel()
        passwordPreviewTimer = nil
        if showsDraftPassword { showsDraftPassword = false }
    }

    private func finishCopy(_ text: String, message: String) throws {
        try requireOpenKeychain()
        try clipboard.copy(text)
        notice = PanelNotice(text: message, icon: "checkmark.circle.fill")
        if pinned {
            if panel?.isKeyWindow == true { panel?.resignKey() }
        } else {
            hidePanel()
        }
        returnToPreviousApp()
    }

    func delete(_ entry: Credential) {
        guard keychainState == .unlocked else { return }
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { finishOperation() }
            do {
                try await store.delete(entry)
                guard keychainState == .unlocked else { return }
                entries.removeAll { $0.id == entry.id }
                if case .named(let name) = categoryFilter, !categories.contains(name) { categoryFilter = .all }
                if selected == entry.id { selected = listedEntries.first?.id }
                notice = PanelNotice(text: "Password deleted", icon: "checkmark.circle")
            } catch { report(error) }
        }
    }

    func openWebsite(_ entry: Credential) {
        guard keychainState == .unlocked else { return }
        guard ["https", "http"].contains(entry.url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(entry.url)
        if !pinned { hidePanel() }
    }

    private func report(_ error: Error) {
        guard keychainState == .unlocked else { return }
        if case KeychainFailure.locked = error {
            lockApp()
            return
        }
        notice = PanelNotice(text: error.localizedDescription, icon: "exclamationmark.circle", isError: true)
    }

    private func showPanel() {
        deferredDismissal?.cancel()
        let active = NSWorkspace.shared.frontmostApplication
        if let active, active.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            priorApp = active
        }
        let window = panel ?? makePanel()
        let beginMonitoring = !window.isVisible || active?.processIdentifier != getpid()
        if !window.isVisible { place(window) }
        if NSApp.isHidden { NSApp.unhide(nil) }
        if !NSApp.isActive { NSApp.activate() }
        window.makeKeyAndOrderFront(nil)
        // Finder can remain active when reopening a menu bar app.
        window.orderFrontRegardless()
        if keychainState == .suspended {
            resumeKeychainInterface()
            focusRequest += 1
            return
        }
        if keychainState == .unlocked, beginMonitoring, walletKind == nil {
            let chrome = active?.bundleIdentifier == ChromeTab.bundleIdentifier ? active : nil
            startWebsiteMonitor(chrome: chrome)
        }
        focusRequest += 1
        guard keychainState == .unlocked else { return }
        if let kind = walletKind {
            if let resume = walletResume {
                walletResume = nil
                openWalletRecord(resume)
            } else if !walletLoaded {
                refreshWallet(kind)
            }
        } else if !loaded && !editing {
            refresh()
        }
    }

    private func hidePanel() {
        hideDraftPassword()
        showingPasswordGenerator = false
        if case .details = walletScreen { walletScreen = .list }
        panel?.orderOut(nil)
        stopWebsiteMonitor()
    }

    private func stopWebsiteMonitor() {
        websiteMonitor?.cancel()
        websiteMonitor = nil
        requestingChromePermission = false
        updateWebsiteSuggestion(.unavailable)
    }

    private func startWebsiteMonitor(chrome: NSRunningApplication?) {
        guard keychainState == .unlocked else { return }
        stopWebsiteMonitor()
        if chrome != nil, !editing {
            search = ""
            selected = visibleEntries.first?.id
        }
        websiteMonitor = Task { [weak self] in
            var browserPID = chrome?.processIdentifier
            var mayRequestPermission = true
            while !Task.isCancelled {
                guard let self, keychainState == .unlocked, panel?.isVisible == true else { return }
                if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
                    let activePID = front.bundleIdentifier == ChromeTab.bundleIdentifier ? front.processIdentifier : nil
                    if activePID != browserPID {
                        browserPID = activePID
                        mayRequestPermission = true
                        updateWebsiteSuggestion(.unavailable)
                    }
                }

                if let browserPID, !editing {
                    var result = await ChromeTab.website(processIdentifier: browserPID, askUserIfNeeded: false)
                    guard !Task.isCancelled else { return }
                    if case .permissionRequired = result, mayRequestPermission {
                        mayRequestPermission = false
                        requestingChromePermission = true
                        result = await ChromeTab.website(processIdentifier: browserPID, askUserIfNeeded: true)
                        guard !Task.isCancelled else { return }
                        requestingChromePermission = false
                        if panel?.isKeyWindow == false { schedulePanelDismissal() }
                    }
                    updateWebsiteSuggestion(result)
                }
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            }
        }
    }

    private func updateWebsiteSuggestion(_ result: ChromeTab.Lookup) {
        let site: WebsiteSuggestion?
        let permissionDenied: Bool
        switch result {
        case .site(let suggestion):
            site = suggestion
            permissionDenied = false
        case .permissionDenied, .permissionRequired:
            site = nil
            permissionDenied = true
        case .unavailable:
            site = nil
            permissionDenied = false
        }
        if websitePermissionDenied != permissionDenied { websitePermissionDenied = permissionDenied }
        guard suggestedSite != site else { return }

        let preferSuggestion = selected == nil || selected == visibleEntries.first?.id
            || websiteSuggestions.contains(where: { $0.id == selected })
        suggestedSite = site
        if preferSuggestion || !listedEntries.contains(where: { $0.id == selected }) {
            selected = listedEntries.first?.id
        }
    }

    private func makePanel() -> ReminderPanel {
        let window = ReminderPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.title = "Stasher"
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .utilityWindow
        window.isMovableByWindowBackground = true
        window.sharingType = .none
        window.delegate = self
        window.contentView = NSHostingView(rootView: PasswordPanel(controller: self))
        panel = window
        applyPin()
        return window
    }

    private func applyPin() {
        panel?.level = pinned ? .floating : .normal
        panel?.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary]
                                           : [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        if panel?.isVisible == true { panel?.orderFrontRegardless() }
    }

    private func place(_ window: ReminderPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        window.setFrameOrigin(NSPoint(
            x: max(visible.minX + margin, visible.maxX - window.frame.width - margin),
            y: max(visible.minY + margin, visible.maxY - window.frame.height - margin)
        ))
    }

    private func returnToPreviousApp() {
        if NSApp.isActive, let priorApp, !priorApp.isTerminated {
            NSApp.yieldActivation(to: priorApp)
            _ = priorApp.activate()
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard panel?.isKeyWindow == true else { return event }
        if keychainState != .unlocked {
            if event.keyCode == 53 { closePanel(); return nil }
            return event
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "n" {
            if let kind = walletKind {
                if !walletScreen.isEditing { openWalletEditor(kind) }
            } else if !editing && !showingPasswordGenerator {
                openEditor()
            }
            return nil
        }
        if event.keyCode == 53, modifiers.isEmpty {
            if showingPasswordGenerator { closePasswordGenerator() }
            else if editing { endEditing() }
            else if walletKind != nil, !isWalletList { closeWalletScreen() }
            else { closePanel() }
            return nil
        }
        if walletKind == nil, !editing, !showingPasswordGenerator, modifiers.isEmpty, [125, 126].contains(event.keyCode),
           panel?.firstResponder is NSTextView {
            let items = listedEntries
            if let index = items.firstIndex(where: { $0.id == selected }) {
                let offset = event.keyCode == 125 ? 1 : -1
                selected = items[min(items.count - 1, max(0, index + offset))].id
            } else {
                selected = items.first?.id
            }
            return nil
        }
        return event
    }

    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Lock App", action: #selector(lockApp), keyEquivalent: "l").target = self
        appMenu.addItem(withTitle: "Quit Stasher", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        return menu
    }
}

extension AppController {
    func unlockKeychain() {
        guard !isBusy, keychainState == .locked else { return }
        isBusy = true
        keychainState = .authenticating
        keychainError = nil
        let generation = keychainGeneration
        Task {
            defer { finishOperation() }
            guard generation == keychainGeneration else { return }
            do {
                try await KeychainDatabase.shared.unlock()
                guard generation == keychainGeneration else { return }
                keychainState = .suspended
                focusRequest += 1
            } catch {
                guard generation == keychainGeneration else { return }
                keychainState = .locked
                keychainError = error.localizedDescription
            }
        }
    }

    @objc func lockApp() {
        guard keychainState != .locked, keychainLockTask == nil else { return }
        let operationWasBusy = isBusy
        keychainGeneration = UUID()
        keychainState = .locked
        keychainError = nil
        clearKeychainInterface()
        operationCancellation?.cancel()
        isBusy = true
        keychainLockTask = Task { await KeychainDatabase.shared.lock() }
        if !operationWasBusy { finishOperation() }
    }

    private func suspendKeychainInterface() {
        if keychainState == .unlocked { keychainState = .suspended }
        hidePanel()
        clearKeychainInterface()
        operationCancellation?.cancel()
    }

    private func resumeKeychainInterface() {
        guard keychainState == .suspended, !isBusy, panel?.isVisible == true else { return }
        keychainState = .unlocked
        refresh()
        let chrome = priorApp?.bundleIdentifier == ChromeTab.bundleIdentifier ? priorApp : nil
        startWebsiteMonitor(chrome: chrome)
    }

    private func finishOperation() {
        if let lockTask = keychainLockTask {
            Task {
                await lockTask.value
                keychainLockTask = nil
                isBusy = false
            }
            return
        }
        isBusy = false
        resumeKeychainInterface()
    }

    private func clearKeychainInterface() {
        if let sheet = panel?.attachedSheet {
            panel?.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
        stopWebsiteMonitor()
        hideDraftPassword()
        clipboard.clearIfOwned()
        entries = []
        loaded = false
        selected = nil
        search = ""
        categoryFilter = .all
        savedCategories = []
        categoryColorSlots = [:]
        editing = false
        editingEntry = nil
        draft = CredentialDraft()
        showingPasswordGenerator = false
        deletionTarget = nil
        invalidWebsite = false
        invalidLoginName = false
        invalidPassword = false
        walletItems = []
        walletKind = nil
        walletLoaded = false
        walletSearch = ""
        walletScreen = .list
        walletDraft = WalletDraft(kind: .address)
        walletResume = nil
        walletDeletionTarget = nil
        notice = nil
        focusRequest += 1
    }

    private func requireOpenKeychain() throws {
        guard keychainState == .unlocked else { throw KeychainFailure.locked }
    }

    func importEncryptedVault() {
        guard keychainState == .unlocked, !isBusy, let panel else { return }
        isBusy = true
        notice = nil
        Task {
            defer { finishOperation() }
            let alert = NSAlert()
            alert.messageText = "Import your encrypted vault?"
            alert.informativeText = "Enter the master password you used for the encrypted vault. Stasher copies its records into your local login Keychain and keeps the original file and any conflicting Keychain records."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 242, height: 24))
            field.placeholderString = "Vault master password"
            field.setAccessibilityLabel("Vault master password")
            alert.accessoryView = field
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            let response = await alert.beginSheetModal(for: panel)
            defer { field.stringValue = "" }
            guard response == .alertFirstButtonReturn, keychainState == .unlocked else { return }

            let password = field.stringValue
            field.stringValue = ""
            guard !password.isEmpty else {
                notice = PanelNotice(text: "Enter your vault master password to import.",
                                     icon: "exclamationmark.circle", isError: true)
                return
            }

            let cancellation = CancellationToken()
            operationCancellation = cancellation
            defer { operationCancellation = nil }
            do {
                let result = try await VaultMigration.importAll(password: password, cancellation: cancellation)
                guard keychainState == .unlocked else { return }
                let records = try await store.list()
                guard keychainState == .unlocked else { return }
                try await rememberCategories(records.map(\.category))
                entries = records
                loaded = true
                if let kind = walletKind {
                    let items = try await walletStore.list(kind)
                    guard keychainState == .unlocked else { return }
                    walletItems = items
                    walletLoaded = true
                }
                notice = PanelNotice(text: "Imported \(result.imported). Already in Keychain: \(result.skipped). Conflicts kept: \(result.conflicts).",
                                     icon: "checkmark.circle.fill")
            } catch { report(error) }
        }
    }
}

extension AppController {
    var isWalletList: Bool {
        if case .list = walletScreen { return true }
        return false
    }

    var visibleWalletItems: [WalletSummary] {
        let query = walletSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return walletItems }
        return walletItems.filter {
            $0.label.localizedStandardContains(query) || $0.subtitle.localizedStandardContains(query)
        }
    }

    func selectWallet(_ kind: WalletKind?) {
        guard keychainState == .unlocked else { return }
        guard walletKind != kind, !isBusy, !editing, !showingPasswordGenerator, isWalletList else { return }
        walletKind = kind
        walletResume = nil
        walletSearch = ""
        notice = nil
        focusRequest += 1
        if let kind {
            stopWebsiteMonitor()
            walletItems = []
            walletLoaded = false
            refreshWallet(kind)
        } else {
            let chrome = priorApp?.bundleIdentifier == ChromeTab.bundleIdentifier ? priorApp : nil
            startWebsiteMonitor(chrome: chrome)
            if !loaded { refresh() }
        }
    }

    func refreshWallet(_ kind: WalletKind) {
        guard keychainState == .unlocked else { return }
        guard walletKind == kind, !isBusy else { return }
        isBusy = true
        notice = nil
        Task {
            defer { finishOperation() }
            do {
                let records = try await walletStore.list(kind)
                guard keychainState == .unlocked else { return }
                walletItems = records
                walletLoaded = true
            } catch { report(error) }
        }
    }

    func openWalletRecord(_ summary: WalletSummary) {
        guard keychainState == .unlocked else { return }
        guard walletKind == summary.kind, !isBusy else { return }
        isBusy = true
        notice = nil
        Task {
            defer { finishOperation() }
            do {
                let record = try await walletStore.read(summary)
                guard keychainState == .unlocked else { return }
                walletScreen = .details(record)
            } catch { report(error) }
        }
    }

    func openWalletEditor(_ kind: WalletKind, record: WalletRecord? = nil) {
        guard keychainState == .unlocked else { return }
        guard walletKind == kind, !isBusy else { return }
        notice = nil
        walletDraft = WalletDraft(kind: kind, record: record)
        walletScreen = .editor(record?.summary)
    }

    func openAddressGenerator() {
        guard keychainState == .unlocked else { return }
        guard walletKind == .address, isWalletList, !isBusy else { return }
        notice = nil
        walletScreen = .addressGenerator
    }

    func useGeneratedAddress(_ address: WalletRecord) {
        guard keychainState == .unlocked else { return }
        guard walletKind == .address, case .addressGenerator = walletScreen, !isBusy else { return }
        walletDraft = WalletDraft(kind: .address, record: address)
        walletScreen = .editor(nil)
    }

    func closeWalletScreen() {
        guard !isBusy else { return }
        resetWalletScreen()
        notice = nil
        focusRequest += 1
    }

    private func resetWalletScreen() {
        walletScreen = .list
        walletResume = nil
        walletDraft = WalletDraft(kind: walletKind ?? .address)
    }

    func saveWallet(_ kind: WalletKind) {
        guard keychainState == .unlocked else { return }
        guard walletKind == kind, case .editor(let original) = walletScreen, !isBusy else { return }
        let record: WalletRecord
        do {
            record = try walletDraft.record(kind: kind, id: original?.id ?? UUID())
        } catch {
            notice = PanelNotice(text: error.localizedDescription, icon: "exclamationmark.circle", isError: true)
            return
        }
        isBusy = true
        notice = nil
        Task {
            defer { finishOperation() }
            do {
                let saved = try await walletStore.save(record, editing: original != nil,
                                                      expectedModifiedAt: original?.modifiedAt)
                guard keychainState == .unlocked else { return }
                walletItems.removeAll { $0.id == saved.summary.id }
                walletItems.insert(saved.summary, at: 0)
                walletLoaded = true
                walletSearch = ""
                resetWalletScreen()
                focusRequest += 1
                notice = PanelNotice(text: kind == .address ? "Address saved" : "Card saved",
                                     icon: "checkmark.circle.fill")
            } catch { report(error) }
        }
    }

    func copyWalletValue(_ value: String, title: String, from summary: WalletSummary) {
        guard keychainState == .unlocked else { return }
        guard !isBusy, !value.isEmpty else { return }
        do {
            walletResume = pinned ? nil : summary
            try finishCopy(value, message: "\(title) copied")
        } catch {
            walletResume = nil
            report(error)
        }
    }

    func deleteWallet(_ summary: WalletSummary) {
        guard keychainState == .unlocked else { return }
        guard walletKind == summary.kind, !isBusy else { return }
        isBusy = true
        notice = nil
        Task {
            defer { finishOperation() }
            do {
                try await walletStore.delete(summary)
                guard keychainState == .unlocked else { return }
                walletItems.removeAll { $0.id == summary.id }
                resetWalletScreen()
                focusRequest += 1
                notice = PanelNotice(text: summary.kind == .address ? "Address deleted" : "Card deleted",
                                     icon: "checkmark.circle.fill")
            } catch { report(error) }
        }
    }
}

final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
