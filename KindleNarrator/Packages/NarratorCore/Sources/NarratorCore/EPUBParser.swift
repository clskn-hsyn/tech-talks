import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

public enum EPUBError: Error, LocalizedError, Equatable {
    case notAZipArchive
    case missingContainer
    case missingPackageDocument(String)
    case encrypted
    case noReadableText

    public var errorDescription: String? {
        switch self {
        case .notAZipArchive: return "This file isn't a valid EPUB."
        case .missingContainer, .missingPackageDocument: return "This EPUB is missing its table of contents data."
        case .encrypted: return "This book is protected by DRM. Download the DRM-free EPUB from Amazon's Manage Your Content and Devices page, if the publisher offers one."
        case .noReadableText: return "No readable text was found in this book."
        }
    }
}

/// Reads an EPUB 2 or 3 file into a `Book`.
public struct EPUBParser {
    public struct Metadata: Equatable, Sendable {
        public var title: String?
        public var author: String?
    }

    struct ManifestItem {
        var href: String
        var mediaType: String
        var properties: String
    }

    let archive: Archive

    public init(url: URL) throws {
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBError.notAZipArchive
        }
    }

    public init(data: Data) throws {
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw EPUBError.notAZipArchive
        }
    }

    public func parse(fallbackTitle: String) throws -> Book {
        if let encryption = try? readString("META-INF/encryption.xml"), Self.isDRMEncryption(encryption) {
            throw EPUBError.encrypted
        }
        guard let container = try? readXML("META-INF/container.xml") else { throw EPUBError.missingContainer }
        guard let packagePath = container.first("rootfile")?.attributes["full-path"] else {
            throw EPUBError.missingContainer
        }
        guard let package = try? readXML(packagePath) else { throw EPUBError.missingPackageDocument(packagePath) }
        let baseDirectory = (packagePath as NSString).deletingLastPathComponent

        let metadataNode = package.first("metadata")
        let metadata = Metadata(
            title: metadataNode?.first("title")?.text.trimmed.nilIfEmpty,
            author: metadataNode?.all("creator").map { $0.text.trimmed }.filter { !$0.isEmpty }.joined(separator: ", ").nilIfEmpty
        )

        var manifest: [String: ManifestItem] = [:]
        for item in package.first("manifest")?.all("item") ?? [] {
            guard let id = item.attributes["id"], let href = item.attributes["href"] else { continue }
            manifest[id] = ManifestItem(
                href: Self.resolve(href, relativeTo: baseDirectory),
                mediaType: item.attributes["media-type"] ?? "",
                properties: item.attributes["properties"] ?? ""
            )
        }

        let spineNode = package.first("spine")
        let spine: [ManifestItem] = (spineNode?.all("itemref") ?? []).compactMap { ref in
            guard ref.attributes["linear"] != "no", let id = ref.attributes["idref"] else { return nil }
            return manifest[id]
        }

        let tocTitles = readTableOfContents(manifest: manifest, ncxID: spineNode?.attributes["toc"])

        var chapters: [Chapter] = []
        for (index, item) in spine.enumerated() {
            guard item.mediaType.contains("html") || item.href.hasSuffix("html") || item.href.hasSuffix("htm"),
                  let html = try? readString(item.href) else { continue }
            let document = HTMLTextExtractor.extract(html)
            guard !document.paragraphs.isEmpty else { continue }
            let title = tocTitles[item.href] ?? document.firstHeading ?? "Section \(index + 1)"
            let auxiliary = BookBuilder.isAuxiliary(title: title, path: item.href)
            let chapter = BookBuilder.chapter(title: title, paragraphs: document.paragraphs, isAuxiliary: auxiliary)
            if !chapter.sentences.isEmpty { chapters.append(chapter) }
        }
        guard !chapters.isEmpty else { throw EPUBError.noReadableText }
        let cast = DialogueAnalyzer.analyze(&chapters)

        return Book(
            title: metadata.title ?? fallbackTitle,
            author: metadata.author,
            format: .epub,
            chapters: chapters,
            cast: cast
        )
    }

    /// The cover image bytes, if the package declares one.
    public func coverImageData() -> Data? {
        guard let container = try? readXML("META-INF/container.xml"),
              let packagePath = container.first("rootfile")?.attributes["full-path"],
              let package = try? readXML(packagePath) else { return nil }
        let base = (packagePath as NSString).deletingLastPathComponent
        let items = package.first("manifest")?.all("item") ?? []
        let coverID = package.first("metadata")?.all("meta")
            .first { $0.attributes["name"] == "cover" }?.attributes["content"]
        let cover = items.first { ($0.attributes["properties"] ?? "").contains("cover-image") }
            ?? items.first { $0.attributes["id"] == coverID }
            ?? items.first { ($0.attributes["id"] ?? "").lowercased().contains("cover") && ($0.attributes["media-type"] ?? "").hasPrefix("image/") }
        guard let href = cover?.attributes["href"] else { return nil }
        return try? readData(Self.resolve(href, relativeTo: base))
    }

    // MARK: - Table of contents

    /// Maps each content file path to its first title in the EPUB 3 nav document or EPUB 2 NCX.
    func readTableOfContents(manifest: [String: ManifestItem], ncxID: String?) -> [String: String] {
        var titles: [String: String] = [:]
        func record(_ href: String, _ title: String, base: String) {
            let path = Self.resolve(String(href.split(separator: "#", maxSplits: 1).first ?? ""), relativeTo: base)
            let clean = HTMLTextExtractor.collapseWhitespace(title)
            if titles[path] == nil, !clean.isEmpty { titles[path] = clean }
        }

        if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let html = try? readString(nav.href) {
            let base = (nav.href as NSString).deletingLastPathComponent
            for (href, title) in Self.anchors(in: Self.tocSection(of: html)) { record(href, title, base: base) }
        }
        let ncx = ncxID.flatMap { manifest[$0] } ?? manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }
        if titles.isEmpty, let ncx, let root = try? readXML(ncx.href) {
            let base = (ncx.href as NSString).deletingLastPathComponent
            for point in root.all("navPoint", recursive: true) {
                guard let src = point.first("content")?.attributes["src"],
                      let label = point.first("navLabel")?.first("text")?.text else { continue }
                record(src, label, base: base)
            }
        }
        return titles
    }

    /// The `<nav epub:type="toc">` part of a nav document, so page lists and landmarks are ignored.
    static func tocSection(of html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<nav[^>]*epub:type\s*=\s*["'][^"']*\btoc\b[^"']*["'][^>]*>([\s\S]*?)</nav>"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return html }
        return String(html[range])
    }

    static func anchors(in html: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: #"<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { return nil }
            let text = HTMLTextExtractor.extract(String(html[textRange])).paragraphs.joined(separator: " ")
            return (HTMLTextExtractor.decodeEntities(String(html[hrefRange])), text)
        }
    }

    // MARK: - Archive access

    func readData(_ path: String) throws -> Data {
        guard let entry = archive[path] ?? archive[path.removingPercentEncoding ?? path] else {
            throw EPUBError.missingPackageDocument(path)
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    func readString(_ path: String) throws -> String {
        let data = try readData(path)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func readXML(_ path: String) throws -> XMLElementNode {
        try XMLElementNode.parse(readData(path))
    }

    /// Adobe and Amazon DRM list encrypted content files here; font obfuscation alone is harmless.
    static func isDRMEncryption(_ xml: String) -> Bool {
        let fontObfuscation = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        guard xml.contains("EncryptedData") else { return false }
        let methods = xml.components(separatedBy: "Algorithm=\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        return methods.contains { !fontObfuscation.contains($0) }
    }

    /// Resolves an href from a package or nav document into an archive path.
    static func resolve(_ href: String, relativeTo base: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        var components: [Substring] = base.isEmpty || decoded.hasPrefix("/") ? [] : base.split(separator: "/")
        for part in decoded.split(separator: "/") {
            if part == ".." { _ = components.popLast() } else if part != "." { components.append(part) }
        }
        return components.joined(separator: "/")
    }
}

// MARK: - Minimal XML tree

/// Just enough DOM for container.xml, the OPF package and NCX files, which are always well-formed XML.
final class XMLElementNode {
    let name: String
    let attributes: [String: String]
    var children: [XMLElementNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func first(_ localName: String) -> XMLElementNode? {
        all(localName, recursive: true).first
    }

    func all(_ localName: String, recursive: Bool = false) -> [XMLElementNode] {
        var result: [XMLElementNode] = []
        for child in children {
            if child.name == localName { result.append(child) }
            if recursive { result.append(contentsOf: child.all(localName, recursive: true)) }
        }
        return result
    }

    static func parse(_ data: Data) throws -> XMLElementNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw parser.parserError ?? EPUBError.missingContainer
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLElementNode?
        var stack: [XMLElementNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            // Keep both "opf:role" and "role" so lookups don't care about prefixes.
            var attrs = attributes
            for (key, value) in attributes {
                if let local = key.split(separator: ":").last, local != Substring(key) { attrs[String(local)] = value }
            }
            let localName = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = XMLElementNode(name: localName, attributes: attrs)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
