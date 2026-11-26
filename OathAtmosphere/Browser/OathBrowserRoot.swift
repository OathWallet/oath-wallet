import SwiftUI
import OathBrowser

struct OathBrowserRoot: View {
    let controller: OathBrowserController
    let session: OathWalletSession
    let searchEngine: BrowserSearchEngine
    let showsRecentSites: Bool
    let active: Bool
    @Namespace private var tabPreviews
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.oathLocalizer) private var strings

    private var available: Bool { active && session.isUnlocked && scenePhase != .background }

    var body: some View {
        NavigationStack(path: Binding(get: { controller.navigation.path }, set: { path in
            if available { controller.setPath(path) }
        })) {
            OathBrowserStartPage(controller: controller, session: session, showsRecentSites: showsRecentSites)
                .navigationDestination(for: BrowserNavigation.Route.self) { route in
                    switch route {
                    case .tabs:
                        OathBrowserTabOverview(controller: controller, namespace: tabPreviews) { controller.showStart() }
                    case .page:
                        OathBrowserScreen(controller: controller, session: session, namespace: tabPreviews, onExit: controller.goBack)
                    case .connections(let walletID):
                        OathWalletConnectPage(session: session, walletID: walletID)
                            .toolbar(.hidden, for: .bottomBar)
                    }
                }
        }
        .toolbar(controller.navigation.path.isEmpty ? .visible : .hidden, for: .tabBar)
        .tint(nil)
        .oathBrowserLibrary(isPresented: Binding(get: { active && controller.showsLibrary }, set: { presented in
            if available && controller.isForeground { controller.presentLibrary(presented) }
        }), controller: controller)
        .alert(strings.text(.browserTitle), isPresented: Binding(get: { controller.notice != nil }, set: { if !$0 { controller.notice = nil } })) {
            Button(strings.text(.done)) { controller.notice = nil }
        } message: { if let notice = controller.notice { Text(strings.text(notice)) } }
        .onChange(of: searchEngine, initial: true) { controller.searchEngine = searchEngine }
        .task(id: available) {
            guard available else { controller.suspend(); return }
            await controller.load(session: session)
            guard !Task.isCancelled, session.isUnlocked else { return }
            controller.isForeground = true
        }
        .onDisappear { controller.suspend() }
    }
}
