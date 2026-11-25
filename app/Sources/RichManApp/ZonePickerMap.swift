import SwiftUI
import MapLibre
import CoreLocation

/// Map used to pick a security-zone center. The crosshair stays at the map
/// center; panning updates the bound coordinate.
struct ZonePickerMap: UIViewRepresentable {
    @Binding var center: CLLocationCoordinate2D
    let styleURL: URL?

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.delegate = context.coordinator
        map.showsLogoView = false
        map.showsAttributionButton = false
        map.setCenter(center, zoomLevel: 15.0, animated: false)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private let parent: ZonePickerMap

        init(_ parent: ZonePickerMap) {
            self.parent = parent
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            parent.center = mapView.centerCoordinate
        }
    }
}
