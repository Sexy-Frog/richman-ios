import SwiftUI
import CoreLocation

/// Map-based security-zone editor (Settings). Mirrors the Android zone dialog:
/// drag the map under the crosshair, choose a radius and an action.
struct ZoneEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tor: TorSession

    @State private var center: CLLocationCoordinate2D
    @State private var radius: Double
    @State private var action: SecurityZone.Action

    init(zone: SecurityZone?) {
        let base = zone ?? SecurityZone(
            latitude: 35.6812,
            longitude: 139.7671,
            radius: 300,
            action: .lock
        )
        _center = State(initialValue: base.center)
        _radius = State(initialValue: base.radius)
        _action = State(initialValue: base.action)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack {
                        ZonePickerMap(
                            center: $center,
                            styleURL: tor.mapStyleURL ?? MapConfig.styleURL
                        )
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        Image(systemName: "plus")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(RM.primary)
                    }
                } footer: {
                    Text("地図を動かして中心を合わせます。")
                }

                Section("半径") {
                    Slider(value: $radius, in: 100...1000, step: 50)
                    LabeledContent("半径", value: "\(Int(radius))m")
                }

                Section("入室時の動作") {
                    Picker("動作", selection: $action) {
                        ForEach(SecurityZone.Action.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                }
            }
            .navigationTitle("セキュリティゾーン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        SecurityZoneStore.current = SecurityZone(
                            latitude: center.latitude,
                            longitude: center.longitude,
                            radius: radius,
                            action: action
                        )
                        dismiss()
                    }
                }
            }
        }
    }
}
