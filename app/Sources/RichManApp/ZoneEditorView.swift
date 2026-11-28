import SwiftUI
import CoreLocation
import RichManCore

/// Full-screen privacy-zone editor. The map fills the screen, a crosshair
/// marks the centre, and a floating card carries radius/action/save. New
/// zones start at the current location as soon as CoreLocation delivers a fix.
struct ZoneEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tor: TorSession
    @EnvironmentObject private var location: LocationProvider

    @State private var center: CLLocationCoordinate2D
    @State private var radius: Double
    @State private var action: SecurityZone.Action
    @State private var recenterToken = 0
    @State private var showLocationPrimer = false
    @State private var waitingForInitialFix = false
    @State private var insideNow: Bool?
    @State private var query = ""
    @State private var results: [GeocodeResult] = []
    @State private var searching = false
    @State private var searchError: String?
    @FocusState private var searchFocused: Bool

    private let startsNew: Bool

    init(zone: SecurityZone?) {
        let base = zone ?? SecurityZone(
            latitude: 35.6812,
            longitude: 139.7671,
            radius: 300,
            action: .lock
        )
        startsNew = zone == nil
        _center = State(initialValue: base.center)
        _radius = State(initialValue: base.radius)
        _action = State(initialValue: base.action)
    }

    var body: some View {
        ZStack {
            ZonePickerMap(
                center: $center,
                radius: $radius,
                styleURL: tor.mapStyleURL ?? MapConfig.styleURL,
                recenter: recenterToken
            )
            .ignoresSafeArea()

            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(RM.primary)
                    .shadow(color: .black.opacity(0.25), radius: 4)
                Text("半径 \(Int(radius))m")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(RM.onSurface)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Text("© OpenStreetMap contributors")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 60)
                .padding(.leading, 12)

            VStack(spacing: 10) {
                topBar
                searchBar
                if !results.isEmpty {
                    resultsCard
                }
                if let searchError {
                    Text(searchError)
                        .font(.caption)
                        .foregroundStyle(RM.error)
                        .padding(.horizontal, 16)
                }
                Spacer()
                bottomCard
            }
        }
        .onAppear {
            prepareInitialCenter()
            MapProxy.shared.prefetch(
                latitude: center.latitude,
                longitude: center.longitude,
                zoom: 17
            )
        }
        .onChange(of: recenterToken) { _, _ in
            MapProxy.shared.prefetch(
                latitude: center.latitude,
                longitude: center.longitude,
                zoom: 17
            )
        }
        .onChange(of: tor.mapStyleURL) { _, _ in
            MapProxy.shared.prefetch(
                latitude: center.latitude,
                longitude: center.longitude,
                zoom: 17
            )
        }
        .onChange(of: location.location?.timestamp) { _, _ in
            guard waitingForInitialFix, let fix = location.location else { return }
            waitingForInitialFix = false
            center = fix.coordinate
            recenterToken += 1
        }
        .sheet(isPresented: $showLocationPrimer) {
            LocationPrimer().environmentObject(location)
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(RM.onSurface)
                    .frame(width: 38, height: 38)
                    .background(.regularMaterial, in: Circle())
            }
            Spacer()
            Text("プライバシーゾーン")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
            Spacer()
            Button("保存") { save() }
                .font(.headline)
                .foregroundStyle(RM.onPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(RM.primary, in: Capsule())
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RM.onSurfaceVariant)
            TextField("住所・駅名・施設名を検索", text: $query)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { search() }
            if searching {
                ProgressView().scaleEffect(0.75)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    searchError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(RM.onSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 16)
    }

    private var resultsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(results.prefix(4))) { result in
                Button { apply(result) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(RM.onSurface)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("この場所を中心にする")
                            .font(.caption2)
                            .foregroundStyle(RM.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                if result.id != results.prefix(4).last?.id {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .padding(.horizontal, 16)
    }

    private var bottomCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("半径")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(radius))m")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(RM.onSurfaceVariant)
            }
            Slider(value: $radius, in: 50...3000, step: 50)
                .tint(RM.primary)

            HStack {
                Text("入室時の動作")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("入室時の動作", selection: $action) {
                    ForEach(SecurityZone.Action.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(RM.primary)
            }

            Button { checkCurrentLocation() } label: {
                Label("現在地がこの範囲に入っているか確認", systemImage: "scope")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RM.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RM.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            if let insideNow {
                Label(
                    insideNow ? "現在地はこのゾーンの内側です" : "現在地はこのゾーンの外側です",
                    systemImage: insideNow ? "checkmark.circle.fill" : "circle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(insideNow ? RM.primary : RM.onSurfaceVariant)
            }

            Button { centerOnCurrentLocation() } label: {
                Label("現在地を中心にする", systemImage: "location.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RM.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RM.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Text("地図を動かすと円の中心が動きます。円の内側に入ると「\(action.label)」を実行します。位置情報は端末内の判定だけに使い、サーバーには送信しません。")
                .font(.caption2)
                .foregroundStyle(RM.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func prepareInitialCenter() {
        guard startsNew else { return }
        if let fix = location.location {
            center = fix.coordinate
            recenterToken += 1
            return
        }
        waitingForInitialFix = true
        if location.hasPermission {
            location.startIfAuthorized()
        } else if location.authorization == .notDetermined {
            location.requestPermission()
        }
    }

    private func centerOnCurrentLocation() {
        guard location.hasPermission else {
            showLocationPrimer = true
            return
        }
        if let fix = location.location {
            waitingForInitialFix = false
            center = fix.coordinate
            recenterToken += 1
        } else {
            waitingForInitialFix = true
            location.startIfAuthorized()
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchFocused = false
        searching = true
        searchError = nil
        Task {
            defer { searching = false }
            guard let transport = tor.readyTransport else {
                searchError = "ネットワークに接続できません"
                return
            }
            do {
                let client = RelayClient(transport: transport)
                let found = try await client.geocode(
                    query: text,
                    lat: center.latitude,
                    lon: center.longitude
                )
                results = Array(found.prefix(5))
                if results.isEmpty { searchError = "見つかりませんでした" }
            } catch {
                searchError = "検索できませんでした。時間をおいてお試しください。"
            }
        }
    }

    private func apply(_ result: GeocodeResult) {
        center = CLLocationCoordinate2D(
            latitude: result.lat, longitude: result.lon
        )
        recenterToken += 1
        results = []
        query = ""
        searchError = nil
        searchFocused = false
        MapProxy.shared.prefetch(
            latitude: result.lat, longitude: result.lon, zoom: 17
        )
    }

    private func checkCurrentLocation() {
        guard location.hasPermission else {
            showLocationPrimer = true
            return
        }
        guard let fix = location.location else {
            waitingForInitialFix = true
            location.startIfAuthorized()
            return
        }
        let zone = CLLocation(latitude: center.latitude, longitude: center.longitude)
        insideNow = fix.distance(from: zone) <= radius
    }

    private func save() {
        SecurityZoneStore.current = SecurityZone(
            latitude: center.latitude,
            longitude: center.longitude,
            radius: radius,
            action: action
        )
        dismiss()
    }
}
