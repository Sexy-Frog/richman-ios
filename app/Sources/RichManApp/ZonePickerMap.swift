import SwiftUI
import MapLibre
import CoreLocation
import UIKit

/// Map used to pick a privacy-zone center. The crosshair stays at the map
/// center; panning updates the bound coordinate. A geodesic circle is drawn as
/// a vector fill/line layer so the map stays visible through it.
struct ZonePickerMap: UIViewRepresentable {
    @Binding var center: CLLocationCoordinate2D
    @Binding var radius: Double
    let styleURL: URL?
    var recenter: Int = 0

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.delegate = context.coordinator
        map.showsLogoView = false
        map.showsAttributionButton = false
        map.backgroundColor = .systemBackground
        map.tintColor = .systemBlue
        map.maximumZoomLevel = 18
        map.setCenter(center, zoomLevel: 16.0, animated: false)
        context.coordinator.lastRecenter = recenter
        context.coordinator.lastStyleURL = styleURL
        context.coordinator.lastRadius = radius
        context.coordinator.installCircle(
            on: map, center: center, radius: radius
        )
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        if let styleURL, styleURL != context.coordinator.lastStyleURL {
            context.coordinator.lastStyleURL = styleURL
            map.styleURL = styleURL
            context.coordinator.circleSource = nil
        }
        if radius != context.coordinator.lastRadius {
            context.coordinator.lastRadius = radius
            context.coordinator.installCircle(
                on: map, center: map.centerCoordinate, radius: radius
            )
        }
        guard recenter != context.coordinator.lastRecenter else { return }
        context.coordinator.lastRecenter = recenter
        map.setCenter(center, zoomLevel: map.zoomLevel, animated: true)
        context.coordinator.installCircle(
            on: map, center: center, radius: radius
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: ZonePickerMap
        var lastRecenter = 0
        var lastStyleURL: URL?
        var lastRadius: Double = 0
        var circleSource: MLNShapeSource?

        init(_ parent: ZonePickerMap) {
            self.parent = parent
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            parent.center = mapView.centerCoordinate
            installCircle(
                on: mapView,
                center: mapView.centerCoordinate,
                radius: parent.radius
            )
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            circleSource = nil
            installCircle(
                on: mapView,
                center: mapView.centerCoordinate,
                radius: parent.radius
            )
        }

        func installCircle(
            on mapView: MLNMapView,
            center: CLLocationCoordinate2D,
            radius: Double
        ) {
            guard let style = mapView.style else { return }
            var coordinates = Self.circle(
                center: center, radius: max(10, radius)
            )
            let polygon = coordinates.withUnsafeMutableBufferPointer { buffer in
                MLNPolygon(
                    coordinates: buffer.baseAddress!,
                    count: UInt(buffer.count)
                )
            }
            if let source = circleSource {
                source.shape = polygon
                return
            }
            let source = MLNShapeSource(
                identifier: "rm-zone-circle",
                shape: polygon,
                options: nil
            )
            circleSource = source
            style.addSource(source)

            let fill = MLNFillStyleLayer(
                identifier: "rm-zone-fill", source: source
            )
            fill.fillColor = NSExpression(
                forConstantValue: UIColor.systemBlue.withAlphaComponent(0.14)
            )
            fill.fillOpacity = NSExpression(forConstantValue: 1.0)
            style.addLayer(fill)

            let line = MLNLineStyleLayer(
                identifier: "rm-zone-line", source: source
            )
            line.lineColor = NSExpression(
                forConstantValue: UIColor.systemBlue.withAlphaComponent(0.92)
            )
            line.lineWidth = NSExpression(forConstantValue: 2.0)
            style.addLayer(line)
        }

        private static func circle(
            center: CLLocationCoordinate2D,
            radius: Double
        ) -> [CLLocationCoordinate2D] {
            let points = 128
            let earth = 6_371_000.0
            let lat = center.latitude * .pi / 180
            var out = [CLLocationCoordinate2D]()
            out.reserveCapacity(points + 1)
            for i in 0...points {
                let bearing = Double(i) / Double(points) * 2 * .pi
                let angular = radius / earth
                let lat2 = asin(
                    sin(lat) * cos(angular)
                        + cos(lat) * sin(angular) * cos(bearing)
                )
                let lon2 = center.longitude * .pi / 180 + atan2(
                    sin(bearing) * sin(angular) * cos(lat),
                    cos(angular) - sin(lat) * sin(lat2)
                )
                out.append(
                    CLLocationCoordinate2D(
                        latitude: lat2 * 180 / .pi,
                        longitude: lon2 * 180 / .pi
                    )
                )
            }
            return out
        }
    }
}
