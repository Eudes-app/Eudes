// personal-data: allow-file — les tests de la politique d'adresses énumèrent des plages
// privées et réservées pour vérifier qu'elles sont refusées.
import XCTest
import Network
@testable import Eudes

final class WebPageReaderTests: XCTestCase {
    func testOnlyPublicAddressesCanBecomeSocketEndpoints() throws {
        for address in ["1.1.1.1", "8.8.8.8", "93.184.215.14", "172.15.1.1", "172.32.1.1"] {
            guard case .ipv4 = try WebPageAddressPolicy.endpoint(address) else { return XCTFail(address) }
        }
        for address in ["2606:4700:4700::1111", "2001:4860:4860::8888", "2a00:1450::1"] {
            guard case .ipv6 = try WebPageAddressPolicy.endpoint(address) else { return XCTFail(address) }
        }
    }

    func testRejectsPrivateReservedAndTranslatedDestinations() {
        let blocked = [
            "0.0.0.0", "0.1.2.3", "10.0.0.1", "100.64.0.1", "100.127.255.254", "127.0.0.1",
            "169.254.169.254", "172.16.0.1", "172.31.255.254", "192.0.0.9", "192.0.2.1", "192.168.1.1",
            "192.88.99.1", "198.18.0.1", "198.19.1.1", "198.51.100.1", "203.0.113.1",
            "224.0.0.1", "239.255.255.250", "240.0.0.1", "255.255.255.255",
            "::", "::1", "::ffff:127.0.0.1", "::ffff:8.8.8.8", "::192.168.1.1", "fc00::1", "fd12::1",
            "fe80::1", "fe80::1%en0", "ff02::1", "64:ff9b::a00:1", "64:ff9b::808:808", "64:ff9b:1::1",
            "2001::1", "2001:2::1", "2001:db8::1", "2002:7f00:1::", "3ffe::1", "3fff::1", "localhost", "example.com"
        ]
        for address in blocked {
            XCTAssertThrowsError(try WebPageAddressPolicy.endpoint(address), address) {
                XCTAssertEqual($0 as? WebPageError, .unsafeAddress, address)
            }
        }
    }

    func testMixedPublicAndPrivateDNSAnswersFailClosed() throws {
        XCTAssertEqual(try WebPageAddressPolicy.validatedEndpoints(["1.1.1.1", "2606:4700:4700::1111"]).count, 2)
        XCTAssertThrowsError(try WebPageAddressPolicy.validatedEndpoints(["1.1.1.1", "10.0.0.1"]))
        XCTAssertThrowsError(try WebPageAddressPolicy.validatedEndpoints([]))
        XCTAssertThrowsError(try WebPageAddressPolicy.validatedEndpoints(Array(repeating: "1.1.1.1", count: 65)))
    }

    func testPageRequestContainsOnlySourceURLAndFixedHeaders() throws {
        let built = try WebPageHTTP.request(url: XCTUnwrap(URL(string: "https://example.com/article?q=caf%C3%A9#section")))
        XCTAssertEqual(built.hostname, "example.com")
        let wire = try XCTUnwrap(String(data: built.bytes, encoding: .utf8))
        XCTAssertTrue(wire.hasPrefix("GET /article?q=caf%C3%A9 HTTP/1.1\r\nHost: example.com\r\n"))
        XCTAssertTrue(wire.contains("Accept-Encoding: identity\r\n"))
        XCTAssertTrue(wire.contains("Connection: close\r\n"))
        XCTAssertFalse(wire.contains("#section"))
        XCTAssertFalse(wire.lowercased().contains("cookie:"))
        XCTAssertFalse(wire.lowercased().contains("authorization:"))
        XCTAssertFalse(wire.lowercased().contains("referer:"))
    }

    func testPageRequestRejectsUntrustedURLShapes() throws {
        for raw in ["http://example.com/", "https://example.com:444/", "https://user:secret@example.com/", "https://localhost/",
                    "https://printer.local/", "https://127.0.0.1/", "https://[::1]/", "https://10.0.0.1/", "file:///etc/hosts"] {
            XCTAssertThrowsError(try WebPageHTTP.request(url: XCTUnwrap(URL(string: raw))), raw) {
                XCTAssertEqual($0 as? WebPageError, .unsafeAddress)
            }
        }
    }

    func testReadsFixedLengthAndChunkedHTTPText() throws {
        let fixed = try WebPageHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nHello".utf8))
        XCTAssertEqual(String(data: fixed.body, encoding: .utf8), "Hello")
        let chunked = try WebPageHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nHe\r\n3;fixture=yes\r\nllo\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(chunked.body, fixed.body)
        let withTrailers = try WebPageHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n0\r\nDigest: ignored\r\n\r\n".utf8))
        XCTAssertEqual(withTrailers.body, fixed.body)
    }

    func testRedirectsAreNotFollowedAndCompressedContentIsRejected() {
        XCTAssertThrowsError(try WebPageHTTP.parse(Data("HTTP/1.1 302 Found\r\nLocation: https://internal.example/\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? WebPageError, .redirectNotAllowed)
        }
        XCTAssertThrowsError(try WebPageHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Encoding: gzip\r\n\r\ncompressed".utf8))) {
            XCTAssertEqual($0 as? WebPageError, .unsupportedContent)
        }
        XCTAssertThrowsError(try WebPageHTTP.parse(Data("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? WebPageError, .httpStatus(403))
        }
    }

    func testRejectsAmbiguousTruncatedAndMalformedHTTPBodies() {
        for wire in [
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nHi",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nHi",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\nHi",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHi\r\n0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nHi\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n Transfer-Encoding: chunked\r\n\r\nHi"
        ] {
            XCTAssertThrowsError(try WebPageHTTP.parse(Data(wire.utf8))) { XCTAssertEqual($0 as? WebPageError, .invalidResponse) }
        }
    }

    func testAcceptsBodiesOfAnySize() throws {
        let body = Data(repeating: 65, count: 2 * 1_048_576)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\n\r\n"
        let response = try WebPageHTTP.parse(Data(header.utf8) + body)
        XCTAssertEqual(response.body, body)
        XCTAssertEqual(response.contentType, "text/plain")
    }

    func testHTMLExtractionPrefersArticleAndRemovesNonContent() throws {
        let html = """
        <html><head><title>Ignored</title></head><body><nav>Menu</nav>
        <main><h1>Climat &amp; météo</h1><p>Température : 21&nbsp;°C.</p>
        <script>sendSecrets()</script><style>hidden</style><form>Enter password</form>
        <!-- hidden comment --><p>D&eacute;tails &#233;tablis.</p></main>
        <footer>Navigation</footer><p>Outside the article</p></body></html>
        """
        let text = try DirectWebPageReader.extract(WebPageResponse(body: Data(html.utf8), contentType: "text/html; charset=UTF-8"))
        XCTAssertEqual(text, "Climat & météo Température : 21 °C. Détails établis.")
    }

    func testTextExtractionDoesNotTreatTextAsHTMLAndKeepsFullText() throws {
        let plain = "A < B &amp; C.\n\n" + String(repeating: "x", count: 7_000)
        let result = try DirectWebPageReader.extract(WebPageResponse(body: Data(plain.utf8), contentType: "text/plain"))
        XCTAssertEqual(result, "A < B &amp; C. " + String(repeating: "x", count: 7_000))
        XCTAssertThrowsError(try DirectWebPageReader.extract(WebPageResponse(body: Data("<script>hidden</script>".utf8), contentType: "text/html"))) {
            XCTAssertEqual($0 as? WebPageError, .emptyPage)
        }
        XCTAssertThrowsError(try DirectWebPageReader.extract(WebPageResponse(body: Data("%PDF".utf8), contentType: "application/pdf"))) {
            XCTAssertEqual($0 as? WebPageError, .unsupportedContent)
        }
        XCTAssertThrowsError(try DirectWebPageReader.extract(WebPageResponse(body: Data([0]), contentType: "text/plain"))) {
            XCTAssertEqual($0 as? WebPageError, .unsupportedContent)
        }
    }

    func testReadPreservesCitationIdentityAndMarksPage() async throws {
        let source = WebSource(url: try XCTUnwrap(URL(string: "https://example.com/article")), title: "Original title", excerpt: "Search snippet", kind: .searchSnippet)
        let transport = PageFixtureTransport(response: WebPageResponse(body: Data("<article>Verified page text</article>".utf8), contentType: "text/html"))
        let result = try await DirectWebPageReader(transport: transport).read(source: source)
        XCTAssertEqual(result.url, source.url)
        XCTAssertEqual(result.title, source.title)
        XCTAssertEqual(result.excerpt, "Verified page text")
        XCTAssertEqual(result.kind, .page)
    }

    func testReadDoesNotExposeTransportDetailsAndPreservesCancellation() async throws {
        let source = WebSource(url: try XCTUnwrap(URL(string: "https://example.com/article")), title: "Source", excerpt: "Snippet", kind: .searchSnippet)
        do {
            _ = try await DirectWebPageReader(transport: PageFixtureTransport(error: .notConnectedToInternet)).read(source: source)
            XCTFail("Expected error")
        } catch { XCTAssertEqual(error as? WebPageError, .unavailable) }
        do {
            _ = try await DirectWebPageReader(transport: PageFixtureTransport(error: .cancelled)).read(source: source)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private struct PageFixtureTransport: WebPageTransport {
    var response = WebPageResponse(body: Data(), contentType: "text/plain")
    var error: URLError.Code?
    func fetch(url: URL) async throws -> WebPageResponse {
        if let error { throw URLError(error, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://example.com/private-user-query")!]) }
        return response
    }
}
