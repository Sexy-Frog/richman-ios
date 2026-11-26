import Foundation

/// Style source for the privacy-zone map. Shared-location map screens are gone;
/// this is used only by the zone editor.
enum MapConfig {
    static var styleURL: URL? {
        #if DEBUG
        return Bundle.main.url(
            forResource: "map_style_direct", withExtension: "json"
        )
        #else
        return nil
        #endif
    }
}
