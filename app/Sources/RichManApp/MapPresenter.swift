import SwiftUI

/// The map is no longer a tab. It is presented on demand — from `/locate`
/// answers, a shared-location bubble, or the chat/settings menu — like the
/// Android client.
struct MapRoute: Identifiable, Equatable {
    let id = UUID()
    var focusPeer: String?
}

@MainActor
final class MapPresenter: ObservableObject {
    @Published var route: MapRoute?

    func show(focusPeer: String? = nil) {
        route = MapRoute(focusPeer: focusPeer)
    }

    func dismiss() {
        route = nil
    }
}
