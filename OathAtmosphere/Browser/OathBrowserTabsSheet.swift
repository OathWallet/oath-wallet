import SwiftUI

struct OathBrowserTabsSheet: View {
    let tabs: OathBrowserSession
    let newTab: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        NavigationStack {
            List {
                ForEach(tabs.items) { tab in
                    HStack(spacing: 12) {
                        OathButton {
                            tabs.select(tab.id); tabs.sheet = nil
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "globe").font(.title2).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tab.page.title.isEmpty ? strings.text(.browserNewTab) : tab.page.title)
                                        .oathFont(.body, weight: .medium).lineLimit(2)
                                    if let host = OathBrowserPolicy.connectionAuthority(tab.page.url) {
                                        Text(verbatim: host).oathFont(.subheadline).foregroundStyle(.secondary)
                                            .lineLimit(1).environment(\.layoutDirection, .leftToRight)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if tab.id == tabs.selectedID {
                                    Image(systemName: "checkmark").foregroundStyle(OathOnboardingColors.blue)
                                }
                            }.frame(minHeight: 54).contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(tab.id == tabs.selectedID ? .isSelected : [])
                        .accessibilityIdentifier("browser.tab.select")
                        OathButton { tabs.close(tab.id) } label: {
                            Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel(strings.text(.close))
                        .accessibilityValue(tab.page.title.isEmpty ? strings.text(.browserNewTab) : tab.page.title)
                        .accessibilityIdentifier("browser.tab.close")
                    }.buttonStyle(.plain)
                }
            }
            .id(strings.language.isRightToLeft)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
            .navigationTitle(strings.text(.browserTabs)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { OathCloseButton { tabs.sheet = nil } }
                ToolbarItem(placement: .topBarTrailing) {
                    OathButton(action: newTab) { Image(systemName: "plus") }
                        .disabled(!tabs.canAdd).accessibilityLabel(strings.text(.browserNewTab))
                        .accessibilityIdentifier("browser.tab.new")
                }
            }
            .oathNativeLocalization()
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .oathLanguage(strings.language)
    }
}
