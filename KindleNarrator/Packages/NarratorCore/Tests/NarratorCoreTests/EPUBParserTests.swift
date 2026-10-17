import XCTest
import ZIPFoundation
@testable import NarratorCore

final class EPUBParserTests: XCTestCase {
    func testParsesEPUB3WithNavTitles() throws {
        let book = try EPUBParser(data: makeEPUB()).parse(fallbackTitle: "fallback")
        XCTAssertEqual(book.title, "The Test Book")
        XCTAssertEqual(book.author, "Ada Writer")
        XCTAssertEqual(book.chapters.map(\.title), ["Copyright", "The Beginning", "Chapter 2"])
        XCTAssertEqual(book.chapters[0].isAuxiliary, true)
        XCTAssertEqual(book.chapters[1].sentences, ["Chapter one", "Mister Smith arrived in nineteen ninety-nine.", "He stayed."])
        XCTAssertEqual(book.chapters[1].paragraphEnds, [0, 2])
        XCTAssertEqual(book.startPosition, BookPosition(chapter: 1, sentence: 0))
    }

    func testRejectsDRMProtectedBooks() throws {
        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <EncryptedData><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></EncryptedData>
        </encryption>
        """
        let data = try makeEPUB(extraFiles: ["META-INF/encryption.xml": encryption])
        XCTAssertThrowsError(try EPUBParser(data: data).parse(fallbackTitle: "x")) { error in
            XCTAssertEqual(error as? EPUBError, .encrypted)
        }
    }

    func testFontObfuscationIsNotDRM() {
        let xml = #"<EncryptedData><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/></EncryptedData>"#
        XCTAssertFalse(EPUBParser.isDRMEncryption(xml))
    }

    func testResolvesRelativePaths() {
        XCTAssertEqual(EPUBParser.resolve("../Text/ch%201.xhtml", relativeTo: "OEBPS/Nav"), "OEBPS/Text/ch 1.xhtml")
        XCTAssertEqual(EPUBParser.resolve("ch1.xhtml", relativeTo: ""), "ch1.xhtml")
    }

    func testRejectsNonZip() {
        XCTAssertThrowsError(try EPUBParser(data: Data("hello".utf8)).parse(fallbackTitle: "x"))
    }

    // MARK: - Fixture

    private func makeEPUB(extraFiles: [String: String] = [:]) throws -> Data {
        var files: [String: String] = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """,
            "OEBPS/content.opf": """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>The Test Book</dc:title>
                <dc:creator>Ada Writer</dc:creator>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="copy" href="Text/copyright.xhtml" media-type="application/xhtml+xml"/>
                <item id="c1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="c2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
                <item id="empty" href="Text/empty.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="copy"/><itemref idref="c1"/><itemref idref="empty"/><itemref idref="c2"/>
                <itemref idref="nav" linear="no"/>
              </spine>
            </package>
            """,
            "OEBPS/nav.xhtml": """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <nav epub:type="toc"><ol>
              <li><a href="Text/copyright.xhtml">Copyright</a></li>
              <li><a href="Text/ch1.xhtml#start">The <em>Beginning</em></a></li>
            </ol></nav>
            <nav epub:type="page-list"><ol><li><a href="Text/ch2.xhtml#p9">9</a></li></ol></nav>
            </body></html>
            """,
            "OEBPS/Text/copyright.xhtml": "<html><body><p>Copyright 2020. All rights reserved.</p></body></html>",
            "OEBPS/Text/ch1.xhtml": "<html><body><h2>Chapter one</h2><p>Mr. Smith arrived in 1999. He stayed.</p></body></html>",
            "OEBPS/Text/empty.xhtml": "<html><body><div><img src=\"x.png\"/></div></body></html>",
            "OEBPS/Text/ch2.xhtml": "<html><body><h1>Chapter 2</h1><p>The end.</p></body></html>",
        ]
        files.merge(extraFiles) { $1 }

        let archive = try Archive(data: Data(), accessMode: .create)
        for (path, contents) in files.sorted(by: { $0.key == "mimetype" || ($1.key != "mimetype" && $0.key < $1.key) }) {
            let data = Data(contents.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return try XCTUnwrap(archive.data)
    }
}
