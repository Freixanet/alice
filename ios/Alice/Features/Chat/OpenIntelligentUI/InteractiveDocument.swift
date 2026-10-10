import Foundation

/// Controlled main document, opaque iframe. Generated strings are JSON-escaped; only the iframe receives markup.
enum InteractiveDocument {
    static func make(_ artifact: InteractiveArtifact, resourceRoot: URL? = nil, darkMode: Bool = false) throws -> String {
        func resource(_ name: String, _ ext: String) throws -> String {
            let url = resourceRoot?.appendingPathComponent(name + "." + ext)
                ?? Bundle.main.url(forResource: name, withExtension: ext)
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            return try String(contentsOf: url, encoding: .utf8)
        }
        func literal<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                .replacingOccurrences(of: "<", with: "\\u003c")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        let nonce = UUID().uuidString
        let host = try resource("openintelligentui-host", "js")
        let theme = try resource("openintelligentui", "css")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src about:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style nonce="\(nonce)">html,body{margin:0;background:transparent}iframe{border:0;width:100%;display:block}</style></head>
        <body><iframe id="widget" title="Interfaz interactiva" sandbox="allow-scripts" referrerpolicy="no-referrer"></iframe>
        <script nonce="\(nonce)">\(host)
        mountInteractiveArtifact(\(try literal(artifact)), \(try literal(theme)), \(try literal(UUID().uuidString)), \(darkMode));
        </script></body></html>
        """
    }
}
