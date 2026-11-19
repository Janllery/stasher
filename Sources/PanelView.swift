import AppKit
import SwiftUI

private let lightAccent = Color(red: 0.13, green: 0.38, blue: 0.32)

struct PasswordPanel: View {
    private static let categoryHues: [Double] = [0.46, 0.59, 0.075, 0.76, 0.015, 0.31, 0.88, 0.52, 0.12, 0.68, 0.95, 0.38]

    @ObservedObject var controller: AppController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focused: Field?

    private enum Field: Hashable { case search, website, name, loginName, password, category, remarks }

    private var dark: Bool { scheme == .dark }
    private var accent: Color { dark ? Color(red: 0.58, green: 0.80, blue: 0.70) : lightAccent }
    private var paper: Color {
        dark ? Color(red: 0.10, green: 0.13, blue: 0.12) : Color(red: 0.976, green: 0.976, blue: 0.949)
    }
    private var soft: Color { .primary.opacity(dark ? 0.08 : 0.048) }
    private var line: Color { .primary.opacity(dark ? 0.14 : 0.10) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 23) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            if controller.keychainState != .unlocked {
                KeychainAccessView(controller: controller, accent: accent)
            } else if controller.showingPasswordGenerator {
                PasswordGeneratorView(controller: controller, accent: accent)
            } else if controller.editing {
                editor
            } else if let kind = controller.walletKind {
                if controller.isWalletList { sectionPicker }
                WalletPanel(controller: controller, kind: kind, accent: accent)
            } else {
                sectionPicker
                searchBar
                    .padding(.bottom, 9)
                categoryBar
                    .padding(.bottom, 8)
                entries
                    .frame(minHeight: 0, maxHeight: .infinity)
                listStatus
                    .frame(minHeight: 29)
            }
            Divider().overlay(line)
            footer
                .padding(.top, 13)
        }
        .padding(.horizontal, 21)
        .padding(.top, 19)
        .padding(.bottom, 14)
        .frame(width: AppController.width, height: AppController.height)
        .background {
            let opacity = reduceTransparency ? 1 : controller.opacity
            ZStack {
                if opacity < 1 {
                    DesktopBlur().opacity((1 - opacity) * 1.2)
                }
                paper.opacity(opacity)
            }
            .clipShape(shape)
        }
        .overlay { shape.strokeBorder(line, lineWidth: 1).allowsHitTesting(false) }
        .tint(accent)
        .task(id: controller.focusRequest) {
            guard controller.keychainState == .unlocked, controller.walletKind == nil else { return }
            // The new field needs to be installed before AppKit can give it focus.
            do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
            focused = controller.editing ? .website : .search
        }
        .alert("Delete password?", isPresented: Binding(
            get: { controller.deletionTarget != nil },
            set: { if !$0 { controller.deletionTarget = nil } }
        ), presenting: controller.deletionTarget) { entry in
            Button("Delete", role: .destructive) { controller.delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("This removes \(entry.name) from your Keychain.")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(accent.opacity(dark ? 0.19 : 0.12))
                Image(nsImage: StasherMark.templateImage())
                    .renderingMode(.template)
                    .foregroundStyle(accent)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            Text("Stasher")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.5)
                .accessibilityAddTraits(.isHeader)
            Spacer()

            iconButton(controller.pinned ? "Unpin Panel" : "Keep Panel on Top",
                       icon: controller.pinned ? "pin.fill" : "pin",
                       selected: controller.pinned, action: controller.togglePin)
                .accessibilityValue(controller.pinned ? "Pinned" : "Unpinned")

            Menu {
                if controller.keychainState == .unlocked, controller.walletKind == nil {
                    Button("Generate Password…", systemImage: "wand.and.stars", action: controller.openPasswordGenerator)
                        .disabled(controller.showingPasswordGenerator || controller.isBusy)
                    Button("Import CSV…", systemImage: "square.and.arrow.down", action: controller.importCSV)
                        .disabled(controller.editing || controller.showingPasswordGenerator || controller.isBusy)
                    Button("Export CSV…", systemImage: "square.and.arrow.up", action: controller.exportCSV)
                        .disabled(controller.editing || controller.showingPasswordGenerator || controller.isBusy)
                    Divider()
                }
                if controller.keychainState == .unlocked {
                    Button("Refresh Records", systemImage: "arrow.clockwise") {
                        if let kind = controller.walletKind { controller.refreshWallet(kind) }
                        else { controller.refresh() }
                    }
                    .disabled(controller.isBusy || controller.editing || !controller.isWalletList)
                    Button("Import Encrypted Vault…", systemImage: "tray.and.arrow.down",
                           action: controller.importEncryptedVault)
                        .disabled(controller.isBusy || controller.editing || !controller.isWalletList)
                    Button("Lock App", systemImage: "lock", action: controller.lockApp)
                    Divider()
                }
                Button("Quit Stasher", systemImage: "power", action: controller.quit)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 31, height: 31)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
            .help("More actions")

            iconButton("Close panel", icon: "xmark", action: controller.closePanel)
                .disabled(controller.isBusy)
        }
    }

    private var sectionPicker: some View {
        Picker("Record type", selection: Binding(get: { controller.walletKind }, set: controller.selectWallet)) {
            Text("Passwords").tag(Optional<WalletKind>.none)
            Text(WalletKind.address.title).tag(Optional(WalletKind.address))
            Text(WalletKind.card.title).tag(Optional(WalletKind.card))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(controller.isBusy)
        .padding(.bottom, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search passwords", text: $controller.search)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .focused($focused, equals: .search)
                    .onSubmit { controller.copySelected() }
                    .help("Search by name, website, or username")
                if !controller.search.isEmpty {
                    Button {
                        controller.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 41)
            .background(soft, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(focused == .search ? accent.opacity(0.70) : line, lineWidth: 1)
                    .allowsHitTesting(false)
            }

            Button("Generate", systemImage: "wand.and.stars", action: controller.openPasswordGenerator)
                .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent))
                .disabled(controller.isBusy)
                .accessibilityLabel("Generate a password")
                .help("Generate a password, passphrase, or PIN")

            Button {
                controller.openEditor()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(PanelAction(primary: true, dark: dark, accent: accent))
            .disabled(controller.isBusy)
            .help("Add password (⌘N)")
        }
    }

    private var categoryBar: some View {
        let filters: [CategoryFilter] = [.all, .uncategorized] + controller.categories.map(CategoryFilter.named)
        return HStack(spacing: 8) {
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(filters, id: \.self) { filter in
                            let selected = controller.categoryFilter == filter
                            let categoryTint: Color? = if case .named(let name) = filter { categoryColor(name) } else { nil }
                            let foreground = categoryTint ?? (selected ? accent : .secondary)
                            let background = selected ? foreground.opacity(0.19) : categoryTint?.opacity(0.10) ?? soft
                            Button {
                                controller.categoryFilter = filter
                            } label: {
                                HStack(spacing: 5) {
                                    if let categoryTint {
                                        Circle().fill(categoryTint).frame(width: 6, height: 6)
                                            .accessibilityHidden(true)
                                    }
                                    Text(filter.title).lineLimit(1)
                                }
                                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 25)
                                    .foregroundStyle(foreground)
                                    .background(background, in: Capsule())
                                    .overlay {
                                        if selected {
                                            Capsule().strokeBorder(foreground.opacity(0.36))
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .id(filter)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .accessibilityLabel("Filter by category")
                .onChange(of: controller.categoryFilter) { scroll.scrollTo(controller.categoryFilter) }
            }
            Button(action: controller.addCategory) {
                Label("New Category", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .frame(minHeight: 25)
                    .foregroundStyle(accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.isBusy)
        }
        .frame(height: 26)
    }

    private func categoryColor(_ name: String) -> Color {
        let slot = controller.categoryColorSlots[name] ?? 0
        let hue = Self.categoryHues.indices.contains(slot) ? Self.categoryHues[slot]
            : (Double(slot) * 0.61803398875).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: dark ? 0.48 : 0.83, brightness: dark ? 0.92 : 0.43)
    }

    @ViewBuilder private var entries: some View {
        if controller.isBusy && !controller.loaded {
            emptyView(icon: "lock", title: "Reading Keychain…", description: nil)
        } else if !controller.loaded, controller.notice?.isError == true {
            VStack(spacing: 12) {
                emptyView(icon: "lock.trianglebadge.exclamationmark", title: "Could not load passwords",
                          description: nil)
                Button("Try Again", action: controller.refresh)
                    .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if controller.listedEntries.isEmpty {
            if controller.search.isEmpty {
                if controller.categoryFilter == .all {
                    emptyView(icon: "key.horizontal", title: "No passwords yet",
                              description: "Select Add to save your first password.")
                } else {
                    emptyView(icon: "folder", title: "No passwords in this category", description: nil)
                }
            } else {
                emptyView(icon: "magnifyingglass", title: "No matching passwords",
                          description: "Try a site name, domain, or username.")
            }
        } else {
            let suggestions = controller.websiteSuggestions
            let suggestedHeader = "websiteSuggestions"
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if !suggestions.isEmpty, let site = controller.suggestedSite {
                            HStack(spacing: 8) {
                                Label("Suggested for this site", systemImage: "globe")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .accessibilityAddTraits(.isHeader)
                                Text(site.host)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .id(suggestedHeader)
                            ForEach(suggestions) { entry in
                                row(entry).id(entry.id)
                            }
                            if controller.listedEntries.count > suggestions.count {
                                Divider().overlay(line).padding(.vertical, 4)
                            }
                        }
                        ForEach(controller.listedEntries.dropFirst(suggestions.count)) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .onChange(of: controller.selected) {
                    if let selected = controller.selected {
                        if suggestions.first?.id == selected {
                            scroll.scrollTo(suggestedHeader, anchor: .top)
                        } else {
                            scroll.scrollTo(selected)
                        }
                    }
                }
                .onChange(of: suggestions.first?.id) {
                    if !suggestions.isEmpty { scroll.scrollTo(suggestedHeader, anchor: .top) }
                }
            }
        }
    }

    private func emptyView(icon: String, title: String, description: String?) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 56, height: 56)
                .background(accent.opacity(dark ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            if let description {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ entry: Credential) -> some View {
        let selected = controller.selected == entry.id
        let website = entry.url.absoluteString
        let remarks = entry.remarks.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginLabel = entry.loginName.isEmpty ? "" : ", username \(entry.loginName)"
        let categoryLabel = entry.category.isEmpty ? "" : ", category \(entry.category)"
        let remarksLabel = remarks.isEmpty ? "" : ", notes \(remarks)"
        let accessibilityLabel = entry.name + categoryLabel + loginLabel + ", URL \(website)" + remarksLabel
        return HStack(spacing: 9) {
            Button {
                controller.selected = entry.id
            } label: {
                HStack(spacing: 10) {
                    Text(String(entry.name.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .frame(width: 33, height: 33)
                        .background(accent.opacity(dark ? 0.18 : 0.10),
                                    in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            if !entry.category.isEmpty {
                                let tint = categoryColor(entry.category)
                                Text(entry.category)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                                    .foregroundStyle(tint)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(tint.opacity(0.12), in: Capsule())
                                    .frame(maxWidth: 74, alignment: .leading)
                            }
                        }
                        if !entry.loginName.isEmpty {
                            Text(entry.loginName)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        Text(website)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        if !remarks.isEmpty {
                            Text("Notes · \(remarks)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(remarks.isEmpty ? website : "\(website)\n\(remarks)")
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(selected ? .isSelected : [])

            VStack(spacing: 4) {
                if !entry.loginName.isEmpty {
                    Button {
                        controller.copyLoginName(entry)
                    } label: {
                        Label("Username", systemImage: "person")
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 84, alignment: .leading)
                    }
                    .accessibilityLabel("Copy username for \(entry.name)")
                    .help("Copy username")
                }
                Button {
                    controller.copy(entry)
                } label: {
                    Label("Password", systemImage: "document.on.document")
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 84, alignment: .leading)
                }
                .accessibilityLabel("Copy password for \(entry.name)")
                .help("Copy password")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent, compact: true))
            .disabled(controller.isBusy)

            Menu {
                Button("Copy Username and Password", systemImage: "document.on.document") {
                    controller.copy(entry, includingLoginName: true)
                }
                .disabled(entry.loginName.isEmpty || controller.isBusy)
                Divider()
                Button("Open Website", systemImage: "arrow.up.right") { controller.openWebsite(entry) }
                Button("Edit Password", systemImage: "pencil") { controller.openEditor(entry) }
                Divider()
                Button("Delete Password", systemImage: "trash", role: .destructive) { controller.deletionTarget = entry }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 29)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(entry.name)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minHeight: 55)
        .background(selected ? accent.opacity(dark ? 0.14 : 0.075) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(0.24))
                    .allowsHitTesting(false)
            }
        }
    }

    private var listStatus: some View {
        HStack(spacing: 6) {
            if let notice = controller.notice {
                status(notice)
            } else if controller.websitePermissionDenied {
                Text("Allow Automation to get suggestions from Chrome.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("System Settings → Privacy & Security → Automation → Stasher → Google Chrome")
                Spacer()
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Saved in Keychain")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if !controller.listedEntries.isEmpty {
                    Text("↑↓ Select  ↵ Copy password")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(controller.editingEntry == nil ? "Add Password" : "Edit Password")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top, spacing: 10) {
                            formField("Website URL", field: .website,
                                      error: controller.invalidWebsite ? "Enter a valid URL." : nil) {
                                TextField("example.com", text: $controller.draft.website)
                            }
                            formField("Site name (optional)", field: .name, error: nil) {
                                TextField("Use the domain", text: $controller.draft.name)
                            }
                            .frame(width: 146)
                        }
                        formField("Username (required)", field: .loginName,
                                  error: controller.invalidLoginName ? "Enter a username." : nil) {
                            TextField("Username or email address", text: $controller.draft.loginName)
                        }
                        HStack(alignment: .top, spacing: 10) {
                            passwordField
                            categoryField.frame(width: 146)
                        }
                        formField("Notes (optional)", field: .remarks, error: nil, height: 54) {
                            TextField("Enter notes", text: $controller.draft.remarks, axis: .vertical)
                                .lineLimit(2, reservesSpace: true)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onChange(of: focused) {
                    if let focused { scroll.scrollTo(focused) }
                }
            }
            HStack(spacing: 8) {
                if let notice = controller.notice { status(notice) }
                Spacer(minLength: 0)
                Button("Cancel", action: controller.endEditing)
                    .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent))
                    .disabled(controller.isBusy)
                Button("Save", action: saveEditor)
                    .buttonStyle(PanelAction(primary: true, dark: dark, accent: accent))
                    .disabled(controller.isBusy)
            }
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
        .onSubmit(saveEditor)
    }

    private func saveEditor() {
        controller.save()
        if controller.invalidWebsite { focused = .website }
        else if controller.invalidLoginName { focused = .loginName }
        else if controller.invalidPassword { focused = .password }
    }

    private var passwordField: some View {
        let isNew = controller.editingEntry == nil
        let isVisible = isNew && controller.showsDraftPassword
        let label = isVisible ? "Hide password" : "Show password"
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 5) {
                formField("Password", field: .password,
                          error: controller.invalidPassword ? "Enter a password." : nil) {
                    SecureField(isNew ? "Enter a password" : "Leave blank to keep it", text: $controller.draft.password)
                }
                .overlay(alignment: .topTrailing) {
                    Button("Generate Password", systemImage: "wand.and.stars", action: controller.openPasswordGenerator)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                        .disabled(controller.isBusy)
                }
                if isNew {
                    Button(action: controller.toggleDraftPassword) {
                        Image(systemName: isVisible ? "eye.slash" : "eye")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 28, height: 29)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .accessibilityLabel(label)
                    .help(label)
                    .disabled(controller.isBusy)
                    .padding(.top, 23)
                }
            }
            if isVisible, !controller.draft.password.isEmpty {
                Text(verbatim: controller.draft.password)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(soft, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Entered password")
                    .accessibilityValue(controller.draft.password)
            }
        }
    }

    private var categoryField: some View {
        HStack(alignment: .bottom, spacing: 4) {
            formField("Category (optional)", field: .category, error: nil) {
                TextField("Uncategorized", text: $controller.draft.category)
            }
            Menu {
                Button("Uncategorized") { controller.draft.category = "" }
                ForEach(controller.categories, id: \.self) { name in
                    Button(name) { controller.draft.category = name }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 23, height: 35)
                    .background(soft, in: RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Choose an existing category")
            .help("Choose an existing category or enter a new name.")
            .disabled(controller.isBusy)
        }
    }

    private func formField<Content: View>(_ label: String, field: Field, error: String?, height: CGFloat = 36,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            content()
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 11)
                .frame(height: height)
                .background(soft, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(error != nil ? .red : focused == field ? accent.opacity(0.7) : line)
                        .allowsHitTesting(false)
                }
                .focused($focused, equals: field)
                .accessibilityLabel(label)
                .disabled(controller.isBusy)
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .id(field)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(accent)
                .font(.system(size: 13))
                .accessibilityHidden(true)
            Text("Opacity")
                .font(.system(size: 11, weight: .medium))
                .fixedSize()
            Slider(value: $controller.opacity, in: controller.opacityRange, step: 0.01)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 96)
                .disabled(reduceTransparency)
                .accessibilityLabel("Opacity")
                .accessibilityValue(reduceTransparency ? "100%" : "\(Int((controller.opacity * 100).rounded()))%")
                .help("Adjust the panel background opacity")
            Text(reduceTransparency ? "100%" : "\(Int((controller.opacity * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                .accessibilityHidden(true)
            Spacer(minLength: 10)
            if let shortcut = controller.shortcut {
                Text(shortcut.label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(soft, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Global shortcut \(shortcut.label)")
                    .help("Global shortcut \(shortcut.label)")
            } else {
                Text("Shortcut unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Use the menu bar icon to open the panel.")
            }
        }
        .frame(height: 23)
    }

    private func iconButton(_ label: String, icon: String, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 31, height: 31)
                .foregroundStyle(selected ? accent : .secondary)
                .background(selected ? accent.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(IconHover(dark: dark))
        .accessibilityLabel(label)
        .help(label)
    }

    private func status(_ notice: PanelNotice) -> some View {
        Label(notice.text, systemImage: notice.icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(notice.isError ? .red : accent)
            .fixedSize(horizontal: false, vertical: true)
    }

}

struct PanelAction: ButtonStyle {
    var primary: Bool
    var dark: Bool
    var accent: Color
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, primary: primary, dark: dark, accent: accent, compact: compact)
    }

    private struct Face: View {
        let configuration: Configuration
        let primary: Bool
        let dark: Bool
        let accent: Color
        let compact: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            let fill = primary ? accent : Color.primary.opacity(hovered ? 0.10 : 0.04)
            configuration.label
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
                .foregroundStyle(primary ? (dark ? Color.black.opacity(0.87) : .white) : accent)
                .padding(.horizontal, compact ? 8 : 13)
                .frame(height: compact ? 29 : 41)
                .fixedSize(horizontal: true, vertical: false)
                .background(fill, in: RoundedRectangle(cornerRadius: compact ? 7 : 10))
                .overlay {
                    if primary && hovered {
                        RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.09)).allowsHitTesting(false)
                    }
                }
                .opacity(enabled ? 1 : 0.53)
                .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

private struct IconHover: ButtonStyle {
    let dark: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, dark: dark)
    }

    private struct Face: View {
        let configuration: Configuration
        let dark: Bool
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background(.primary.opacity(hovered ? (dark ? 0.13 : 0.07) : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .scaleEffect(!reduceMotion && configuration.isPressed ? 0.94 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

private struct DesktopBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
