import Foundation
import libxml2

/// Reads declarations from the document head without executing scripts or loading subresources.
struct BrowserPageMetadata {
    var title: String?
    var icons: [URL] = []

    init(html: Data, url: URL, encoding: String?) {
        let options = HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
        let document = html.withUnsafeBytes { bytes in
            htmlReadMemory(bytes.bindMemory(to: CChar.self).baseAddress, Int32(bytes.count), nil, encoding, Int32(options))
        }
        guard let document else { return }
        defer { xmlFreeDoc(document) }
        var head = xmlFirstElementChild(xmlDocGetRootElement(document))
        while let element = head, String(cString: element.pointee.name) != "head" { head = xmlNextElementSibling(element) }
        guard let head else { return }

        var base: String?
        var socialTitle: String?
        var siteName: String?
        var touchIcons: [String] = []
        var otherIcons: [String] = []
        var node = xmlFirstElementChild(head)
        while let element = node {
            node = xmlNextElementSibling(element)
            func attribute(_ key: String) -> String? {
                Self.text(startingAt: xmlHasProp(element, key)?.pointee.children)
            }
            switch String(cString: element.pointee.name) {
            case "title":
                title = title ?? BrowserPageRecord.pageTitle(Self.text(startingAt: element.pointee.children), for: url)
            case "meta":
                let key = (attribute("property") ?? attribute("name"))?.lowercased()
                if key == "og:title" { socialTitle = BrowserPageRecord.pageTitle(attribute("content"), for: url) }
                if key == "og:site_name" { siteName = BrowserPageRecord.pageTitle(attribute("content"), for: url) }
            case "base":
                if base == nil { base = attribute("href") }
            case "link":
                guard let href = attribute("href"), let rel = attribute("rel")?.lowercased().split(whereSeparator: \.isWhitespace) else { continue }
                if rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed") { touchIcons.append(href) }
                else if rel.contains("icon") { otherIcons.append(href) }
            default: break
            }
        }
        title = title ?? socialTitle ?? siteName
        let baseURL = base.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL } ?? url
        for href in touchIcons + otherIcons {
            guard let candidate = URL(string: href, relativeTo: baseURL)?.absoluteURL, let icon = BrowserPolicy.restorable(candidate),
                  !icons.contains(icon) else { continue }
            icons.append(icon)
            if icons.count == 3 { break }
        }
    }

    private static func text(startingAt child: xmlNodePtr?) -> String? {
        var node = child
        var text = ""
        while let part = node {
            if (part.pointee.type == XML_TEXT_NODE || part.pointee.type == XML_CDATA_SECTION_NODE), let content = part.pointee.content {
                text += String(cString: content)
            }
            node = part.pointee.next
        }
        return text.isEmpty ? nil : text
    }
}
