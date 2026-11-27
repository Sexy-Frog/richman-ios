import SwiftUI
import CoreLocation

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
                styleURL: tor.mapStyleURL ?? MapConfig.styleURL,
                recenter: recenterToken
            )
            .ignoresSafeArea()

            Image(systemName: "plus")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(RM.primary)
                .shadow(color: .black.opacity(0.25), radius: 4)

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomCard
            }
        }
        .onAppear {
            prepareInitialCenter()
            MapProxy.shared.prefetch(
                latitude: center.latitude,
                longitude: center.longitude,
                zoom: 15
            )
        }
        .onChange(of: recenterToken) { _, _ in
            MapProxy.shared.prefetch(
                latitude: center.latitude,
                longitude: center.longitude,
                zoom: 15
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
            Slider(value: $radius, in: 100...1000, step: 50)
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

            Button { centerOnCurrentLocation() } label: {
                Label("現在地を中心にする", systemImage: "location.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RM.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RM.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Text("地図を動かして中心を合わせます。位置情報はゾーン判定にのみ使い、バックグラウンドでは取得しません。")
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
