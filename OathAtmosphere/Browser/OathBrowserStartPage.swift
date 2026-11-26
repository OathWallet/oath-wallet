import OathBrowser
import SwiftUI

struct OathBrowserStartPage: View {
    let controller: OathBrowserController
    let session: OathWalletSession
    let showsRecentSites: Bool
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    @State private var addingFavorite = false
    @State private var confirmingClearHistory = false
    private let connections = OathWalletConnectService.shared

    var body: some View {
        contentWithStartControls
            .toolbar(.hidden, for: .bottomBar)
            .toolbar {
                if !controller.privateMode {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(strings.text(.browserLibrary), systemImage: "book") { controller.presentLibrary(true) }
                            .accessibilityIdentifier("browser.start.library")
                    }
                }
            }
            .oathNativeAppBar(title: strings.text(.browserTitle), subtitle: controller.privateMode ? strings.text(.browserPrivate) : nil)
            .disabled(!controller.isReady)
            .onDisappear { addingFavorite = false }
            .sheet(isPresented: $addingFavorite) {
                OathBrowserAddFavorite(controller: controller)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }

    @ViewBuilder private var contentWithStartControls: some View {
        let controls = OathBrowserStartControls(controller: controller)
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        if #available(iOS 26, *) {
            startContent.safeAreaBar(edge: .bottom, spacing: 0) { controls }
        } else {
            startContent.safeAreaInset(edge: .bottom, spacing: 0) { controls }
        }
    }

    private var startContent: some View {
        ScrollView {
            if !controller.privateMode {
                VStack(alignment: .leading, spacing: 20) {
                    Text(strings.text(.browserFavorites)).font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 128 : 78), spacing: 12)],
                              alignment: .leading, spacing: 18) {
                        ForEach(controller.archive.bookmarks) { page in favorite(page) }
                        Button { addingFavorite = true } label: {
                            tile(title: strings.text(.browserAddFavorite)) {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(uiColor: .tertiarySystemFill))
                                    .overlay { Image(systemName: "plus").font(.title2.weight(.medium)) }
                            }
                        }
                        .accessibilityIdentifier("browser.favorite.add")
                    }
                    if showsRecentSites, !controller.archive.history.isEmpty {
                        recentSites
                    }
                    if let walletID = session.displayedProfile?.id.uuidString {
                        let count = connections.sessions(for: walletID).count
                        if count > 0 {
                            Divider()
                            NavigationLink(value: BrowserNavigation.Route.connections(walletID)) {
                                OathSettingsRow(title: strings.text(.browserConnectedSites), icon: "link",
                                                value: strings.number(count))
                            }
                            .buttonStyle(OathSettingsRowButtonStyle())
                            .accessibilityIdentifier("browser.start.connections")
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: OathSurfaceColors.groupedCanvas))
        .buttonStyle(.plain)
    }

    private func favorite(_ page: BrowserPageRecord) -> some View {
        let origin = try? BrowserOrigin(page.url)
        let host = origin?.host ?? ""
        let name = page.displayTitle
        return Button { controller.open(page.url) } label: {
            tile(title: name) {
                if let origin, let image = controller.favoriteImages[origin] {
                    Image(uiImage: image)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12 / displayScale, style: .continuous))
                } else {
                    let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                    Text(verbatim: domain.prefix(1).uppercased()).font(.title2.weight(.semibold))
                }
            }
        }
        .task(id: page.id) { await controller.loadFavorite(page) }
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(verbatim: host))
        .accessibilityIdentifier("browser.favorite")
        .contextMenu {
            Button(strings.text(.delete), systemImage: "trash", role: .destructive) { controller.removeBookmark(page.id) }
        }
    }

    private var recentSites: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(strings.text(.browserRecentSites)).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button { confirmingClearHistory = true } label: {
                    Text(strings.text(.clear))
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("browser.recent.clear")
                .confirmationDialog(strings.text(.browserClearHistoryPrompt), isPresented: $confirmingClearHistory,
                                    titleVisibility: .visible) {
                    Button(strings.text(.clear), role: .destructive, action: controller.clearHistory)
                    Button(strings.text(.cancel), role: .cancel) {}
                }
            }
            ForEach(controller.archive.history.prefix(8)) { page in
                Button { controller.open(page.url) } label: {
                    Label {
                        Text(verbatim: page.displayTitle).lineLimit(2)
                    } icon: {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("browser.recent")
                .contextMenu {
                    Button(strings.text(.browserRemoveFromRecents), systemImage: "trash", role: .destructive) {
                        controller.removeVisit(page.id)
                    }
                }
            }
        }
    }

    private func tile(title: String, @ViewBuilder icon: () -> some View) -> some View {
        VStack(spacing: 7) {
            icon().frame(width: 52, height: 52)
                .accessibilityHidden(true)
            Text(verbatim: title).font(.caption).lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
    }
}

private struct OathBrowserStartControls: View {
    let controller: OathBrowserController
    @State private var editing = false
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        HStack(spacing: 8) {
            OathBrowserAddressField(url: nil, origin: "", placeholder: strings.text(.browserSearchOrAddress),
                                    editing: $editing, submit: controller.navigate)
                .frame(maxWidth: .infinity, minHeight: 48)
            if #available(iOS 26, *) {
                tabsButton.buttonStyle(.glass)
            } else {
                tabsButton.buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.circle)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { editing = false }
    }

    private var tabsButton: some View {
        Button {
            if editing { editing = false }
            else { controller.showTabOverview() }
        } label: {
            Label(strings.text(editing ? .close : .browserTabs), systemImage: editing ? "xmark" : "square.on.square")
                .labelStyle(.iconOnly)
                .font(.title3)
        }
        .accessibilityIdentifier(editing ? "browser.address.cancel" : "browser.tabs")
    }
}

private struct OathBrowserAddFavorite: View {
    let controller: OathBrowserController
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""

    private var website: URL? {
        guard case .website(let url) = try? BrowserPolicy.resolve(address) else { return nil }
        return BrowserPolicy.restorable(url)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(strings.text(.browserWebsiteAddress), text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("browser.favorite.address")
                LabeledContent(strings.text(.contactName)) {
                    TextField(strings.text(.scannerWCOptional), text: $name)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("browser.favorite.name")
                }
            }
            .oathNativeAppBar(title: strings.text(.browserAddFavorite))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(strings.text(.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(strings.text(.save)) {
                        guard let website else { return }
                        controller.addFavorite(url: website, name: name)
                        dismiss()
                    }
                    .disabled(website == nil)
                    .accessibilityIdentifier("browser.favorite.save")
                }
            }
        }
    }
}
