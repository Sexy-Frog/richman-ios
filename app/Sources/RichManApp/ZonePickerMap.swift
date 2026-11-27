import SwiftUI
import MapLibre
import CoreLocation

/// Map used to pick a privacy-zone center. The crosshair stays at the map
/// center; panning updates the bound coordinate. Bumping `recenter` moves the
/// map to the bound coordinate (e.g. "use current location").
struct ZonePickerMap: UIViewRepresentable {
    @Binding var center: CLLocationCoordinate2D
    let styleURL: URL?
    var recenter: Int = 0

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.delegate = context.coordinator
        map.showsLogoView = false
        map.showsAttributionButton = false
        map.setCenter(center, zoomLevel: 16.0, animated: false)
        context.coordinator.lastRecenter = recenter
        context.coordinator.lastStyleURL = styleURL
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        // Tor may finish bootstrapping after this view was created. Without
        // this, an editor opened early stays on the empty style forever.
        if let styleURL, styleURL != context.coordinator.lastStyleURL {
            context.coordinator.lastStyleURL = styleURL
            map.styleURL = styleURL
        }
        guard recenter != context.coordinator.lastRecenter else { return }
        context.coordinator.lastRecenter = recenter
        map.setCenter(center, zoomLevel: map.zoomLevel, animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: ZonePickerMap
        var lastRecenter = 0
        var lastStyleURL: URL?

        init(_ parent: ZonePickerMap) {
            self.parent = parent
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            parent.center = mapView.centerCoordinate
        }
    }
}
