import Foundation

/// Builds a Japanese-label variant of the OpenFreeMap style at runtime.
/// DEBUG-only for now (the release build waits for the relay tile proxy).
enum MapStyleLoader {
    static func japaneseStyleFile() async -> URL? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("richman-style-ja.json")
        if FileManager.default.fileExists(atPath: file.path) {
            return file
        }

        guard let remote = URL(string: "https://tiles.openfreemap.org/styles/liberty") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: remote)
            guard var style = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let layers = style["layers"] as? [[String: Any]] else {
                return nil
            }

            var updated: [[String: Any]] = []
            for layer in layers {
                var layer = layer
                if var layout = layer["layout"] as? [String: Any],
                   let field = layout["text-field"],
                   containsLatin(field) {
                    layout["text-field"] = ["coalesce", ["get", "name:ja"], ["get", "name"]]
                    layer["layout"] = layout
                }
                updated.append(layer)
            }
            style["layers"] = updated

            let out = try JSONSerialization.data(withJSONObject: style)
            try out.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    private static func containsLatin(_ value: Any) -> Bool {
        if let string = value as? String {
            return string.contains("name:latin") || string.contains("name:nonlatin")
        }
        if let array = value as? [Any] {
            return array.contains { containsLatin($0) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { containsLatin($0) }
        }
        return false
    }
}
