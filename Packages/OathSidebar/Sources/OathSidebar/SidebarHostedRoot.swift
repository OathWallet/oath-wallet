import SwiftUI

@MainActor final class SidebarHosts {
    let front = SidebarHostSource()
    let drawer = SidebarHostSource()
}

@MainActor final class SidebarHostSource: ObservableObject {
    @Published private(set) var view: AnyView?
    private var pending: AnyView?

    func submit(_ value: AnyView) {
        let scheduled = pending != nil
        pending = value
        guard !scheduled else { return }
        // A representable update runs inside SwiftUI reconciliation. Publish to
        // the child graph afterwards, coalescing multiple inputs in that pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, let pending else { return }
            self.pending = nil
            view = pending
        }
    }
}

struct SidebarHostedRoot: View {
    @ObservedObject var source: SidebarHostSource
    let initial: AnyView
    var body: some View { source.view ?? initial }
}
