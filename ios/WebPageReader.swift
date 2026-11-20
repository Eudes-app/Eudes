import Foundation
import Network
import Security
import Darwin

protocol WebPageReading: Sendable {
    func read(source: WebSource) async throws -> WebSource
}

enum WebPageError: LocalizedError, Equatable {
    case unsafeAddress, unavailable, timedOut, redirectNotAllowed, unsupportedContent, invalidResponse, responseTooLarge, emptyPage
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unsafeAddress: "Cette page ne peut pas être consultée directement en sécurité."
        case .unavailable: "La page Web n’est pas accessible."
        case .timedOut: "La lecture de la page Web a pris trop de temps."
        case .redirectNotAllowed: "Cette page redirige vers une autre adresse. Seul son extrait de recherche est disponible."
        case .unsupportedContent: "Le format de cette page ne permet pas une lecture directe."
        case .invalidResponse: "La réponse de cette page n’est pas exploitable."
        case .responseTooLarge: "Cette page dépasse la taille autorisée pour une lecture directe."
        case .emptyPage: "Aucun texte exploitable n’a été trouvé dans cette page."
        case .httpStatus(let status): "La page Web est indisponible (HTTP \(status))."
        }
    }
}

struct WebPageResponse: Sendable {
    let body: Data
    let contentType: String
}

protocol WebPageTransport: Sendable {
    func fetch(url: URL) async throws -> WebPageResponse
}

/// Reads only a source selected from the current turn's search results. The caller
/// owns that allowlist; the transport additionally pins a vetted public IP address.
struct DirectWebPageReader: WebPageReading {
    static let maximumCharacters = 6_000
    var transport: any WebPageTransport = PinnedWebPageTransport()

    func read(source: WebSource) async throws -> WebSource {
        try Task.checkCancellation()
        guard let url = WebSearchClient.publicHTTPSURL(source.url) else {
            let error = WebPageError.unsafeAddress
            DiagnosticLog.record(error, context: "page refusée")
            throw error
        }
        do {
            let response = try await transport.fetch(url: url)
            try Task.checkCancellation()
            let text = try Self.extract(response)
            // Keep the original URL, title and position so existing citations remain stable.
            return WebSource(url: source.url, title: source.title, excerpt: text, kind: .page)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // The page address is private: `describe` keeps the app-defined case only.
            DiagnosticLog.record(error, context: "lecture de page échouée")
            if let error = error as? WebPageError { throw error }
            throw WebPageError.unavailable
        }
    }

    static func extract(_ response: WebPageResponse) throws -> String {
        guard response.body.count <= WebPageHTTP.maximumBodyBytes else { throw WebPageError.responseTooLarge }
        let parts = response.contentType.lowercased().split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let mime = parts.first,
              ["text/html", "application/xhtml+xml", "text/plain", "text/markdown"].contains(mime) else {
            throw WebPageError.unsupportedContent
        }
        let charset = parts.dropFirst().first(where: { $0.hasPrefix("charset=") })?
            .dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let encoding: String.Encoding
        switch charset {
        case nil, "utf-8", "utf8", "us-ascii": encoding = .utf8
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252": encoding = .windowsCP1252
        default: throw WebPageError.unsupportedContent
        }
        guard var text = String(data: response.body, encoding: encoding),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw WebPageError.unsupportedContent }
        if mime == "text/html" || mime == "application/xhtml+xml" {
            text = replace(#"(?is)<!--.*?(?:-->|$)"#, in: text, with: " ")
            text = replace(#"(?is)<(script|style|noscript|template|iframe|svg|head|nav|footer|header|aside|form|button|select)\b[^>]*>.*?(?:</\1\s*>|$)"#, in: text, with: " ")
            // Prefer the main article when a document exposes one; otherwise read body text.
            if let main = contents(of: "main", in: text) ?? contents(of: "article", in: text) ?? contents(of: "body", in: text) {
                text = main
            }
            text = replace(#"(?is)<[^>]+>"#, in: text, with: " ")
            text = WebSearchClient.decodeEntities(text)
        }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { throw WebPageError.emptyPage }
        return String(text.prefix(maximumCharacters))
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func contents(of tag: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: "<" + tag + #"\b[^>]*>(.*?)</"# + tag + #"\s*>"#,
                                                        options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            .max(by: { $0.count < $1.count })
    }
}

/// Conservative address policy: reject special-use IPv4 ranges, and allow only
/// ordinary IPv6 global unicast. IPv4-mapped, NAT64, 6to4 and Teredo are rejected
/// rather than trusting a second, implicit address translation.
enum WebPageAddressPolicy {
    static func endpoint(_ address: String) throws -> NWEndpoint.Host {
        guard !address.contains("%") else { throw WebPageError.unsafeAddress }
        if let ipv4 = IPv4Address(address) {
            let bytes = Array(ipv4.rawValue)
            guard isPublicIPv4(bytes) else { throw WebPageError.unsafeAddress }
            return .ipv4(ipv4)
        }
        if let ipv6 = IPv6Address(address) {
            let bytes = Array(ipv6.rawValue)
            guard bytes.count == 16, (bytes[0] & 0xe0) == 0x20,
                  !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 0x02), // 2001::/23 special use
                  !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8),
                  !(bytes[0] == 0x20 && bytes[1] == 0x02), // 6to4 embeds another destination
                  !(bytes[0] == 0x3f && bytes[1] == 0xfe), // Former 6bone testing prefix
                  !(bytes[0] == 0x3f && bytes[1] == 0xff && (bytes[2] & 0xf0) == 0x00) else {
                throw WebPageError.unsafeAddress
            }
            return .ipv6(ipv6)
        }
        throw WebPageError.unsafeAddress
    }

    static func validatedEndpoints(_ addresses: [String]) throws -> [NWEndpoint.Host] {
        guard !addresses.isEmpty, addresses.count <= 64 else { throw WebPageError.unsafeAddress }
        // Validate EVERY result, not only the address chosen for this connection.
        return try addresses.map(endpoint)
    }

    private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 { return false }
        if b[0] == 100 && (64...127).contains(b[1]) { return false }
        if b[0] == 169 && b[1] == 254 { return false }
        if b[0] == 172 && (16...31).contains(b[1]) { return false }
        if b[0] == 192 {
            if b[1] == 168 { return false }
            if b[1] == 0 && (b[2] == 0 || b[2] == 2) { return false }
            if b[1] == 88 && b[2] == 99 { return false }
            if (b[1] == 31 && b[2] == 196) || (b[1] == 52 && b[2] == 193) || (b[1] == 175 && b[2] == 48) { return false }
        }
        if b[0] == 198 && (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100)) { return false }
        if b[0] == 203 && b[1] == 0 && b[2] == 113 { return false }
        return true
    }
}

/// A bounded HTTP/1 reader. No redirects, automatic decompression, cookies,
/// authentication, browser execution or secondary requests are performed.
enum WebPageHTTP {
    static let maximumBodyBytes = 1_048_576
    static let maximumHeaderBytes = 32_768
    static let maximumWireBytes = maximumBodyBytes + maximumHeaderBytes

    static func request(url: URL) throws -> (hostname: String, bytes: Data) {
        guard let safeURL = WebSearchClient.publicHTTPSURL(url),
              let parts = URLComponents(url: safeURL, resolvingAgainstBaseURL: false), let host = parts.host else {
            throw WebPageError.unsafeAddress
        }
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        let target = path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard target.hasPrefix("/"), target.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw WebPageError.unsafeAddress
        }
        let request = "GET \(target) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: Eudes/1.0 (Web Reading)\r\nAccept: text/html, application/xhtml+xml, text/plain, text/markdown\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
        return (host, Data(request.utf8))
    }

    static func parse(_ data: Data) throws -> WebPageResponse {
        guard data.count <= maximumWireBytes else { throw WebPageError.responseTooLarge }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              separator.lowerBound <= maximumHeaderBytes,
              let header = String(data: data[..<separator.lowerBound], encoding: .ascii) else {
            throw WebPageError.invalidResponse
        }
        let lines = header.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ", maxSplits: 2)
        guard status.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(String(status[0])),
              status[1].count == 3, let code = Int(status[1]) else { throw WebPageError.invalidResponse }
        if (300...399).contains(code) { throw WebPageError.redirectNotAllowed }
        guard (200...299).contains(code) else { throw WebPageError.httpStatus(code) }
        var fields: [String: String] = [:]
        let framingFields: Set<String> = ["content-type", "content-length", "content-encoding", "transfer-encoding"]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else {
                throw WebPageError.invalidResponse
            }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                throw WebPageError.invalidResponse
            }
            if framingFields.contains(name), fields[name] != nil { throw WebPageError.invalidResponse }
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["content-encoding"] == nil || fields["content-encoding"]?.lowercased() == "identity" else {
            throw WebPageError.unsupportedContent
        }
        guard let contentType = fields["content-type"] else { throw WebPageError.unsupportedContent }
        var body = Data(data[separator.upperBound...])
        if let encoding = fields["transfer-encoding"] {
            guard encoding.lowercased() == "chunked", fields["content-length"] == nil else { throw WebPageError.invalidResponse }
            body = try decodeChunks(body)
        } else if let length = fields["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length) else {
                throw WebPageError.invalidResponse
            }
            guard count <= maximumBodyBytes else { throw WebPageError.responseTooLarge }
            guard body.count == count else { throw WebPageError.invalidResponse }
        }
        guard body.count <= maximumBodyBytes else { throw WebPageError.responseTooLarge }
        return WebPageResponse(body: body, contentType: contentType)
    }

    private static func decodeChunks(_ data: Data) throws -> Data {
        var offset = 0
        var decoded = Data()
        let crlf = Data("\r\n".utf8)
        while offset < data.count {
            guard let end = data.range(of: crlf, in: offset..<data.count), end.lowerBound - offset <= 1_024,
                  let line = String(data: data[offset..<end.lowerBound], encoding: .ascii),
                  let sizeText = line.split(separator: ";", maxSplits: 1).first,
                  !sizeText.isEmpty, sizeText.count <= 16,
                  sizeText.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let size = Int(sizeText, radix: 16) else { throw WebPageError.invalidResponse }
            offset = end.upperBound
            if size == 0 {
                // Trailers are irrelevant to page evidence, but their framing must terminate.
                let trailing = Data(data[offset...])
                guard trailing == crlf || (trailing.count <= maximumHeaderBytes &&
                    trailing.suffix(4) == Data("\r\n\r\n".utf8)) else { throw WebPageError.invalidResponse }
                return decoded
            }
            guard size <= maximumBodyBytes - decoded.count else { throw WebPageError.responseTooLarge }
            guard size <= data.count - offset, data.count - offset - size >= 2,
                  data[(offset + size)..<(offset + size + 2)] == crlf else { throw WebPageError.invalidResponse }
            decoded.append(data[offset..<(offset + size)])
            offset += size + 2
        }
        throw WebPageError.invalidResponse
    }
}

struct PinnedWebPageTransport: WebPageTransport {
    func fetch(url: URL) async throws -> WebPageResponse {
        try Task.checkCancellation()
        let request = try WebPageHTTP.request(url: url)
        let operation = PinnedWebPageOperation(hostname: request.hostname, request: request.bytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in operation.start(continuation) }
        } onCancel: {
            operation.cancel()
        }
    }
}

/// Mutable state is confined to queue. DNS is resolved once on a utility thread;
/// the selected endpoint is an IP value, never a hostname that can rebind later.
private final class PinnedWebPageOperation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fr.eudes.app.web-page")
    private let hostname: String
    private let request: Data
    private var continuation: CheckedContinuation<WebPageResponse, Error>?
    private var connection: NWConnection?
    private var deadline: DispatchWorkItem?
    private var finished = false
    private var cancelled = false
    private var received = Data()
    private var candidates: [NWEndpoint.Host] = []

    init(hostname: String, request: Data) { self.hostname = hostname; self.request = request }

    func start(_ continuation: CheckedContinuation<WebPageResponse, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            if self.cancelled { self.finish(.failure(CancellationError())); return }
            let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(WebPageError.timedOut)) }
            self.deadline = timeout
            self.queue.asyncAfter(deadline: .now() + 15, execute: timeout)
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try Self.resolve(self.hostname) }
                self.queue.async {
                    guard !self.finished else { return }
                    switch result {
                    case .success(let addresses):
                        self.candidates = addresses
                        self.connectNext()
                    case .failure(let error): self.finish(.failure(error))
                    }
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            if self.continuation != nil { self.finish(.failure(CancellationError())) }
        }
    }

    private func connectNext() {
        guard !finished else { return }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        guard !candidates.isEmpty else { finish(.failure(WebPageError.unavailable)); return }
        received = Data()
        let endpoint = candidates.removeFirst()
        let tls = NWProtocolTLS.Options()
        // Apple's documented override verifies the peer certificate for the original
        // DNS name even though the socket connects to an IP. Default trust stays enabled.
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, hostname)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.preferNoProxies = true
        let next = NWConnection(host: endpoint, port: 443, using: parameters)
        connection = next
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next, self.connection === next, !self.finished else { return }
            switch state {
            case .ready:
                next.send(content: self.request, completion: .contentProcessed { [weak self, weak next] error in
                    guard let self, let next, self.connection === next, !self.finished else { return }
                    if error != nil { self.finish(.failure(WebPageError.unavailable)); return }
                    self.receive(next)
                })
            case .failed, .waiting: self.connectNext()
            default: break
            }
        }
        next.start(queue: queue)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection, !self.finished else { return }
            if let data {
                guard data.count <= WebPageHTTP.maximumWireBytes - self.received.count else {
                    self.finish(.failure(WebPageError.responseTooLarge)); return
                }
                self.received.append(data)
                if self.received.count > WebPageHTTP.maximumHeaderBytes,
                   self.received.range(of: Data("\r\n\r\n".utf8)) == nil {
                    self.finish(.failure(WebPageError.responseTooLarge)); return
                }
            }
            if error != nil { self.finish(.failure(WebPageError.unavailable)); return }
            if complete {
                self.finish(Result { try WebPageHTTP.parse(self.received) })
            } else {
                self.receive(connection)
            }
        }
    }

    private func finish(_ result: Result<WebPageResponse, Error>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let callback = continuation
        continuation = nil
        callback?.resume(with: result)
    }

    private static func resolve(_ hostname: String) throws -> [NWEndpoint.Host] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, "443", &hints, &first) == 0, let first else { throw WebPageError.unavailable }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let entry = node {
            let info = entry.pointee
            guard info.ai_family == AF_INET || info.ai_family == AF_INET6, let address = info.ai_addr else {
                throw WebPageError.unsafeAddress
            }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, info.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else {
                throw WebPageError.unsafeAddress
            }
            addresses.append(String(cString: name))
            guard addresses.count <= 64 else { throw WebPageError.unsafeAddress }
            node = info.ai_next
        }
        return try WebPageAddressPolicy.validatedEndpoints(addresses)
    }
}
