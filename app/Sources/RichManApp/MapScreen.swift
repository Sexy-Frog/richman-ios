import SwiftUI
import MapLibre
import CoreLocation
import Foundation

// MARK: - Demo data (real sharing wiring lands with Tor + location services)

struct MapPerson: Identifiable, Hashable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let updated: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isFresh: Bool { Date().timeIntervalSince(updated) < 120 }
}

enum MapDemo {
    static let me = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)

    static var people: [MapPerson] {
        [
            MapPerson(
                id: "demo-alice", name: "アリス",
                latitude: 35.6580, longitude: 139.7016,
                updated: Date().addingTimeInterval(-25)
            ),
            MapPerson(
                id: "demo-bob", name: "ボブ",
                latitude: 35.6938, longitude: 139.7034,
                updated: Date().addingTimeInterval(-260)
            ),
        ]
    }
}

/// Remote style is DEBUG-only for now: shipping a direct CDN connection would
/// leak the user's IP, so release builds wait for the relay tile proxy.
enum MapConfig {
    static var styleURL: URL? {
        #if DEBUG
        // Bundled copy of the Android palette (name:ja) with OpenFreeMap's
        // public sources. Keeps the DEBUG/Simulator map visually identical to
        // the Tor-delivered style. Release still shows nothing until Tor is up.
        return Bundle.main.url(
            forResource: "map_style_direct", withExtension: "json"
        )
        #else
        return nil
        #endif
    }

    /// Screenshot/CI hook: `-rm.mapfocus <id>` opens the map focused on a friend.
    static var initialFocus: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "rm.mapfocus")
        #else
        return nil
        #endif
    }
}

// MARK: - Screen

struct MapHomeView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var tor: TorSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var actions = MapActions()
    @State private var selectedId: String?
    @State private var chatTarget: Contact?
    @State private var styleURL: URL? = MapConfig.styleURL

    init(initialFocus: String? = nil) {
        _selectedId = State(initialValue: initialFocus ?? MapConfig.initialFocus)
    }

    /// Real positions come from shared `loc` messages. The demo seed is only a
    /// fallback for DEBUG screenshot builds (and when nothing is shared yet).
    private var people: [MapPerson] {
        let shared = store.places.map { id, place in
            MapPerson(
                id: id,
                name: store.contact(id)?.name ?? "友だち",
                latitude: place.latitude,
                longitude: place.longitude,
                updated: place.updatedAt
            )
        }
        if !shared.isEmpty { return shared }
        return DemoData.enabled ? MapDemo.people : []
    }
    private var selected: MapPerson? { people.first { $0.id == selectedId } }
    private var me: CLLocationCoordinate2D {
        location.location?.coordinate ?? MapDemo.me
    }

    var body: some View {
        ZStack {
            MapContainer(
                people: people,
                me: me,
                hasUserLocation: location.location != nil,
                focusId: selectedId,
                onSelect: { selectedId = $0 },
                actions: actions,
                styleURL: styleURL
            )
            .ignoresSafeArea()

            if styleURL == nil && tor.mapStyleURL == nil {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                        .font(.system(size: 40))
                        .foregroundStyle(RM.onSurfaceVariant)
                    Text("地図はTor対応後に有効になります")
                        .font(.subheadline.weight(.semibold))
                    Text("タイル配信をリレー経由にする準備中です。")
                        .font(.caption)
                        .foregroundStyle(RM.onSurfaceVariant)
                }
                .padding(20)
                .background(RM.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if location.hasPermission {
                        pill {
                            HStack(spacing: 7) {
                                Circle().fill(Color(hex: 0x06C755)).frame(width: 8, height: 8)
                                Text("位置情報を共有中").font(.caption.weight(.semibold))
                            }
                        }
                    } else {
                        Button { location.requestPermission() } label: {
                            pill {
                                HStack(spacing: 6) {
                                    Image(systemName: "location.fill")
                                        .font(.caption2)
                                    Text("現在地を許可").font(.caption.weight(.semibold))
                                }
                            }
                        }
                    }
                    Spacer()
                    pill {
                        Text("共有中 \(people.count)人").font(.caption.weight(.semibold))
                    }
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(RM.onSurface)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("地図を閉じる")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer()

                HStack(alignment: .bottom) {
                    Text("\u{00A9} OpenFreeMap \u{00B7} \u{00A9} OpenMapTiles \u{00B7} \u{00A9} OpenStreetMap")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(hex: 0x3A3A3A))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                    Spacer()
                    VStack(spacing: 8) {
                        mapButton("plus") { actions.zoomIn() }
                        mapButton("minus") { actions.zoomOut() }
                        mapButton("location") {
                            actions.center(me, zoom: 15.5)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                if let person = selected {
                    selectedCard(person)
                } else {
                    friendStrip
                }
            }
        }
        .sheet(item: $chatTarget) { contact in
            NavigationStack { ChatView(contact: contact) }
                .environmentObject(store)
                .environmentObject(location)
                .environmentObject(tor)
        }
        .task {
            if let proxied = tor.mapStyleURL {
                styleURL = proxied
            }
        }
        .onChange(of: tor.mapStyleURL) { _, newValue in
            if let newValue { styleURL = newValue }
        }
    }

    // MARK: overlays

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RM.surface.opacity(0.94), in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    private func mapButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: 0x1F2937))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.95), in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
    }

    private var friendStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(people) { person in
                    Button { selectedId = person.id } label: {
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottomTrailing) {
                                Avatar(name: person.name)
                                    .frame(width: 46, height: 46)
                                Circle()
                                    .fill(person.isFresh ? Color(hex: 0x06C755) : Color(hex: 0x9AA3AE))
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(RM.surface, lineWidth: 2))
                            }
                            Text(person.name).font(.caption2).foregroundStyle(RM.onSurface)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(RM.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func selectedCard(_ person: MapPerson) -> some View {
        HStack(spacing: 12) {
            Avatar(name: person.name)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.headline)
                Text("最終更新 \(person.updated.formatted(date: .omitted, time: .shortened))" + distanceLabel(person))
                    .font(.caption2)
                    .foregroundStyle(RM.onSurfaceVariant)
            }
            Spacer()
            Button {
                if let contact = store.contact(person.id) { chatTarget = contact }
            } label: {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 17))
                    .frame(width: 38, height: 38)
                    .background(RM.surfaceVariant, in: Circle())
            }
            Button { selectedId = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(RM.surfaceVariant, in: Circle())
            }
        }
        .padding(12)
        .background(RM.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func distanceLabel(_ person: MapPerson) -> String {
        let from = CLLocation(latitude: me.latitude, longitude: me.longitude)
        let to = CLLocation(latitude: person.latitude, longitude: person.longitude)
        let meters = from.distance(from: to)
        if meters >= 1000 {
            return String(format: " ・ 約%.1fkm", meters / 1000)
        }
        return " ・ 約\(Int(meters))m"
    }
}

// MARK: - Map actions bridge

final class MapActions: ObservableObject {
    weak var map: MLNMapView?

    func zoomIn() {
        guard let map else { return }
        map.setZoomLevel(map.zoomLevel + 1, animated: true)
    }

    func zoomOut() {
        guard let map else { return }
        map.setZoomLevel(map.zoomLevel - 1, animated: true)
    }

    func center(_ coordinate: CLLocationCoordinate2D, zoom: Double) {
        map?.setCenter(coordinate, zoomLevel: zoom, animated: true)
    }
}

// MARK: - UIViewRepresentable

struct MapContainer: UIViewRepresentable {
    let people: [MapPerson]
    let me: CLLocationCoordinate2D
    let hasUserLocation: Bool
    let focusId: String?
    let onSelect: (String) -> Void
    let actions: MapActions
    let styleURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.delegate = context.coordinator
        map.showsLogoView = false
        map.showsAttributionButton = false
        let focus = people.first { $0.id == focusId }
        map.setCenter(
            focus?.coordinate ?? me,
            zoomLevel: focus == nil ? 14.5 : 15.5,
            animated: false
        )
        let annotations = makeAnnotations()
        map.addAnnotations(annotations)
        context.coordinator.meAnnotation = annotations
            .compactMap { $0 as? MLNPointAnnotation }
            .first { $0.subtitle == "__me__" }
        context.coordinator.lastMe = me
        actions.map = map
        context.coordinator.lastFocus = focusId
        context.coordinator.lastStyleURL = styleURL
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        actions.map = map
        if styleURL != context.coordinator.lastStyleURL {
            context.coordinator.lastStyleURL = styleURL
            map.styleURL = styleURL
        }

        let previous = context.coordinator.lastMe
        if previous == nil ||
            previous!.latitude != me.latitude ||
            previous!.longitude != me.longitude {
            context.coordinator.meAnnotation?.coordinate = me
            context.coordinator.lastMe = me
        }

        if hasUserLocation, !context.coordinator.centeredOnUser, focusId == nil {
            context.coordinator.centeredOnUser = true
            map.setCenter(me, zoomLevel: 15.5, animated: true)
        }

        if let focusId, focusId != context.coordinator.lastFocus,
           let person = people.first(where: { $0.id == focusId }) {
            context.coordinator.lastFocus = focusId
            map.setCenter(person.coordinate, zoomLevel: 15.5, animated: true)
        }
    }

    private func makeAnnotations() -> [MLNAnnotation] {
        var result: [MLNAnnotation] = []
        let mine = MLNPointAnnotation()
        mine.coordinate = me
        mine.title = "現在地"
        mine.subtitle = "__me__"
        result.append(mine)

        for person in people {
            let point = MLNPointAnnotation()
            point.coordinate = person.coordinate
            point.title = person.name
            point.subtitle = person.id
            result.append(point)
        }
        return result
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: MapContainer
        var lastFocus: String?
        var lastStyleURL: URL?
        var meAnnotation: MLNPointAnnotation?
        var lastMe: CLLocationCoordinate2D?
        var centeredOnUser = false

        init(_ parent: MapContainer) {
            self.parent = parent
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let point = annotation as? MLNPointAnnotation else { return nil }
            let isMe = point.subtitle == "__me__"
            let identifier = isMe ? "me" : "friend"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MapAnnotationView
                ?? MapAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            if isMe {
                view.configureMe()
            } else {
                view.configureFriend(
                    name: point.title ?? "",
                    seed: point.subtitle ?? point.title ?? "?"
                )
            }
            return view
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let point = annotation as? MLNPointAnnotation,
                  let id = point.subtitle, id != "__me__" else { return }
            parent.onSelect(id)
        }
    }
}

// MARK: - Annotation view

final class MapAnnotationView: MLNAnnotationView {
    private let avatar = UILabel()
    private let namePill = UILabel()

    override init(annotation: MLNAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clipsToBounds = false

        avatar.textAlignment = .center
        avatar.textColor = .white
        avatar.font = .boldSystemFont(ofSize: 15)
        avatar.layer.masksToBounds = true
        avatar.layer.borderColor = UIColor.white.cgColor
        avatar.layer.borderWidth = 2
        addSubview(avatar)

        namePill.textAlignment = .center
        namePill.font = .boldSystemFont(ofSize: 10)
        namePill.textColor = UIColor(hex: 0x263238)
        namePill.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        namePill.layer.cornerRadius = 8
        namePill.layer.masksToBounds = true
        addSubview(namePill)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configureMe() {
        frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        centerOffset = CGVector(dx: 0, dy: 0)
        avatar.text = ""
        avatar.backgroundColor = UIColor(hex: 0x1A73E8)
        avatar.frame = CGRect(x: 9, y: 9, width: 16, height: 16)
        avatar.layer.cornerRadius = 8
        avatar.layer.borderWidth = 3
        namePill.isHidden = true
    }

    func configureFriend(name: String, seed: String) {
        frame = CGRect(x: 0, y: 0, width: 110, height: 62)
        centerOffset = CGVector(dx: 0, dy: -31)
        avatar.frame = CGRect(x: 37, y: 0, width: 36, height: 36)
        avatar.layer.cornerRadius = 18
        avatar.layer.borderWidth = 2
        avatar.text = String(name.prefix(1))
        avatar.backgroundColor = Self.color(seed)
        namePill.isHidden = false
        namePill.text = name
        namePill.frame = CGRect(x: 5, y: 40, width: 100, height: 18)
    }

    private static func color(_ seed: String) -> UIColor {
        let palette: [UInt32] = [0x06C755, 0x2E86DE, 0xE67E22, 0x8E44AD, 0x16A085, 0xD35400]
        var hash = 0
        for scalar in seed.unicodeScalars {
            hash = hash &* 31 &+ Int(scalar.value)
        }
        return UIColor(hex: palette[abs(hash) % palette.count])
    }
}
