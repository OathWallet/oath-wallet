import Foundation
import OathArtworkSource

/// SwiftDraw requires both rect dimensions. SVG gives omitted dimensions a
/// zero used value. Apply those defaults only after the original document has
/// passed the safety validator and its first drawing parse has failed.
enum ArtworkRectangleDefaults {
    static func apply(to data: Data) -> Data? {
        let writer = Writer(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = writer
        guard parser.parse(), writer.changed else { return nil }
        return writer.output
    }

    private final class Writer: NSObject, XMLParserDelegate {
        var output = Data()
        var changed = false

        private func append(_ text: String, parser: XMLParser) {
            let bytes = Data(text.utf8)
            guard output.count + bytes.count <= ArtworkSource.byteLimit else {
                parser.abortParsing()
                return
            }
            output.append(bytes)
        }
        private func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "\r", with: "&#13;")
                .replacingOccurrences(of: "\n", with: "&#10;")
                .replacingOccurrences(of: "\t", with: "&#9;")
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            var attributes = attributes
            if name == "rect" {
                for dimension in ["width", "height"] {
                    if let value = attributes[dimension] {
                        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-") else {
                            parser.abortParsing()
                            return
                        }
                    } else {
                        attributes[dimension] = "0"
                        changed = true
                    }
                }
            }
            let fields = attributes.sorted { $0.key < $1.key }.map { key, value in
                " " + key + "=\"" + escaped(value) + "\""
            }.joined()
            append("<" + name + fields + ">", parser: parser)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            append("</" + name + ">", parser: parser)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            append(escaped(string), parser: parser)
        }
        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            guard let text = String(data: data, encoding: .utf8) else {
                parser.abortParsing()
                return
            }
            append(escaped(text), parser: parser)
        }
    }
}
