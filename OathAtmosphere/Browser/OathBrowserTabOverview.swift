import OathBrowser
import SwiftUI

struct OathBrowserTabOverview: View {
    let controller: OathBrowserController
    let namespace: Namespace.ID
    let onExit: @MainActor () -> Void
    @State private var searching = false
    @State private var query = ""
    @State private var sortByName = false
    @State private var onScreenTabIDs: [UUID] = []
    @FocusState private var searchFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.oathLocalizer) private var strings

    private var privateGroup: Bool { controller.privateMode }
    private var group: [OathBrowserTab] { controller.groupTabs }
    private var visibleTabs: [OathBrowserTab] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = group.filter {
            term.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(term) ||
                $0.url.host?.localizedCaseInsensitiveContains(term) == true
        }
        return sortByName ? matches.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending } : matches
    }
    private var columns: [GridItem] {
        if typeSize.isAccessibilitySize { return [GridItem(.flexible())] }
        if sizeClass == .regular { return [GridItem(.adaptive(minimum: 180, maximum: 250), spacing: 16)] }
        return [GridItem(.flexible(), spacing: 14), GridItem(.flexible())]
    }
    private var previewIDToReveal: UUID? {
        guard controller.showsTabOverview else { return nil }
        return visibleTabs.first { $0.id == controller.selectedID }?.id
    }
    private var countLabel: String {
        let count = controller.tabs.count { !$0.isPrivate }
        return strings.format(count == 1 ? .browserOneTab : .browserTabCount, strings.number(count))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(uiColor: .systemGray6), Color(uiColor: .systemGray5)],
                           startPoint: .topTrailing, endPoint: .bottomLeading).ignoresSafeArea()
            if visibleTabs.isEmpty {
                if group.isEmpty {
                    ContentUnavailableView {
                        Label(strings.text(.browserNoTabs), systemImage: privateGroup ? "hand.raised" : "square.on.square")
                    } description: {
                        if privateGroup { Text(strings.text(.browserPrivateDetail)) }
                    }
                } else { ContentUnavailableView.search(text: query) }
            } else {
                ScrollViewReader { proxy in
                    let grid = ScrollView {
                        LazyVGrid(columns: columns, alignment: .center, spacing: 20) {
                            ForEach(visibleTabs) { tab in
                                tabCard(tab).id(tab.id)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: previewIDToReveal, initial: true) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                    if #available(iOS 18, *) {
                        grid.onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.1) { onScreenTabIDs = $0 }
                    } else {
                        grid
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.visible, for: .bottomBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                OathCloseButton(action: onExit).accessibilityIdentifier("browser.tabs.exit")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(strings.text(searching ? .close : .searchTitle), systemImage: searching ? "xmark" : "magnifyingglass") {
                    searching.toggle()
                    if !searching { query = "" }
                }
            }
            if searching {
                ToolbarItem(placement: .principal) {
                    TextField(strings.text(.searchTitle), text: $query)
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onAppear { searchFocused = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(strings.text(.browserLibrary), systemImage: "book") { controller.presentLibrary(true) }
                        .accessibilityIdentifier("browser.library")
                    Picker(strings.text(.assetFilterSort), selection: $sortByName) {
                        Text(strings.text(.browserTabOrder)).tag(false)
                        Text(strings.text(.assetFilterNameAscending)).tag(true)
                    }
                } label: { Label(strings.text(.moreOptions), systemImage: "ellipsis") }
                    .accessibilityIdentifier("browser.menu")
            }
            ToolbarItem(placement: .bottomBar) {
                Button(strings.text(.browserNewTab), systemImage: "plus") {
                    guard controller.session?.isUnlocked == true else { return }
                    searching = false
                    query = ""
                    controller.showStart(newTab: true)
                }
                .accessibilityIdentifier("browser.tabs.new")
            }
            if #available(iOS 26, *) {
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) { groupPicker }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible, placement: .bottomBar)
            } else {
                ToolbarItem(placement: .bottomBar) { Spacer() }
                ToolbarItem(placement: .bottomBar) { groupPicker }
                ToolbarItem(placement: .bottomBar) { Spacer() }
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    let tab = group.first { $0.id == controller.selectedID } ?? group.max { $0.lastUsed < $1.lastUsed }
                    finish(with: tab, fromPreview: tab.map { onScreenTabIDs.contains($0.id) } ?? false)
                } label: {
                    Label(strings.text(.done), systemImage: "checkmark").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                .tint(.accentColor)
                .accessibilityIdentifier("browser.tabs.done")
            }
        }
        .oathNativeAppBar()
    }

    private func finish(with tab: OathBrowserTab?, fromPreview: Bool) {
        guard controller.session?.isUnlocked == true else { return }
        if let tab {
            if !visibleTabs.contains(where: { $0.id == tab.id }) {
                searching = false
                query = ""
            }
            controller.select(tab, fromPreview: fromPreview)
        } else {
            onExit()
        }
    }

    private var groupPicker: some View {
        Picker(strings.text(.browserMode), selection: Binding(get: { privateGroup }, set: controller.selectTabGroup)) {
            Text(strings.text(.browserPrivate)).tag(true)
            Text(verbatim: countLabel).tag(false)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .onChange(of: privateGroup) { query = "" }
    }

    private func tabCard(_ tab: OathBrowserTab) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        let selected = tab.id == controller.selectedID
        return Button { finish(with: tab, fromPreview: true) } label: {
            VStack(spacing: 8) {
                let preview = shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .aspectRatio(1 / 1.4, contentMode: .fit)
                    .overlay { OathBrowserPreviewImage(tab: tab).privacySensitive() }
                    .clipShape(shape)
                Group {
                    if #available(iOS 18, *) {
                        preview.matchedTransitionSource(id: tab.id, in: namespace) { $0.clipShape(shape) }
                    } else {
                        preview
                    }
                }
                .overlay { shape.strokeBorder(selected ? Color.accentColor.opacity(0.75) : .primary.opacity(0.09),
                                              lineWidth: selected ? 2 : 0.5) }
                .shadow(color: .black.opacity(0.09), radius: 6, y: 3)
                Text(verbatim: tab.displayTitle)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: tab.displayTitle))
        .accessibilityValue(Text(verbatim: tab.url.host ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(tab.preview == nil ? "browser.tab.placeholder" : "browser.tab.preview")
        .overlay(alignment: .topTrailing) {
            Button { controller.close(tab) } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.primary)
                    .frame(width: 24, height: 24).background(.regularMaterial, in: Circle())
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(strings.text(.browserCloseTab))
            .accessibilityValue(Text(verbatim: tab.displayTitle)).accessibilityIdentifier("browser.tab.close")
        }
    }
}

private struct OathBrowserPreviewImage: UIViewRepresentable {
    let tab: OathBrowserTab

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        view.layer.cornerRadius = 15
        view.layer.cornerCurve = .continuous
        view.backgroundColor = .secondarySystemGroupedBackground
        view.tintColor = .tertiaryLabel
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        tab.previewView = view
        if let image = tab.preview {
            view.contentMode = .scaleAspectFill
            view.image = image
        } else {
            view.contentMode = .center
            view.image = UIImage(systemName: tab.isPrivate ? "hand.raised" : "globe",
                                 withConfiguration: UIImage.SymbolConfiguration(textStyle: .largeTitle))
        }
    }
}

private extension OathBrowserTab {
    var displayTitle: String { title.isEmpty ? url.host ?? "" : title }
}
