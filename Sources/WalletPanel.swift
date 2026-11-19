import SwiftUI

struct WalletPanel: View {
    @ObservedObject var controller: AppController
    let kind: WalletKind
    let accent: Color

    @Environment(\.colorScheme) private var scheme
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case search, label, field(WalletField) }

    private var dark: Bool { scheme == .dark }
    private var fill: Color { .primary.opacity(dark ? 0.08 : 0.048) }
    private var border: Color { .primary.opacity(dark ? 0.14 : 0.10) }

    var body: some View {
        Group {
            switch controller.walletScreen {
            case .list:
                list
            case .details(let record):
                details(record)
            case .editor(let original):
                editor(isNew: original == nil)
            case .addressGenerator:
                AddressGeneratorView(accent: accent, back: controller.closeWalletScreen,
                                     copy: controller.copyGeneratedText, use: controller.useGeneratedAddress)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(kind == .address ? "Delete address?" : "Delete card?",
               isPresented: Binding(
                get: { controller.walletDeletionTarget != nil },
                set: { if !$0 { controller.walletDeletionTarget = nil } }
               ),
               presenting: controller.walletDeletionTarget) { item in
            Button("Delete", role: .destructive) { controller.deleteWallet(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("This removes \(item.label) from your Keychain.")
        }
    }

    private var list: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(kind == .address ? "Search addresses" : "Search cards", text: $controller.walletSearch)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .search)
                        .onSubmit {
                            if let item = controller.visibleWalletItems.first { controller.openWalletRecord(item) }
                        }
                    if !controller.walletSearch.isEmpty {
                        Button {
                            controller.walletSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .font(.system(size: 14))
                .padding(.horizontal, 11)
                .frame(height: 41)
                .background(fill, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(focus == .search ? accent.opacity(0.65) : border)
                        .allowsHitTesting(false)
                }
                if kind == .address {
                    Button("Generate", systemImage: "dice", action: controller.openAddressGenerator)
                        .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent))
                        .disabled(controller.isBusy)
                        .accessibilityLabel("Generate test addresses")
                        .help("Generate test addresses")
                }
                Button("Add", systemImage: "plus") { controller.openWalletEditor(kind) }
                    .buttonStyle(PanelAction(primary: true, dark: dark, accent: accent))
                    .disabled(controller.isBusy)
                    .accessibilityLabel(kind == .address ? "Add address" : "Add card")
            }
            if controller.visibleWalletItems.isEmpty {
                emptyList
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(controller.visibleWalletItems, content: listRow)
                    }
                }
            }
            HStack {
                status
                Spacer(minLength: 0)
            }
            .frame(minHeight: 25)
        }
        .task(id: controller.focusRequest) {
            do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
            focus = .search
        }
    }

    @ViewBuilder private var emptyList: some View {
        VStack(spacing: 8) {
            if controller.isBusy && !controller.walletLoaded {
                ProgressView().controlSize(.small).accessibilityLabel("Loading")
            } else if !controller.walletLoaded, controller.notice?.isError == true {
                Button("Try Again") { controller.refreshWallet(kind) }
                    .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent))
            } else {
                Image(systemName: kind.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(controller.walletSearch.isEmpty ? (kind == .address ? "No saved addresses" : "No saved cards") : "No matching records")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listRow(_ item: WalletSummary) -> some View {
        Button {
            controller.openWalletRecord(item)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: kind.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(WalletRowStyle())
        .disabled(controller.isBusy)
    }

    private func details(_ record: WalletRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button("Back", systemImage: "chevron.left", action: controller.closeWalletScreen)
                    .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent, compact: true))
                    .accessibilityLabel("Back to \(kind.title)")
                Text(record.summary.label)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button("Edit", systemImage: "pencil") { controller.openWalletEditor(kind, record: record) }
                    .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent, compact: true))
                Button(role: .destructive) {
                    controller.walletDeletionTarget = record.summary
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 23, height: 27)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind == .address ? "Delete address" : "Delete card")
                .help(kind == .address ? "Delete address" : "Delete card")
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(kind.detailFields.filter { !record.value($0).isEmpty }, id: \.self) { field in
                        detailRow(field, record: record)
                        Divider()
                    }
                }
            }
            HStack(spacing: 8) {
                status
                Spacer(minLength: 0)
                if kind == .address {
                    Button("Copy Full Address", systemImage: "document.on.document") {
                        controller.copyWalletValue(record.mailingAddress, title: "Address", from: record.summary)
                    }
                    .buttonStyle(PanelAction(primary: true, dark: dark, accent: accent, compact: true))
                }
            }
            .frame(minHeight: 38)
        }
        .disabled(controller.isBusy)
    }

    private func detailRow(_ field: WalletField, record: WalletRecord) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(record.display(field))
                    .font(.system(size: 13, design: field.isMasked ? .monospaced : .default))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if field == .expiration {
                Menu {
                    let parts = record.value(field).split(separator: "/")
                    if parts.count == 2 {
                        Button("Copy Month") {
                            controller.copyWalletValue(String(parts[0]), title: "Expiry month", from: record.summary)
                        }
                        Button("Copy Year") {
                            controller.copyWalletValue(String(parts[1]), title: "Expiry year", from: record.summary)
                        }
                    }
                    Button("Copy Full Expiry Date") { copy(field, record: record) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Expiry date copy options")
                .help("Expiry date copy options")
            }
            Button("Copy", systemImage: "document.on.document") { copy(field, record: record) }
                .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent, compact: true))
                .accessibilityLabel("Copy \(field.title.lowercased())")
        }
        .padding(.vertical, 7)
    }

    private func copy(_ field: WalletField, record: WalletRecord) {
        controller.copyWalletValue(record.value(field), title: field.title, from: record.summary)
    }

    private func editor(isNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(kind == .address ? (isNew ? "Add Address" : "Edit Address") : (isNew ? "Add Card" : "Edit Card"))
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        textInput("Label", required: true, target: .label) {
                            TextField(kind == .address ? "e.g. Home" : "e.g. Personal", text: $controller.walletDraft.label)
                        }
                        ForEach(kind.fieldRows.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 9) {
                                ForEach(kind.fieldRows[index], id: \.self, content: editorField)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onChange(of: focus) {
                    if let focus { scroll.scrollTo(focus) }
                }
            }
            HStack(spacing: 8) {
                status
                Spacer(minLength: 0)
                Button("Cancel", action: controller.closeWalletScreen)
                    .buttonStyle(PanelAction(primary: false, dark: dark, accent: accent))
                Button("Save") { controller.saveWallet(kind) }
                    .buttonStyle(PanelAction(primary: true, dark: dark, accent: accent))
            }
            .padding(.bottom, 10)
        }
        .disabled(controller.isBusy)
        .onSubmit { controller.saveWallet(kind) }
        .task { focus = .label }
    }

    @ViewBuilder private func editorField(_ field: WalletField) -> some View {
        let value = Binding(
            get: { controller.walletDraft.fields[field, default: ""] },
            set: { controller.walletDraft.fields[field] = $0 }
        )
        if field == .country {
            VStack(alignment: .leading, spacing: 5) {
                Text("Country or region (required)").font(.system(size: 12, weight: .medium))
                Picker("Country or region", selection: value) {
                    Text("Choose a country or region").tag("")
                    ForEach(Country.sortedCodes, id: \.self) { code in
                        Text(Country.name(code)).tag(code)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Country or region (required)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            textInput(field.title, required: field.isRequired, target: .field(field)) {
                if field.isMasked {
                    SecureField(field.placeholder, text: value)
                } else {
                    TextField(field.placeholder, text: value)
                }
            }
        }
    }

    private func textInput<Content: View>(_ title: String, required: Bool, target: Focus,
                                          @ViewBuilder content: () -> Content) -> some View {
        let label = required ? "\(title) (required)" : title
        return VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .medium))
            content()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(focus == target ? accent.opacity(0.65) : border)
                        .allowsHitTesting(false)
                }
                .focused($focus, equals: target)
                .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(target)
    }

    private var status: some View {
        Group {
            if let notice = controller.notice {
                Label(notice.text, systemImage: notice.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(notice.isError ? .red : accent)
                    .fixedSize(horizontal: false, vertical: true)
            } else if controller.isWalletList {
                Label("Saved in Keychain", systemImage: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WalletRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.09 : 0.04),
                        in: RoundedRectangle(cornerRadius: 9))
    }
}
