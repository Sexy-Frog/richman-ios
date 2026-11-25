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
        map.setCenter(center, zoomLevel: 15.0, animated: false)
        context.coordinator.lastRecenter = recenter
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        guard recenter != context.coordinator.lastRecenter else { return }
        context.coordinator.lastRecenter = recenter
        map.setCenter(center, zoomLevel: map.zoomLevel, animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private let parent: ZonePickerMap
        var lastRecenter = 0

        init(_ parent: ZonePickerMap) {
            self.parent = parent
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            parent.center = mapView.centerCoordinate
        }
    }
}
