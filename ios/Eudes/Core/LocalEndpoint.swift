import Foundation
import Darwin

/// Validates an explicitly configured API origin. DNS names are allowed; redirects,
/// URL credentials, ambiguous numeric hosts and unapproved cleartext remain forbidden.
struct LocalEndpoint: Equatable {
    let baseURL: URL

    init(_ input: String, allowsHTTP: Bool) throws {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(https?)://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+)(?::([0-9]+))?(/[A-Za-z0-9_./~-]*)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.range == range,
              let hostRange = Range(match.range(at: 2), in: raw),
              var components = URLComponents(string: raw) else { throw EudesError.invalidAddress }
        let host = String(raw[hostRange]).lowercased()
        if host.hasPrefix("[") {
            let address = String(host.dropFirst().dropLast())
            var bytes = in6_addr()
            guard inet_pton(AF_INET6, address, &bytes) == 1 else { throw EudesError.invalidAddress }
            // Only ULA and the exact loopback address; no unspecified/link-local/global IPs.
            let octets = withUnsafeBytes(of: bytes) { Array($0) }
            let loopback = octets.dropLast().allSatisfy { $0 == 0 } && octets.last == 1
            guard octets[0] & 0xfe == 0xfc || loopback else { throw EudesError.publicAddress }
            if loopback { components.host = "[::1]" }
        } else if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            guard Self.isPrivateIPv4(host) || host == "127.0.0.1" else { throw EudesError.publicAddress }
        } else if host == "localhost" {
            components.host = "localhost"
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard host.count <= 253, labels.count >= 2,
                  labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" }),
                  let last = labels.last, last.contains(where: { $0.isLetter }),
                  host != "localhost", !host.hasSuffix(".localhost"),
                  !host.hasPrefix("0x") else { throw EudesError.invalidAddress }
        }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw EudesError.invalidAddress
        }
        if match.range(at: 3).location != NSNotFound {
            guard let portRange = Range(match.range(at: 3), in: raw),
                  let port = Int(raw[portRange]), (1...65535).contains(port),
                  String(port) == String(raw[portRange]) else { throw EudesError.invalidAddress }
        }
        guard components.scheme != "http" || allowsHTTP else { throw EudesError.insecureHTTP }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw EudesError.invalidAddress }
        baseURL = url
    }

    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), (0...255).contains(value), String(value) == String(part) else {
                return false
            }
            values.append(value)
        }
        return values[0] == 10 || (values[0] == 172 && (16...31).contains(values[1]))
            || (values[0] == 192 && values[1] == 168)
    }

    enum Route: String { case models = "models", completions = "chat/completions", responses = "responses", countTokens = "messages/count_tokens" }

    func url(for route: Route) -> URL {
        route.rawValue.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
    }
}
