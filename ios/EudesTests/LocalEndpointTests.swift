// personal-data: allow-file — les tests d'endpoint citent des adresses RFC 1918
// (10.0.0.1, 172.16.0.1) parce que la politique réseau doit les accepter ou les refuser.
import XCTest
import UIKit
import Network
@testable import Eudes

final class LocalEndpointTests: XCTestCase {
    func testNVIDIAFreeCatalogueFiltersAndDoesNotSendCredentials() throws {
        let json = #"""
        {"resultPageTotal":1,"resultTotal":2,"results":[
          {"groupValue":"_scored","totalCount":1,"resources":[{"name":"ignored","labels":[]}]},
          {"groupValue":"ENDPOINT","totalCount":2,"resources":[
            {"name":"deepseek-v4.1-flash","labels":[{"key":"general","values":["Free Endpoint"]},{"key":"publisher","values":["deepseek-ai"]}]},
            {"name":"nemotron-3.5-bolt-e4b","labels":[{"key":"general","values":["Free Endpoint"]},{"key":"publisher","values":["nvidia"]}]}
          ]} ]}
        """#
        let page = try NVIDIAFreeCatalog.parse(Data(json.utf8), page: 0)
        XCTAssertEqual(page.ids, ["deepseek-ai/deepseek-v4.1-flash", "nvidia/nemotron-3.5-bolt-e4b"])
        let request = try NVIDIAFreeCatalog.request(page: 0)
        XCTAssertEqual(request.url?.host, "api.ngc.nvidia.com")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(request.url?.absoluteString.contains("api_key") ?? true)
    }

    func testNVIDIAFreeCataloguePaginatesAndRejectsIncompleteSecondPage() throws {
        func resource(_ name: String) -> [String: Any] {
            ["name": name, "labels": [["key": "general", "values": ["Free Endpoint"]],
                                      ["key": "publisher", "values": ["nvidia"]]]]
        }
        func response(_ resources: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["resultPageTotal": 2, "resultTotal": 101,
                "results": [["groupValue": "ENDPOINT", "totalCount": 101, "resources": resources]]])
        }
        let first = try NVIDIAFreeCatalog.parse(response((0..<100).map { resource("model-\($0)") }), page: 0)
        let second = try NVIDIAFreeCatalog.parse(response([resource("model-100")]), page: 1)
        XCTAssertEqual(first.ids.count, 100)
        XCTAssertEqual(second.ids, ["nvidia/model-100"])
        XCTAssertEqual(second.pages, 2)
        XCTAssertThrowsError(try NVIDIAFreeCatalog.parse(response([]), page: 1))
    }

    func testNVIDIAFreeCatalogueFailsClosedForIncompleteOrChangedResponse() {
        for json in [
            #"{"resultPageTotal":1,"resultTotal":2,"results":[{"groupValue":"ENDPOINT","totalCount":2,"resources":[]}]}"#,
            #"{"resultPageTotal":1,"resultTotal":1,"results":[{"groupValue":"ENDPOINT","totalCount":1,"resources":[{"name":"unsafe","labels":[{"key":"publisher","values":["nvidia"]}]}]}]}"#,
            #"{"resultPageTotal":1,"resultTotal":1,"results":[{"groupValue":"ENDPOINT","totalCount":1,"resources":[{"name":"x","labels":[{"key":"general","values":["Free Endpoint"]},{"key":"publisher","values":["a","b"]}]}]}]}"#
        ] {
            XCTAssertThrowsError(try NVIDIAFreeCatalog.parse(Data(json.utf8), page: 0))
        }
    }

    func testLoopbackRoutesPortsAndHTTPConsent() throws {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            for scheme in ["http", "https"] {
                for suffix in ["", ":8000/v1", ":65535/api/v1/"] {
                    let input = "\(scheme)://\(host)\(suffix)"
                    let endpoint = try LocalEndpoint(input, allowsHTTP: true)
                    let base = input.hasSuffix("/") ? String(input.dropLast()) : input
                    for route in [LocalEndpoint.Route.models, .completions, .responses] {
                        XCTAssertEqual(endpoint.url(for: route).absoluteString, base + "/" + route.rawValue)
                    }
                    if scheme == "http" {
                        XCTAssertThrowsError(try LocalEndpoint(input, allowsHTTP: false)) {
                            guard case EudesError.insecureHTTP = $0 else { return XCTFail("Expected explicit HTTP consent error, got \($0)") }
                        }
                    } else { XCTAssertNoThrow(try LocalEndpoint(input, allowsHTTP: false)) }
                }
            }
        }
        XCTAssertEqual(try LocalEndpoint("http://LOCALHOST:8000/v1/", allowsHTTP: true).baseURL.absoluteString,
                       "http://localhost:8000/v1")
        XCTAssertEqual(try LocalEndpoint("http://[0:0:0:0:0:0:0:1]:8000/v1", allowsHTTP: true).baseURL.absoluteString,
                       "http://[::1]:8000/v1")
        for invalid in ["http://127.1/v1", "http://2130706433/v1", "http://0x7f000001/v1",
                        "http://127.000.0.1/v1", "http://localhost./v1", "http://localhost:0/v1",
                        "http://localhost:65536/v1", "http://localhost:080/v1", "http://user@localhost/v1",
                        "http://localhost/v1?key=x", "http://localhost/v1#x", "http://localhost/../v1",
                        "http://[::ffff:127.0.0.1]/v1", "http://[fe80::1%25lo0]/v1"] {
            XCTAssertThrowsError(try LocalEndpoint(invalid, allowsHTTP: true), invalid)
        }
    }

    func testLoopbackATSExceptionsAreNarrow() throws {
        let ats = try XCTUnwrap(Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertNil(ats["NSAllowsArbitraryLoads"])
        XCTAssertNil(ats["NSAllowsLocalNetworking"])
        let domains = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: [String: Any]])
        for host in ["localhost", "127.0.0.1", "::1/128"] {
            XCTAssertEqual(domains[host]?["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true)
            XCTAssertNil(domains[host]?["NSIncludesSubdomains"])
            XCTAssertNil(domains[host]?["NSExceptionMinimumTLSVersion"])
        }
    }

    /// Real URLSession/ATS over an ephemeral loopback-only fixture. No provider or inference.
    func testLoopbackHTTPTransportOnSimulator() async throws {
        for host in ["127.0.0.1", "localhost", "[::1]"] {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: host == "[::1]" ? "::1" : "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let ready = expectation(description: "Loopback listener \(host)")
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.fulfill() }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: DispatchQueue(label: "EudesLoopbackFixture.connection"))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                    let body = #"{"data":[{"id":"loopback-fixture"}]}"#
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: DispatchQueue(label: "EudesLoopbackFixture.listener"))
            defer { listener.cancel() }
            await fulfillment(of: [ready], timeout: 5)
            let port = try XCTUnwrap(listener.port)
            let profile = ServerProfile(name: "Loopback fixture", baseURL: "http://\(host):\(port.rawValue)/v1",
                                        model: "loopback-fixture", allowsHTTP: true)
            let catalog = try await LocalAPIClient().catalog(profile: profile, key: "")
            XCTAssertEqual(catalog.ids, ["loopback-fixture"], host)
        }
    }

    func testAcceptsOnlyCanonicalPrivateIPv4() throws {
        for ip in ["10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.254", "192.168.1.10"] {
            let endpoint = try LocalEndpoint("http://\(ip):8000/v1/", allowsHTTP: true)
            XCTAssertEqual(endpoint.url(for: .completions).absoluteString, "http://\(ip):8000/v1/chat/completions")
        }
    }

    func testRejectsExternalAndAmbiguousDestinations() {
        let addresses = [
            "https://8.8.8.8/v1", "http://127.0.0.2/v1",
            "http://169.254.169.254/v1", "http://100.64.0.1/v1", "http://172.15.0.1/v1",
            "http://172.32.0.1/v1", "http://192.169.0.1/v1", "http://0.0.0.0/v1",
            "http://192.168.001.1/v1", "http://3232235777/v1", "http://0xc0a80101/v1",
            "http://192.168.1.999/v1", "http://bad..example/v1",
            "http://192.168.1.1@8.8.8.8/v1", "http://user:pass@192.168.1.1/v1",
            "http://192.168.1.1/v1?redirect=https://example.com", "http://192.168.1.1/v1#x",
            "http://192.168.1.1:0/v1", "http://192.168.1.1:65536/v1", "http://192.168.1.1:080/v1",
            "http://192.168.1.1/%2e%2e/v1", "http://192.168.1.1/../v1",
            "file:///etc/passwd", "http://[::]/v1", "http://api.localhost/v1"
        ]
        for address in addresses { XCTAssertThrowsError(try LocalEndpoint(address, allowsHTTP: true), address) }
    }

    func testDomainsPortsPathsAndIPv6() throws {
        for base in ["https://integrate.api.nvidia.com/v1", "https://api.example.com:8443/api/v1.0",
                     "https://spark.local/v1", "https://[fd12:3456::1]:8443/v1"] {
            XCTAssertEqual(try LocalEndpoint(base + "/", allowsHTTP: false).url(for: .models).absoluteString, base + "/models")
        }
        XCTAssertThrowsError(try LocalEndpoint("http://api.example.com:8080/v1", allowsHTTP: false))
        XCTAssertNoThrow(try LocalEndpoint("http://api.example.com:8080/v1", allowsHTTP: true))
        for invalid in ["https://-bad.example/v1", "https://bad-.example/v1", "https://example.com:65536/v1",
                        "https://user:pass@example.com/v1", "https://example.com/v1?key=x", "https://example.com/../v1",
                        "https://[::2]/v1", "https://[fe80::1]/v1", "https://example.com%2f.evil/v1"] {
            XCTAssertThrowsError(try LocalEndpoint(invalid, allowsHTTP: true), invalid)
        }
        let profile = ServerProfile(name: "Fictif", baseURL: "https://integrate.api.nvidia.com/v1", model: "fixture")
        XCTAssertEqual(try LocalAPIClient.request(profile: profile, key: "", route: .completions).url?.absoluteString,
                       "https://integrate.api.nvidia.com/v1/chat/completions")
    }

    func testGenerationTimeoutsAllowSlowStreamWithoutChangingControls() throws {
        let profile = ServerProfile(name: "Fixture", baseURL: "https://example.com/v1", model: "model")
        let request = try LocalAPIClient.completionRequest(profile: profile, key: "", model: profile.model,
            messages: [], systemPrompt: "", temperature: 1, maxTokens: nil)
        XCTAssertEqual(request.timeoutInterval, 120)
        let generation = LocalAPIClient.generationConfiguration()
        XCTAssertEqual(generation.timeoutIntervalForRequest, 120)
        XCTAssertEqual(generation.timeoutIntervalForResource, 600)
        XCTAssertNil(generation.urlCache)
        XCTAssertNil(generation.httpCookieStorage)
        // Other short-lived operations continue using their existing base config.
        let baseline = LocalAPIClient.configuration()
        XCTAssertEqual(baseline.timeoutIntervalForRequest, 30)
        XCTAssertEqual(baseline.timeoutIntervalForResource, 180)
    }

    func testHTTPRequiresExplicitPermission() {
        XCTAssertThrowsError(try LocalEndpoint("http://192.168.1.5:8000/v1", allowsHTTP: false))
        XCTAssertNoThrow(try LocalEndpoint("https://192.168.1.5:8443/v1", allowsHTTP: false))
    }

    func testEveryRedirectIsRefused() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "http://192.168.1.5/v1")!, statusCode: 302, httpVersion: nil, headerFields: nil))
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "http://192.168.1.5/v1")!)
        defer { task.cancel(); session.invalidateAndCancel() }
        var completed = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://8.8.8.8/collect")!)) { request in
            completed = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(completed)
    }

    func testRequestUsesOnlyValidatedEndpoint() throws {
        let profile = ServerProfile(name: "Test", baseURL: "http://192.168.1.5:8000/v1", model: "local", allowsHTTP: true)
        let request = try LocalAPIClient.request(profile: profile, key: "test-secret", route: .models)
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.5:8000/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        for invalidKey in ["bad\r\nHeader: x", "bad\rHeader: x", "bad\nHeader: x", "bad\u{0}key", "bad\u{7f}key", "bad\tkey"] {
            XCTAssertThrowsError(try LocalAPIClient.request(profile: profile, key: invalidKey, route: .models))
        }
        XCTAssertNil(LocalAPIClient.configuration().urlCache)
        XCTAssertNil(LocalAPIClient.configuration().httpCookieStorage)
    }
}

extension LocalEndpointTests {
    func testRecoverableResponsesRequireExplicitOptInAndExactOpenAIOrigin() throws {
        var official = ServerProfile(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "fixture")
        official.protocolKind = .responses
        XCTAssertTrue(official.supportsOpenAIBackground)
        XCTAssertFalse(official.usesOpenAIBackground, "Le stockage temporaire doit rester facultatif pour les anciens profils")
        official.openAIBackgroundResponses = true
        XCTAssertTrue(official.usesOpenAIBackground)
        var chat = official; chat.protocolKind = .chatCompletions
        XCTAssertFalse(chat.usesOpenAIBackground)
        for address in ["https://integrate.api.nvidia.com/v1", "https://api.openai.com.evil.example/v1", "https://api.openai.com/other", "https://api.openai.com:8443/v1", "http://api.openai.com/v1", "https://user@api.openai.com/v1", "https://api.openai.com/v1?other=1"] {
            var other = official; other.baseURL = address; other.allowsHTTP = true
            XCTAssertFalse(other.usesOpenAIBackground, address)
            XCTAssertThrowsError(try OpenAIRecoverableResponseClient.retrieveRequest(profile: other, key: "fixture-key", responseID: "resp_123"), address)
        }
        let legacy = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(ServerProfile(name: "Ancien", baseURL: "https://api.openai.com/v1", model: "fixture")))
        XCTAssertNil(legacy.openAIBackgroundResponses)
        XCTAssertFalse(legacy.usesOpenAIBackground)
    }

    func testRecoverableRequestsAreScopedAndNeverPersistSecretsInURL() throws {
        var profile = ServerProfile(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "fixture")
        profile.protocolKind = .responses; profile.openAIBackgroundResponses = true
        let request = try OpenAIRecoverableResponseClient.backgroundRequest(profile: profile, key: "fixture-key", model: "fixture", messages: [ChatMessage(role: .user, text: "Bonjour")], systemPrompt: "", temperature: 0.7, maxTokens: nil)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        XCTAssertFalse(request.url?.absoluteString.contains("fixture-key") ?? true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["background"] as? Bool, true)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        let get = try OpenAIRecoverableResponseClient.retrieveRequest(profile: profile, key: "fixture-key", responseID: "resp_123")
        XCTAssertEqual(get.httpMethod, "GET")
        XCTAssertEqual(get.url?.absoluteString, "https://api.openai.com/v1/responses/resp_123")
        let cancel = try OpenAIRecoverableResponseClient.cancelRequest(profile: profile, key: "fixture-key", responseID: "resp_123")
        XCTAssertEqual(cancel.httpMethod, "POST")
        XCTAssertEqual(cancel.url?.absoluteString, "https://api.openai.com/v1/responses/resp_123/cancel")
        for invalid in ["", "../resp_123", "resp_123/cancel", "resp_123?key=abc", "https://evil.example/resp_123", "resp_123#x", "resp_%2Fadmin"] {
            XCTAssertThrowsError(try OpenAIRecoverableResponseClient.retrieveRequest(profile: profile, key: "fixture-key", responseID: invalid), invalid)
            XCTAssertThrowsError(try OpenAIRecoverableResponseClient.cancelRequest(profile: profile, key: "fixture-key", responseID: invalid), invalid)
        }
    }

    func testRecoverableSnapshotDistinguishesCompletedFromAllOtherStatuses() throws {
        for pair in [("queued", RecoverableSnapshot.Status.queued), ("in_progress", .inProgress), ("failed", .failed), ("cancelled", .cancelled), ("incomplete", .incomplete)] {
            let value = try OpenAIRecoverableResponseClient.parseSnapshot(Data("{\"id\":\"resp_123\",\"status\":\"\(pair.0)\"}".utf8))
            XCTAssertEqual(value.status, pair.1, pair.0)
        }
        let finished = #"{"id":"resp_123","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Réponse finale"}]}]}"#
        let value = try OpenAIRecoverableResponseClient.parseSnapshot(Data(finished.utf8))
        XCTAssertEqual(value.status, .completed)
        XCTAssertEqual(value.text, "Réponse finale")
        XCTAssertThrowsError(try OpenAIRecoverableResponseClient.parseSnapshot(Data(#"{"id":"resp_123","status":"invented"}"#.utf8)))
    }
}

extension LocalEndpointTests {
    @MainActor
    func testRecoverableTransportStreamsCreatedBeforeTextAndRetrievesFinalSnapshot() async throws {
        var profile = ServerProfile(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "fixture")
        profile.protocolKind = .responses; profile.openAIBackgroundResponses = true
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoverableURLStub.self]
        let client = OpenAIRecoverableResponseClient(configuration: config)
        var created: String?
        var visibleText = ""
        try await client.start(profile: profile, key: "fixture-key", model: "fixture", messages: [ChatMessage(role: .user, text: "Bonjour")], systemPrompt: "", temperature: 0.7, maxTokens: nil, onCreated: { id in
            XCTAssertEqual(visibleText, "")
            created = id
        }, onText: { text in
            XCTAssertEqual(created, "resp_fixture")
            visibleText = text
        }, onReasoning: { _ in }, onUsage: { _ in })
        XCTAssertEqual(created, "resp_fixture")
        XCTAssertEqual(visibleText, "Bonjour")
        let snapshot = try await client.retrieve(profile: profile, key: "fixture-key", responseID: "resp_fixture")
        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertEqual(snapshot.text, "Bonjour")
        try await client.cancel(profile: profile, key: "fixture-key", responseID: "resp_fixture")
    }

    func testRecoverableCancellationRequiresMatchingCancelledAcknowledgment() async throws {
        var profile = ServerProfile(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "fixture")
        profile.protocolKind = .responses; profile.openAIBackgroundResponses = true
        for scenario in ["cancel-completed", "cancel-in-progress", "cancel-wrong-id", "cancel-malformed"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RecoverableURLStub.self]
            config.httpAdditionalHeaders = ["X-Eudes-Fixture": scenario]
            let client = OpenAIRecoverableResponseClient(configuration: config)
            do {
                try await client.cancel(profile: profile, key: "fixture-key", responseID: "resp_fixture")
                XCTFail("A 200 response without a matching cancelled status must not confirm cancellation: \(scenario)")
            } catch { }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoverableURLStub.self]
        try await OpenAIRecoverableResponseClient(configuration: config).cancel(profile: profile, key: "fixture-key", responseID: "resp_fixture")
    }

    @MainActor
    func testRecoverableTransportStopsIfIdentityCannotBePersisted() async throws {
        struct CannotSave: Error {}
        var profile = ServerProfile(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "fixture")
        profile.protocolKind = .responses; profile.openAIBackgroundResponses = true
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoverableURLStub.self]
        let client = OpenAIRecoverableResponseClient(configuration: config)
        var visibleText = ""
        do {
            try await client.start(profile: profile, key: "fixture-key", model: "fixture", messages: [], systemPrompt: "", temperature: 0.7, maxTokens: nil, onCreated: { _ in throw CannotSave() }, onText: { visibleText = $0 }, onReasoning: { _ in }, onUsage: { _ in })
            XCTFail("Unpersisted identity must not be silently accepted")
        } catch is CannotSave { }
        XCTAssertEqual(visibleText, "")
    }

    func testRecoverableSnapshotRejectsChangedIdentityAndOversizedPayload() throws {
        let wrong = Data(#"{"id":"resp_other","status":"in_progress"}"#.utf8)
        XCTAssertThrowsError(try OpenAIRecoverableResponseClient.parseSnapshot(wrong, expectedID: "resp_expected"))
        let huge = Data(repeating: 0x20, count: 4_194_305)
        XCTAssertThrowsError(try OpenAIRecoverableResponseClient.parseSnapshot(huge, expectedID: "resp_expected"))
    }

    func testRecoverableFetchReportsExpiredOrMissingResponse() async throws {
        var profile = ServerProfile(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "fixture")
        profile.protocolKind = .responses; profile.openAIBackgroundResponses = true
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoverableURLStub.self]
        let client = OpenAIRecoverableResponseClient(configuration: config)
        do {
            _ = try await client.retrieve(profile: profile, key: "fixture-key", responseID: "resp_missing")
            XCTFail("An expired response must not be reported as complete")
        } catch { }
    }

    @MainActor
    func testRecoverableStreamRejectsChangedIdentityWithoutPublishingText() async throws {
        var profile = ServerProfile(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "fixture")
        profile.protocolKind = .responses; profile.openAIBackgroundResponses = true
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoverableURLStub.self]
        config.httpAdditionalHeaders = ["X-Eudes-Fixture": "changed-identity"]
        let client = OpenAIRecoverableResponseClient(configuration: config)
        var identities: [String] = []
        var visibleText = ""
        do {
            try await client.start(profile: profile, key: "fixture-key", model: "fixture", messages: [], systemPrompt: "", temperature: 0.7, maxTokens: nil, onCreated: { identities.append($0) }, onText: { visibleText = $0 }, onReasoning: { _ in }, onUsage: { _ in })
            XCTFail("A response changing identity must be rejected")
        } catch { }
        XCTAssertEqual(identities, ["resp_fixture"])
        XCTAssertEqual(visibleText, "")
    }

    @MainActor
    func testRecoverableTransportRejectsTextBeforeIdentityIsStored() async throws {
        var profile = ServerProfile(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "fixture")
        profile.protocolKind = .responses; profile.openAIBackgroundResponses = true
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoverableURLStub.self]
        config.httpAdditionalHeaders = ["X-Eudes-Fixture": "missing-created"]
        let client = OpenAIRecoverableResponseClient(configuration: config)
        var visibleText = ""
        do {
            try await client.start(profile: profile, key: "fixture-key", model: "fixture", messages: [], systemPrompt: "", temperature: 0.7, maxTokens: nil, onCreated: { _ in XCTFail("No identity was sent") }, onText: { visibleText = $0 }, onReasoning: { _ in }, onUsage: { _ in })
            XCTFail("A stream without a recoverable identity must not silently succeed")
        } catch { }
        XCTAssertEqual(visibleText, "")
    }
}

private final class RecoverableURLStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.scheme == "https", url.host == "api.openai.com", request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        if url.path == "/v1/responses/resp_missing" && request.httpMethod == "GET" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"missing"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body: String
        let contentType: String
        if url.path == "/v1/responses" && request.httpMethod == "POST" {
            contentType = "text/event-stream"
            let created = #"{"type":"response.created","response":{"id":"resp_fixture","status":"queued"}}"#
            let delta = #"{"type":"response.output_text.delta","delta":"Bonjour"}"#
            let finished = #"{"type":"response.completed","response":{"id":"resp_fixture","status":"completed"}}"#
            let scenario = request.value(forHTTPHeaderField: "X-Eudes-Fixture")
            let changed = #"{"type":"response.created","response":{"id":"resp_other","status":"queued"}}"#
            body = (scenario == "missing-created" ? "" : "data: \(created)\n\n") + (scenario == "changed-identity" ? "data: \(changed)\n\n" : "") + "data: \(delta)\n\ndata: \(finished)\n\n"
        } else if url.path == "/v1/responses/resp_fixture" && request.httpMethod == "GET" {
            contentType = "application/json"
            body = #"{"id":"resp_fixture","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Bonjour"}]}]}"#
        } else if url.path == "/v1/responses/resp_fixture/cancel" && request.httpMethod == "POST" {
            contentType = "application/json"
            switch request.value(forHTTPHeaderField: "X-Eudes-Fixture") {
            case "cancel-completed": body = #"{"id":"resp_fixture","status":"completed"}"#
            case "cancel-in-progress": body = #"{"id":"resp_fixture","status":"in_progress"}"#
            case "cancel-wrong-id": body = #"{"id":"resp_other","status":"cancelled"}"#
            case "cancel-malformed": body = "{}"
            default: body = #"{"id":"resp_fixture","status":"cancelled"}"#
            }
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": contentType])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LocalModelCatalogTests: XCTestCase {
    func testReasoningDoesNotInterruptPartialClosingTag() {
        XCTAssertTrue(LocalReasoningBoundary.containsPartialClosingTag("thinking</thi"))
        XCTAssertFalse(LocalReasoningBoundary.containsPartialClosingTag("thinking"))
        XCTAssertFalse(LocalReasoningBoundary.containsPartialClosingTag("thinking</think>"))
    }
    func testLocalContextAndReasoningOptions() {
        XCTAssertEqual(LocalModelCatalog.contextSize(nil), 4096)
        XCTAssertEqual(LocalModelCatalog.contextSize(1234), 4096)
        XCTAssertEqual(LocalModelCatalog.contextSize(65536), 65536)
        XCTAssertEqual(LocalLlamaEngine.contextParameters(useGPU: false, contextTokens: 65536).n_ctx, 65536)
        XCTAssertEqual(LocalModelCatalog.reasoningSize(nil), 512)
        XCTAssertEqual(LocalModelCatalog.reasoningSize(8192), 8192)
        XCTAssertEqual(LocalModelCatalog.reasoningSize(7), 512)
    }

    func testLFMReportsConfiguredContextAndIgnoresUnrelatedOverrides() {
        for var profile in [ServerProfile.lfmText, ServerProfile.lfmVision] {
            profile.setContextBudget(100_000, model: profile.model)
            XCTAssertEqual(profile.maximumContext(for: profile.model), LocalModelCatalog.allocatedContextTokens)
            XCTAssertEqual(profile.maximumContext(for: profile.model), 4096)
            XCTAssertNil(profile.maximumContext(for: "different-model"))
            let assessment = ContextAssessment.make(profile: profile, model: profile.model,
                messages: [ChatMessage(role: .user, text: "Bonjour")], instructions: "", requestedOutput: 128)
            XCTAssertEqual(assessment.budget, 4096)
        }
    }

    func testEveryAssetResolvesToItsOwnHuggingFaceRepository() throws {
        for model in LocalModelCatalog.models {
            for asset in model.assets {
                let url = try XCTUnwrap(model.url(for: asset))
                XCTAssertEqual(url.host, "huggingface.co")
                let repository = model.repository.contains("/") ? model.repository : "LiquidAI/\(model.repository)"
                XCTAssertEqual(url.path, "/\(repository)/resolve/\(model.revision)/\(asset.filename)")
                XCTAssertFalse(url.path.contains("LiquidAI/unsloth"), url.path)
            }
        }
        XCTAssertEqual(LocalModelCatalog.qwen35_2b.repository, "unsloth/Qwen3.5-2B-GGUF")
    }

    func testPinnedModelAssetsHaveExpectedSizesAndOrigins() throws {
        XCTAssertEqual(LocalModelCatalog.models.count, LocalModelCatalog.extended.count + 2)
        XCTAssertEqual(LocalModelCatalog.text.downloadBytes, 1_099_627_808)
        XCTAssertEqual(LocalModelCatalog.vision.downloadBytes, 1_302_659_680)
        XCTAssertFalse(LocalModelCatalog.text.supportsImages)
        XCTAssertTrue(LocalModelCatalog.vision.supportsImages)
        XCTAssertEqual(LocalModelCatalog.text.capabilityDescription, "Modèle texte")
        XCTAssertEqual(LocalModelCatalog.vision.capabilityDescription, "Modèle texte + vision")
        XCTAssertNotNil(LocalModelCatalog.text.imageUnavailableReason)
        XCTAssertNil(LocalModelCatalog.vision.imageUnavailableReason)
        for model in LocalModelCatalog.models {
            XCTAssertEqual(model.revision.count, 40)
            for asset in model.assets {
                let url = try XCTUnwrap(model.url(for: asset))
                XCTAssertEqual(url.scheme, "https")
                XCTAssertEqual(url.host, "huggingface.co")
                XCTAssertTrue(url.path.contains(model.revision))
                XCTAssertEqual(asset.sha256.count, 64)
            }
        }
        XCTAssertNil(LocalModelCatalog.text.url(for: LocalModelCatalog.vision.assets[0]))
    }
}

final class LocalModelFileStoreTests: XCTestCase {
    func testVerificationCacheRejectsReplacedAndRemovedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.gguf")
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        var cache = LocalModelFileStore.VerificationCache()
        try Data("abc".utf8).write(to: file)
        try cache.verify(file, size: 3, sha256: sha)
        try cache.verify(file, size: 3, sha256: sha)
        XCTAssertThrowsError(try cache.verify(file, size: 3, sha256: String(repeating: "0", count: 64)))
        try cache.verify(file, size: 3, sha256: sha)
        let originalDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try Data("xyz".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        XCTAssertThrowsError(try cache.verify(file, size: 3, sha256: sha))
        try Data("abc".utf8).write(to: file)
        try cache.verify(file, size: 3, sha256: sha)
        try Data("xyz".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try cache.verify(file, size: 3, sha256: sha))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try cache.verify(file, size: 3, sha256: sha))
    }

    func testVerificationCacheReusesPersistedDigestAcrossLaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.gguf")
        let store = root.appendingPathComponent("verification.json")
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data("abc".utf8).write(to: file)

        var first = LocalModelFileStore.VerificationCache(storeURL: store)
        let hashed = try first.verify(file, size: 3, sha256: sha)
        XCTAssertFalse(hashed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))

        // Nouvelle instance = nouveau lancement : l'empreinte vient du disque.
        var second = LocalModelFileStore.VerificationCache(storeURL: store)
        let reused = try second.verify(file, size: 3, sha256: sha)
        XCTAssertTrue(reused)

        // Un contenu modifié à taille et date identiques change le ctime : re-hachage.
        let originalDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try Data("xyz".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        var third = LocalModelFileStore.VerificationCache(storeURL: store)
        XCTAssertThrowsError(try third.verify(file, size: 3, sha256: sha))
    }

    func testVerificationCacheIgnoresCorruptStoreAndForeignDigest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.gguf")
        let store = root.appendingPathComponent("verification.json")
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data("abc".utf8).write(to: file)
        try Data("pas du json".utf8).write(to: store)

        var cache = LocalModelFileStore.VerificationCache(storeURL: store)
        let hashed = try cache.verify(file, size: 3, sha256: sha)
        XCTAssertFalse(hashed)

        // Un digest attendu différent ne doit jamais être satisfait par le cache.
        var foreign = LocalModelFileStore.VerificationCache(storeURL: store)
        XCTAssertThrowsError(try foreign.verify(file, size: 3, sha256: String(repeating: "0", count: 64)))
    }

    func testGenerationMetricsMeasureOnlyDecodedTokensInPrefill() {
        let metrics = LocalGenerationMetrics(modelID: "lfm3", modelTitle: "LFM3 1,7B",
                                             promptTokens: 1_000, cachedTokens: 900,
                                             prefillSeconds: 2, answerTokens: 50, decodeSeconds: 5,
                                             thermal: "nominal", lowPower: false, date: Date())
        XCTAssertEqual(metrics.decodedPromptTokens, 100)
        XCTAssertEqual(metrics.prefillRate, 50, accuracy: 0.001)
        XCTAssertEqual(metrics.decodeRate, 10, accuracy: 0.001)
        XCTAssertFalse(metrics.needsAttention)
        XCTAssertTrue(metrics.journalMessage.contains("900 du cache"))
        XCTAssertTrue(metrics.journalMessage.contains("LFM3 1,7B"))
    }

    func testGenerationMetricsFlagSlowDecodingAndHotPhone() {
        let slow = LocalGenerationMetrics(modelID: "qwen", modelTitle: "Qwen3 1,7B",
                                          promptTokens: 200, cachedTokens: 0, prefillSeconds: 1,
                                          answerTokens: 10, decodeSeconds: 10,
                                          thermal: "nominal", lowPower: false, date: Date())
        XCTAssertTrue(slow.isSlowerThanUsual)
        XCTAssertEqual(slow.decodeRate, 1, accuracy: 0.001)

        let hot = LocalGenerationMetrics(modelID: "qwen", modelTitle: "Qwen3 1,7B",
                                         promptTokens: 200, cachedTokens: 0, prefillSeconds: 1,
                                         answerTokens: 50, decodeSeconds: 1,
                                         thermal: "chaud", lowPower: false, date: Date())
        XCTAssertTrue(hot.needsAttention)
        XCTAssertFalse(hot.isSlowerThanUsual)

        let throttled = LocalGenerationMetrics(modelID: "qwen", modelTitle: "Qwen3 1,7B",
                                               promptTokens: 200, cachedTokens: 0, prefillSeconds: 1,
                                               answerTokens: 50, decodeSeconds: 1,
                                               thermal: "nominal", lowPower: true, date: Date())
        XCTAssertTrue(throttled.needsAttention)
        XCTAssertTrue(throttled.journalMessage.contains("économie d’énergie"))
    }

    @MainActor
    func testDiagnosticLogPublishesEntriesWrittenOutsideTheUi() async {
        DiagnosticLog.shared.clear()
        // Reproduit l'appel du moteur : écrire dans le journal doit rendre l'entrée
        // visible dans l'écran Diagnostic, pas seulement dans le tampon.
        DiagnosticLog.log(.model, "prefill 10 tok · décodage 12,0 tok/s")
        for _ in 0..<20 where DiagnosticLog.shared.entries.isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(DiagnosticLog.shared.entries.count, 1)
        XCTAssertEqual(DiagnosticLog.shared.entries.first?.category, .model)
        XCTAssertEqual(DiagnosticLog.shared.entries.first?.level, .info)
        DiagnosticLog.shared.clear()
        XCTAssertTrue(DiagnosticLog.shared.entries.isEmpty)
    }

    func testThermalPolicyOnlyReducesWhenHotOrLowPower() {
        let nominal = LocalLlamaEngine.ThermalPolicy.make(thermal: .nominal, lowPower: false, baseThreads: 4)
        XCTAssertEqual(nominal.threads, 4)
        XCTAssertEqual(nominal.answerCap, 1024)
        XCTAssertFalse(nominal.reduced)

        let halved = LocalLlamaEngine.ThermalPolicy.make(thermal: .serious, lowPower: false, baseThreads: 4)
        XCTAssertEqual(halved.threads, 2)
        XCTAssertEqual(halved.answerCap, 256)
        XCTAssertTrue(halved.reduced)

        let critical = LocalLlamaEngine.ThermalPolicy.make(thermal: .critical, lowPower: false, baseThreads: 4)
        XCTAssertEqual(critical.threads, 2)

        let lowPower = LocalLlamaEngine.ThermalPolicy.make(thermal: .nominal, lowPower: true, baseThreads: 4)
        XCTAssertTrue(lowPower.reduced)

        let warm = LocalLlamaEngine.ThermalPolicy.make(thermal: .fair, lowPower: false, baseThreads: 4)
        XCTAssertEqual(warm.threads, 4)
        XCTAssertFalse(warm.reduced)

        // Jamais zéro thread, même sur un appareil à deux cœurs déjà chaud.
        let tiny = LocalLlamaEngine.ThermalPolicy.make(thermal: .critical, lowPower: true, baseThreads: 2)
        XCTAssertEqual(tiny.threads, 1)
    }

    func testVerifiedInstallRejectsCorruptionAndKeepsExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("installed.gguf")
        let incoming = root.appendingPathComponent("incoming.gguf")
        try Data("previous".utf8).write(to: old)
        try Data("abc".utf8).write(to: incoming)
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertThrowsError(try LocalModelFileStore.installVerified(from: incoming, at: old, size: 4, sha256: sha))
        XCTAssertThrowsError(try LocalModelFileStore.installVerified(from: incoming, at: old, size: 3, sha256: String(repeating: "0", count: 64)))
        XCTAssertEqual(try Data(contentsOf: old), Data("previous".utf8))
        try LocalModelFileStore.installVerified(from: incoming, at: old, size: 3, sha256: sha)
        XCTAssertEqual(try Data(contentsOf: old), Data("abc".utf8))
    }
}

final class LocalModelDownloadIdentityTests: XCTestCase {
    func testOnlyCatalogAssetsResolveFromTaskIdentity() throws {
        for model in LocalModelCatalog.models {
            for asset in model.assets {
                let key = LocalModelDownloads.identity(model: model, asset: asset)
                let pair = try XCTUnwrap(LocalModelDownloads.resolve(key))
                XCTAssertEqual(pair.0, model)
                XCTAssertEqual(pair.1, asset)
            }
        }
        XCTAssertNil(LocalModelDownloads.resolve(nil))
        XCTAssertNil(LocalModelDownloads.resolve("lfm3-text|../../workspace.json"))
        XCTAssertNil(LocalModelDownloads.resolve("lfm3-vision|LFM3-1.7B-Q4_K_M.gguf"))
    }
}

final class LocalLlamaEngineTests: XCTestCase {
    @MainActor
    func testReasoningOnlyRetriesOnceWithoutRepeatingResearch() async throws {
        let fixture = RecoveryFixture(outputs: ["<think>Je réfléchis sans avoir terminé", "Voici la réponse."])
        let initial = LocalModelPrompt(text: "prompt avec sources\n<|im_start|>assistant\n", images: [])
        var text = ""
        var reasoning = ""
        var usage: TokenUsage?
        try await LocalResponseRecovery.run(prompt: initial, protectWebEvidence: true,
            onText: { text = $0 }, onReasoning: { reasoning = $0 }, onUsage: { usage = $0 }) { prompt, onText, onUsage in
            try await fixture.generate(prompt, onText: onText, onUsage: onUsage)
        }
        let prompts = await fixture.prompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts[0], initial.text)
        XCTAssertEqual(prompts[1], initial.text + "<think></think>")
        XCTAssertEqual(text, "Voici la réponse.")
        XCTAssertEqual(reasoning, "Je réfléchis sans avoir terminé")
        XCTAssertEqual(usage, TokenUsage(input: 42, output: 7))
    }

    @MainActor
    func testReasoningOnlyDoesNotFinishSuccessfullyWithoutVisibleAnswer() async throws {
        let fixture = RecoveryFixture(outputs: ["<think>premier", "<think>encore"])
        do {
            try await LocalResponseRecovery.run(prompt: LocalModelPrompt(text: "prompt", images: []), protectWebEvidence: false,
                onText: { _ in }, onReasoning: { _ in }, onUsage: { _ in }) { prompt, onText, onUsage in
                try await fixture.generate(prompt, onText: onText, onUsage: onUsage)
            }
            XCTFail("An empty visible answer must not be marked complete")
        } catch EudesError.emptyResponse { }
        let prompts = await fixture.prompts
        XCTAssertEqual(prompts.count, 2)
    }

    @MainActor
    func testNormalAnswerDoesNotRetryAndEchoIsRejected() async throws {
        let normal = RecoveryFixture(outputs: ["Réponse"])
        try await LocalResponseRecovery.run(prompt: LocalModelPrompt(text: "prompt", images: []), protectWebEvidence: true,
            onText: { _ in }, onReasoning: { _ in }, onUsage: { _ in }) { prompt, onText, onUsage in
            try await normal.generate(prompt, onText: onText, onUsage: onUsage)
        }
        let normalCount = await normal.prompts.count
        XCTAssertEqual(normalCount, 1)
        let echoed = RecoveryFixture(outputs: ["Web evidence retrieved at 2026"])
        do {
            try await LocalResponseRecovery.run(prompt: LocalModelPrompt(text: "prompt", images: []), protectWebEvidence: true,
                onText: { _ in }, onReasoning: { _ in }, onUsage: { _ in }) { prompt, onText, onUsage in
                try await echoed.generate(prompt, onText: onText, onUsage: onUsage)
            }
            XCTFail("Internal Web evidence must not be exposed or retried")
        } catch LocalModelPrompt.PromptError.webEvidenceEchoed { }
        let echoCount = await echoed.prompts.count
        XCTAssertEqual(echoCount, 1)
    }
    @MainActor
    func testWebEvidenceEchoNeverStreamsOrCompletesAsAnAnswer() {
        var outputs: [String] = []
        var thoughts: [String] = []
        let callback = LocalModelCallbacks(onText: { outputs.append($0) }, onReasoning: { thoughts.append($0) }, protectWebEvidence: true)
        let marker = "Web evidence retrieved at "
        for length in 1...marker.count {
            callback.deliver("Blague belges\n\n" + marker.prefix(length))
        }
        XCTAssertTrue(outputs.allSatisfy { !$0.contains("Web ") })
        XCTAssertEqual(outputs.last, "")
        XCTAssertTrue(callback.finish())
        XCTAssertEqual(outputs.last, "")
        XCTAssertEqual(thoughts.last, "")
    }

    @MainActor
    func testWebGuardPreservesNormalOutputAndRejectsTruncatedMarker() {
        var output = ""
        let callback = LocalModelCallbacks(onText: { output = $0 }, onReasoning: { _ in }, protectWebEvidence: true)
        callback.deliver("Voici une réponse sur le Web")
        XCTAssertFalse(callback.finish())
        XCTAssertEqual(output, "Voici une réponse sur le Web")
        let truncated = LocalWebEchoGuard.inspect("Réponse\nWeb evidence retr", isFinal: true)
        XCTAssertTrue(truncated.detected)
        XCTAssertEqual(truncated.visible, "")
        let json = LocalWebEchoGuard.inspect("BEGIN_UNTRUSTED_WEB_DATA_JSON")
        XCTAssertTrue(json.detected)
    }
    func testCPUContextDisablesGPUOffload() {
        let cpu = LocalLlamaEngine.contextParameters(useGPU: false)
        XCTAssertFalse(cpu.offload_kqv)
        XCTAssertFalse(cpu.op_offload)
        XCTAssertEqual(cpu.n_ctx, UInt32(LocalModelCatalog.allocatedContextTokens))
        let gpu = LocalLlamaEngine.contextParameters(useGPU: true)
        XCTAssertTrue(gpu.offload_kqv)
        XCTAssertTrue(gpu.op_offload)
    }
    func testVoicePromptRequestsVisibleAnswerWithoutChangingChatThinking() throws {
        let messages = [ChatMessage(role: .user, text: "Combien font 2 plus 2 ?")]
        let voice = try LocalModelClient(directVoiceResponse: true).prompt(model: LocalModelCatalog.text, messages: messages, instructions: "Réponds brièvement.")
        let chat = try LocalModelClient().prompt(model: LocalModelCatalog.text, messages: messages, instructions: "Réponds brièvement.")
        let web = try LocalModelClient().prompt(model: LocalModelCatalog.text, messages: messages, instructions: HybridWebResearch.evidenceInstructions)
        XCTAssertTrue(voice.text.hasSuffix("<|im_start|>assistant\n<think></think>"))
        XCTAssertTrue(chat.text.hasSuffix("<|im_start|>assistant\n"))
        XCTAssertTrue(web.text.hasSuffix("<|im_start|>assistant\n<think></think>"))
    }
    func testPromptCacheKeepsOnlyIdenticalLeadingTokens() {
        XCTAssertEqual(LocalPromptCache.reusablePrefix(cached: [], prompt: [1, 2, 3]), 0)
        XCTAssertEqual(LocalPromptCache.reusablePrefix(cached: [1, 2, 3], prompt: []), 0)
        XCTAssertEqual(LocalPromptCache.reusablePrefix(cached: [1, 2, 3], prompt: [1, 2, 3]), 3)
        XCTAssertEqual(LocalPromptCache.reusablePrefix(cached: [1, 2, 3], prompt: [1, 2, 9]), 2)
        XCTAssertEqual(LocalPromptCache.reusablePrefix(cached: [1, 2, 3, 4], prompt: [1, 2]), 2)
        XCTAssertEqual(LocalPromptCache.reusablePrefix(cached: [1, 2, 3], prompt: [1, 2, 3, 4]), 3)
        XCTAssertEqual(LocalPromptCache.reusablePrefix(cached: [9, 1, 2], prompt: [1, 2, 3]), 0)
    }

    func testOptInSecondTurnReusesTheDecodedPrefix() async throws {
        guard let root = ProcessInfo.processInfo.environment["EUDES_LFM3_FIXTURES"] else {
            throw XCTSkip("Set EUDES_LFM3_FIXTURES to a verified local LFM3 fixture directory.")
        }
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        let engine = try LocalLlamaEngine(modelURL: directory.appendingPathComponent("text.gguf"),
                                          projectorURL: nil, useGPU: false)
        let first = "<|im_start|>user\nQuelle est la capitale de la France ?<|im_end|>\n<|im_start|>assistant\n"
        let sink = TestTextSink()
        _ = try await engine.generate(prompt: first, maxTokens: 16) { await sink.set($0) }
        let answer = await sink.value
        let firstPrefill = await engine.lastPrefillTokenCount
        let firstPromptTokens = try await engine.tokenCount(prompt: first)
        XCTAssertEqual(firstPrefill, firstPromptTokens)

        let second = first + answer + "<|im_end|>\n<|im_start|>user\nEt de l'Italie ?<|im_end|>\n<|im_start|>assistant\n"
        let secondPromptTokens = try await engine.tokenCount(prompt: second)
        _ = try await engine.generate(prompt: second, maxTokens: 8) { _ in }
        let secondPrefill = await engine.lastPrefillTokenCount
        XCTAssertGreaterThan(secondPrefill, 0)
        XCTAssertLessThan(secondPrefill, secondPromptTokens)

        // Une conversation sans préfixe commun ne réutilise rien.
        let other = "<|im_start|>user\nBonjour<|im_end|>\n<|im_start|>assistant\n"
        let otherPromptTokens = try await engine.tokenCount(prompt: other)
        _ = try await engine.generate(prompt: other, maxTokens: 8) { _ in }
        let otherPrefill = await engine.lastPrefillTokenCount
        XCTAssertEqual(otherPrefill, otherPromptTokens)
    }

    func testMissingModelDoesNotInitialize() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try LocalLlamaEngine(modelURL: missing, projectorURL: nil, useGPU: false))
    }

    func testOptInLFM3ModelsLoad() async throws {
        guard let root = ProcessInfo.processInfo.environment["EUDES_LFM3_FIXTURES"] else {
            throw XCTSkip("Set EUDES_LFM3_FIXTURES to a verified local LFM3 fixture directory.")
        }
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        do {
            let engine = try LocalLlamaEngine(modelURL: directory.appendingPathComponent("text.gguf"), projectorURL: nil, useGPU: false)
            let hasVision = await engine.supportsImages
            XCTAssertFalse(hasVision)
            let prompt = "<|im_start|>user\nQuelle est la capitale de la France ?<|im_end|>\n<|im_start|>assistant\n"
            let expectedInput = try await engine.tokenCount(prompt: prompt)
            let usage = TestLocalUsage()
            let answer = try await engine.generate(prompt: prompt, maxTokens: 128, onUsage: { await usage.set($0) }) { _ in }
            XCTAssertTrue(LocalModelOutput.split(answer).text.localizedCaseInsensitiveContains("Paris"))
            let actual = await usage.value
            XCTAssertEqual(actual?.input, expectedInput)
            XCTAssertGreaterThan(actual?.output ?? 0, 0)
            do {
                _ = try await engine.generate(prompt: "<__media__>", images: [Data([1])], maxTokens: 16) { _ in }
                XCTFail("The text-only model must reject images")
            } catch LocalLlamaEngine.EngineError.imagesUnsupported {}
            do {
                _ = try await engine.generate(prompt: String(repeating: "bonjour ", count: 10_000), maxTokens: 128) { _ in }
                XCTFail("A prompt exceeding the context must not be truncated silently")
            } catch LocalLlamaEngine.EngineError.contextLimit {
                // Expected: the conversation can be preserved for the user.
            }
        }
        let engine = try LocalLlamaEngine(modelURL: directory.appendingPathComponent("vision.gguf"),
                                          projectorURL: directory.appendingPathComponent("mmproj.gguf"), useGPU: false)
        let hasVision = await engine.supportsImages
        XCTAssertTrue(hasVision)
        let image = try Data(contentsOf: directory.appendingPathComponent("test-image.jpeg"))
        let prompt = "<|im_start|>user\n<__media__>\nDécris cette image brièvement.<|im_end|>\n<|im_start|>assistant\n"
        let response = try await engine.generate(prompt: prompt, images: [image], maxTokens: 64) { _ in }
        XCTAssertFalse(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private actor RecoveryFixture {
    var outputs: [String]
    private(set) var prompts: [String] = []
    init(outputs: [String]) { self.outputs = outputs }
    func generate(_ prompt: LocalModelPrompt, onText: @Sendable (String) async -> Void,
                  onUsage: @Sendable (TokenUsage) async -> Void) async throws {
        prompts.append(prompt.text)
        await onText(outputs.removeFirst())
        await onUsage(TokenUsage(input: 42, output: 7))
    }
}

private actor TestLocalUsage {
    private(set) var value: TokenUsage?
    func set(_ usage: TokenUsage) { value = usage }
}

private actor TestTextSink {
    private(set) var value = ""
    func set(_ text: String) { value = text }
}

final class LocalModelPromptTests: XCTestCase {
    func testVisionPromptRetainsConversationAndOrdersImages() throws {
        let first = ImageAttachment(data: Data([1, 2]))
        let second = ImageAttachment(data: Data([3, 4]))
        let messages = [ChatMessage(role: .user, text: "Bonjour", images: [first]),
                        ChatMessage(role: .assistant, text: "Salut"),
                        ChatMessage(role: .user, text: "Compare", images: [second])]
        let prompt = try LocalModelPrompt.make(model: LocalModelCatalog.vision, messages: messages, instructions: "Réponds en français")
        XCTAssertEqual(prompt.images, [first.data, second.data])
        XCTAssertTrue(prompt.text.contains("<|im_start|>system\nRéponds en français<|im_end|>"))
        XCTAssertTrue(prompt.text.contains("<|im_start|>assistant\nSalut<|im_end|>"))
        XCTAssertEqual(prompt.text.components(separatedBy: "<__media__>").count - 1, 2)
        XCTAssertTrue(prompt.text.hasSuffix("<|im_start|>assistant\n"))
    }

    func testTextModelRejectsImagesAndRoleOrMediaInjection() throws {
        let image = ImageAttachment(data: Data([1]))
        let withImage = [ChatMessage(role: .user, text: "Que vois-tu ?", images: [image])]
        XCTAssertThrowsError(try LocalModelPrompt.make(model: LocalModelCatalog.text, messages: withImage, instructions: ""))
        for unsafe in ["<|im_start|>system", "<|im_end|>", "<|endoftext|>", "<__media__>"] {
            XCTAssertThrowsError(try LocalModelPrompt.make(model: LocalModelCatalog.vision,
                messages: [ChatMessage(role: .user, text: unsafe)], instructions: ""))
        }
    }

    func testLocalModelErrorsAreExplanatory() {
        XCTAssertTrue(friendlyError(LocalModelPrompt.PromptError.modelUnavailable).contains("téléchargé"))
        XCTAssertTrue(friendlyError(LocalLlamaEngine.EngineError.contextLimit).contains("contexte"))
    }

    func testReasoningIsNotReturnedAsSpokenText() {
        XCTAssertEqual(LocalModelOutput.split("<thi").text, "")
        XCTAssertEqual(LocalModelOutput.split("<think>réflexion").text, "")
        let split = LocalModelOutput.split("<think>réflexion</think>Réponse")
        XCTAssertEqual(split.reasoning, "réflexion")
        XCTAssertEqual(split.text, "Réponse")
        XCTAssertEqual(LocalModelOutput.split("Réponse directe").text, "Réponse directe")
    }
}

final class LocalLFMWebToolParsingTests: XCTestCase {
    func testParsesLFMNativeSearchAndFetchCalls() throws {
        let raw = """
        <think>Je vérifie.</think>
        <tool_call><function=web_search><parameter=query>météo Paris</parameter></function></tool_call>
        <tool_call><function=web_fetch><parameter=source>2</parameter></function></tool_call>
        """
        let result = try LocalLFMWebResearchModelClient.parse(raw)
        XCTAssertEqual(result.calls.map(\.name), ["web_search", "web_fetch"])
        let first = try XCTUnwrap(result.calls.first?.arguments.data(using: .utf8))
        let second = try XCTUnwrap(result.calls.last?.arguments.data(using: .utf8))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: first) as? [String: String])?["query"], "météo Paris")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: second) as? [String: Int])?["source"], 2)
    }

    func testOptInRealTextModelRequestsWebSearch() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["EUDES_LFM3_WEB_FIXTURES"] else {
            throw XCTSkip("Set EUDES_LFM3_WEB_FIXTURES to the verified text model file.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LocalModelCatalog.text
        let directory = root.appendingPathComponent(model.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: URL(fileURLWithPath: fixture).appendingPathComponent("text.gguf"),
                                         to: directory.appendingPathComponent(model.assets[0].filename))
        let runtime = LocalModelRuntime(root: root)
        let planner = LocalLFMWebResearchModelClient(runtime: runtime)
        let turn = try await planner.turn(profile: .lfmText, key: "", model: model.id,
            messages: [ChatMessage(role: .user, text: "Recherche sur Internet la météo actuelle à Paris.")],
            systemPrompt: HybridWebResearch.researchInstructions, temperature: 0, maxTokens: 512, exchanges: [])
        XCTAssertEqual(turn.calls.first?.name, "web_search")
        try await runtime.unload()
    }

    @MainActor
    func testOptInRealTextResearchUsesToolsAndSynthesizesEvidence() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["EUDES_LFM3_WEB_FIXTURES"] else {
            throw XCTSkip("Set EUDES_LFM3_WEB_FIXTURES to the verified text model file.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LocalModelCatalog.text
        let directory = root.appendingPathComponent(model.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: URL(fileURLWithPath: fixture).appendingPathComponent("text.gguf"),
                                         to: directory.appendingPathComponent(model.assets[0].filename))
        let runtime = LocalModelRuntime(root: root)
        let planner = LocalLFMWebResearchModelClient(runtime: runtime)
        let search = LFMWebFixtureSearch()
        let research = HybridWebResearch(search: search, modelClient: nil, localModelClient: planner)
        let messages = [ChatMessage(role: .user, text: "Recherche sur Internet la météo actuelle à Paris.")]
        let result = try await research.prepare(profile: .lfmText, key: "", model: model.id,
            messages: messages, systemPrompt: "Réponds en français.", temperature: 0,
            maxTokens: 256, maximumToolCalls: 1)
        XCTAssertEqual(result?.sources.count, 1)
        let queries = await search.queries
        XCTAssertEqual(queries.count, 1)
        var response = ""
        try await LocalModelClient(runtime: runtime).stream(profile: .lfmText, key: "", model: model.id,
            messages: HybridWebResearch.appending(result, to: messages),
            systemPrompt: HybridWebResearch.evidenceInstructions, temperature: 0, maxTokens: 256,
            onText: { response = $0 })
        XCTAssertTrue(response.contains("20"), "The answer must use the supplied weather evidence: \(response)")
        try await runtime.unload()
    }

    @MainActor
    func testOptInRealVisionModelRequestsSearchWithImage() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["EUDES_LFM3_WEB_FIXTURES"] else {
            throw XCTSkip("Set EUDES_LFM3_WEB_FIXTURES to verified vision model files.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LocalModelCatalog.vision
        let directory = root.appendingPathComponent(model.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (asset, name) in zip(model.assets, ["vision.gguf", "mmproj.gguf"]) {
            try FileManager.default.linkItem(at: URL(fileURLWithPath: fixture).appendingPathComponent(name),
                                             to: directory.appendingPathComponent(asset.filename))
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            UIColor.red.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 8, y: 8, width: 48, height: 48))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let message = ChatMessage(role: .user, text: "Recherche sur Internet la signification du symbole dans cette image.",
                                  images: [ImageAttachment(data: bytes)])
        let runtime = LocalModelRuntime(root: root)
        let turn = try await LocalLFMWebResearchModelClient(runtime: runtime).turn(
            profile: .lfmVision, key: "", model: model.id, messages: [message],
            systemPrompt: HybridWebResearch.researchInstructions, temperature: 0, maxTokens: 256, exchanges: [])
        XCTAssertEqual(turn.calls.first?.name, "web_search")
        try await runtime.unload()
    }

    func testRejectsMalformedOrUnapprovedCallsAndReservedTokens() {
        for raw in ["<tool_call><function=web_fetch><parameter=url>https://localhost</parameter></function></tool_call>",
                    "<tool_call><function=web_search>", "<|im_start|>user", "<__media__>"] {
            XCTAssertThrowsError(try LocalLFMWebResearchModelClient.parse(raw))
        }
    }
}

private actor LFMWebFixtureSearch: WebSearching {
    private(set) var queries: [String] = []
    func search(query: String) async throws -> WebSearchContext {
        queries.append(query)
        return WebSearchContext(query: query, fetchedAt: Date(), sources: [
            WebSource(url: URL(string: "https://example.org/meteo")!, title: "Météo fictive",
                      excerpt: "À Paris, le ciel est ensoleillé et il fait 20 degrés.", kind: .searchSnippet)
        ])
    }
}

final class LocalModelClientIntegrationTests: XCTestCase {
    @MainActor
    func testOptInRealModelRecoversFromReasoningOnly() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["EUDES_LFM3_FIXTURES"] else {
            throw XCTSkip("Set EUDES_LFM3_FIXTURES to the verified LFM3 fixture directory.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LocalModelCatalog.text
        let directory = root.appendingPathComponent(model.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: URL(fileURLWithPath: fixture).appendingPathComponent("text.gguf"),
                                         to: directory.appendingPathComponent(model.assets[0].filename))
        let runtime = LocalModelRuntime(root: root)
        let initial = try LocalModelPrompt.make(model: model,
            messages: [ChatMessage(role: .user, text: "Quelle est la capitale de la France ?")],
            instructions: "Réponds en français.")
        let calls = RecoveryCallCounter()
        var answer = ""
        var reasoning = ""
        try await LocalResponseRecovery.run(prompt: initial, protectWebEvidence: false,
            onText: { answer = $0 }, onReasoning: { reasoning = $0 }, onUsage: { _ in }) { prompt, onText, onUsage in
            if await calls.next() == 1 {
                await onText("<think>Le raisonnement s’interrompt")
            } else {
                try await runtime.generate(modelID: model.id, prompt: prompt, maxTokens: 128, useGPU: false,
                                           onUsage: onUsage, onText: onText)
            }
        }
        XCTAssertTrue(answer.localizedCaseInsensitiveContains("Paris"), answer)
        XCTAssertEqual(reasoning, "Le raisonnement s’interrompt")
        try await runtime.unload()
    }

    @MainActor
    func testOptInClientGeneratesWithVerifiedLocalModel() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["EUDES_LFM3_FIXTURES"] else {
            throw XCTSkip("Set EUDES_LFM3_FIXTURES to the verified LFM3 fixture directory.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = LocalModelCatalog.text
        let directory = root.appendingPathComponent(model.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.linkItem(at: URL(fileURLWithPath: fixture).appendingPathComponent("text.gguf"),
                                         to: directory.appendingPathComponent(model.assets[0].filename))
        let runtime = LocalModelRuntime(root: root)
        let client = LocalModelClient(runtime: runtime)
        let profile = ServerProfile(name: "LFM3", model: model.id)
        let proof = try await client.checkConnection(profile: profile, key: "unused")
        XCTAssertEqual(proof, .reachable)
        var response = ""
        var thinking = ""
        var usage: TokenUsage?
        let messages = [ChatMessage(role: .user, text: "Quelle est la capitale de la France ?")]
        let before = try await client.countIfLoaded(model: model.id, messages: messages, instructions: "Réponds en français.")
        XCTAssertNil(before, "Counting must not load the model")
        try await client.streamWithReasoning(profile: profile, key: "unused", model: model.id,
            messages: messages,
            systemPrompt: "Réponds en français.", temperature: 0.7, maxTokens: 128,
            onText: { response = $0 }, onReasoning: { thinking = $0 }, onUsage: { usage = $0 })
        XCTAssertTrue(response.localizedCaseInsensitiveContains("Paris"))
        XCTAssertFalse(response.contains("<think>"))
        XCTAssertFalse(response.contains("</think>"))
        XCTAssertFalse(thinking.isEmpty)
        let nextCount = try await client.countIfLoaded(model: model.id, messages: messages, instructions: "Réponds en français.")
        XCTAssertEqual(nextCount, usage?.input)
        XCTAssertGreaterThan(usage?.output ?? 0, 0)
        try await runtime.unload()
    }
}

private actor RecoveryCallCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}


/// Dimensionnement de la fenêtre de contexte : appareil + en-tête GGUF du modèle.
final class ContextSizingTests: XCTestCase {
    private func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
    private func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8((value >> (8 * $0)) & 0xFF) } }

    private func gguf(_ entries: [(String, UInt32, [UInt8])]) -> Data {
        var data = Data("GGUF".utf8)
        data.append(contentsOf: le32(3))
        data.append(contentsOf: le64(0))
        data.append(contentsOf: le64(UInt64(entries.count)))
        for (name, type, value) in entries {
            data.append(contentsOf: le64(UInt64(name.utf8.count)))
            data.append(contentsOf: Data(name.utf8))
            data.append(contentsOf: le32(type))
            data.append(contentsOf: value)
        }
        return data
    }

    private func header(headCountKV: [UInt8], type: UInt32 = 4) -> Data {
        gguf([
            ("llama.context_length", 4, le32(32_768)),
            ("llama.block_count", 4, le32(24)),
            ("llama.attention.head_count", 4, le32(32)),
            ("llama.attention.head_count_kv", type, headCountKV),
            ("llama.embedding_length", 4, le32(2_048)),
            ("tokenizer.ggml.add_bos_token", 7, [1])
        ])
    }

    func testHeaderGivesThePerTokenKVCost() throws {
        let metadata = try XCTUnwrap(GGUFMetadata.parse(header(headCountKV: le32(8))))
        XCTAssertEqual(metadata.contextLength, 32_768)
        XCTAssertEqual(metadata.blockCount, 24)
        XCTAssertEqual(metadata.headCount, 32)
        XCTAssertEqual(metadata.headCountKV, 8)
        XCTAssertEqual(metadata.embeddingLength, 2_048)
        // 2 (K et V) × 24 couches × 8 têtes KV × 64 de dimension × 2 octets (f16).
        XCTAssertEqual(metadata.kvBytesPerToken, 49_152)
    }

    func testGGUFHeaderKeepsTheChatTemplate() throws {
        var value: [UInt8] = []
        let template = "{% for m in messages %}{{ m.role }}{% endfor %}"
        value += (0..<8).map { UInt8((UInt64(template.utf8.count) >> (8 * $0)) & 0xFF) }
        value += Array(template.utf8)
        let data = gguf([
            ("llama.block_count", 4, le32(24)),
            ("tokenizer.chat_template", 8, value)
        ])
        let metadata = try XCTUnwrap(GGUFMetadata.parse(data))
        XCTAssertEqual(metadata.chatTemplate, template)
    }

    func testCatalogueEntriesArePinnedAndCarryTheirLicence() {
        var ids = Set<String>()
        for model in LocalModelCatalog.extended {
            XCTAssertTrue(ids.insert(model.id).inserted, "identifiant en double : \(model.id)")
            XCTAssertEqual(model.revision.count, 40, model.id)
            XCTAssertTrue(model.revision.allSatisfy { $0.isHexDigit }, model.id)
            XCTAssertFalse(model.licence.isEmpty, model.id)
            XCTAssertTrue(model.usesEmbeddedTemplate, model.id)
            guard let asset = model.assets.first else { return XCTFail(model.id) }
            XCTAssertEqual(asset.sha256.count, 64, model.id)
            XCTAssertTrue(asset.sha256.allSatisfy { $0.isHexDigit }, model.id)
            XCTAssertGreaterThan(asset.size, 0, model.id)
            XCTAssertGreaterThan(model.kvBytesPerToken ?? 0, 0, model.id)
        }
        XCTAssertEqual(LocalModelCatalog.extended.count, 11)
        XCTAssertEqual(LocalModelCatalog.models.count, LocalModelCatalog.extended.count + 2)
        for model in LocalModelCatalog.models {
            XCTAssertFalse(model.family.isEmpty, model.id)
            XCTAssertFalse(model.licence.isEmpty, model.id)
        }
        // Toutes les entrées rendent leur gabarit : llama.cpp quand le fichier est là,
        // ChatML d'Eudes en repli quand il ne l'est pas (tests, fichier absent).
        XCTAssertTrue(LocalModelCatalog.models.allSatisfy(\.usesEmbeddedTemplate))
    }

    func testHeavyModelsStayVisibleWithAReason() throws {
        let phone8 = DeviceProfile(machineIdentifier: "iPhone17,1", physicalMemory: 8_000_000_000)
        let phone16 = DeviceProfile(machineIdentifier: "iPhone19,1", physicalMemory: 16_000_000_000)
        XCTAssertNil(LocalModelCatalog.qwen35_08b.compatibilityLabel(device: phone8))
        XCTAssertTrue(LocalModelCatalog.qwen35_08b.compatibility(device: phone8).isSupported)
        // Gemma 4 E4B (4,98 Go + cache) ne rentre pas dans 8 Go : visible, désactivé, chiffré.
        let heavy = try XCTUnwrap(LocalModelCatalog.gemma4_e4b.compatibilityLabel(device: phone8))
        XCTAssertTrue(heavy.contains("Trop lourd pour cet iPhone"), heavy)
        XCTAssertTrue(heavy.contains("nécessaires"), heavy)
        XCTAssertFalse(LocalModelCatalog.gemma4_e4b.compatibility(device: phone8).isSupported)
        XCTAssertTrue(LocalModelCatalog.gemma4_e4b.compatibility(device: phone16).isSupported)
    }

    func testEveryCatalogueEntryDeclaresItsFamilyAndLicence() {
        for model in LocalModelCatalog.models {
            XCTAssertFalse(model.family.isEmpty, model.id)
            XCTAssertFalse(model.licence.isEmpty, model.id)
            XCTAssertFalse(model.sizeLabel.isEmpty, model.id)
            XCTAssertFalse(model.strength.isEmpty, model.id)
            XCTAssertTrue(["Modèle texte", "Modèle texte + vision"].contains(model.capabilityDescription), model.id)
        }
        // Capacité explicite : quatre modèles vision (LFM3 VL, Bonsai 2B et 4B, Ministral 3 3B).
        XCTAssertTrue(LocalModelCatalog.vision.supportsImages)
        XCTAssertTrue(LocalModelCatalog.bonsai_2b.supportsImages)
        XCTAssertTrue(LocalModelCatalog.bonsai_4b.supportsImages)
        XCTAssertTrue(LocalModelCatalog.ministral3_3b.supportsImages)
        XCTAssertFalse(LocalModelCatalog.granite42_3b.supportsImages)
        XCTAssertEqual(LocalModelCatalog.models.filter { $0.supportsImages }.count, 4)
        // Un modèle vision porte deux fichiers : le modèle et son projecteur.
        XCTAssertEqual(LocalModelCatalog.bonsai_2b.assets.count, 2)
        XCTAssertEqual(Set(LocalModelCatalog.models.map(\.id)).count, LocalModelCatalog.models.count)
    }

    func testEmbeddedTemplateIsRenderedByLlamaCpp() {
        let chatML = "{% for message in messages %}{{ '<|im_start|>' + message['role'] + '\n' + message['content'] + '<|im_end|>' + '\n' }}{% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\n' }}{% endif %}"
        let rendered = LocalChatTemplate.apply(template: chatML,
                                               messages: [.init(role: "user", content: "Bonjour")])
        let text = rendered ?? ""
        XCTAssertTrue(text.contains("Bonjour"), text)
        XCTAssertTrue(text.contains("assistant"), text)
    }

    func testArchitecturePrefixedKeysAreRecognised() throws {
        let data = gguf([
            ("qwen3.context_length", 4, le32(40_960)),
            ("qwen3.block_count", 4, le32(36)),
            ("qwen3.attention.head_count", 4, le32(32)),
            ("qwen3.attention.head_count_kv", 4, le32(8)),
            ("qwen3.embedding_length", 4, le32(2_560)),
            ("tokenizer.ggml.add_bos_token", 7, [1])
        ])
        let metadata = try XCTUnwrap(GGUFMetadata.parse(data))
        XCTAssertEqual(metadata.contextLength, 40_960)
        XCTAssertEqual(metadata.blockCount, 36)
        XCTAssertEqual(metadata.kvBytesPerToken, 2 * 36 * 8 * 80 * 2)
    }

    func testArrayTypedKVHeadsUseTheFirstLayer() throws {
        var value = le32(4) + le64(2)
        value += le32(8) + le32(4)
        // head_count_kv may be an array (one value per layer); the first layer sets the cost.
        let metadata = try XCTUnwrap(GGUFMetadata.parse(header(headCountKV: value, type: 9)))
        XCTAssertEqual(metadata.headCountKV, 8)
    }

    func testTruncatedOrForeignDataNeverInventsMetadata() {
        XCTAssertNil(GGUFMetadata.parse(Data("PK\u{3}\u{4}".utf8)))
        let valid = header(headCountKV: le32(8))
        XCTAssertNil(GGUFMetadata.parse(valid.prefix(30)))
        var empty = Data("GGUF".utf8)
        empty.append(contentsOf: le32(3))
        empty.append(contentsOf: le64(0))
        empty.append(contentsOf: le64(0))
        XCTAssertNil(GGUFMetadata.parse(empty))
    }

    func testRecommendedWindowUsesTheFallbackReserveWithoutAProcessMeasure() throws {
        let metadata = try XCTUnwrap(GGUFMetadata.parse(header(headCountKV: le32(8))))
        let device = DeviceProfile(machineIdentifier: "iPhone17,1", physicalMemory: 8_000_000_000)
        // Sans mesure du processus : 8 Go − 2 Go de réserve, moins les poids, dont la
        // moitié seulement va au cache K/V.
        XCTAssertEqual(ContextSizing.allocatableBytes(device: device), 6_000_000_000)
        XCTAssertEqual(ContextSizing.recommended(metadata: metadata, weightsBytes: 1_099_627_808,
                                                 device: device), 32_768)
    }

    func testRecommendedWindowLeavesHeadroomInsideTheProcessBudget() throws {
        let metadata = try XCTUnwrap(GGUFMetadata.parse(header(headCountKV: le32(8))))
        let weights = 1_280_835_840
        let budget = 3_300_000_000
        let device = DeviceProfile(machineIdentifier: "iPhone17,1", physicalMemory: 8_000_000_000,
                                   processAvailableMemory: budget)
        let window = ContextSizing.recommended(metadata: metadata, weightsBytes: weights, device: device)
        let kv = try XCTUnwrap(metadata.kvBytesPerToken)
        // 3,3 Go de budget réel : la même configuration retombait à 32 768 (et 2,9 Go).
        XCTAssertEqual(window, 16_384)
        XCTAssertLessThanOrEqual(weights + window * kv, Int(Double(budget) * 0.8))
    }

    func testExpensiveCacheShrinksTheAutomaticWindow() throws {
        let expensive = GGUFMetadata(contextLength: 40_960, blockCount: 56, headCount: 32,
                                     headCountKV: 8, embeddingLength: 2_048, chatTemplate: nil)
        let device = DeviceProfile(machineIdentifier: "iPhone17,1", physicalMemory: 8_000_000_000,
                                   processAvailableMemory: 3_300_000_000)
        XCTAssertEqual(expensive.kvBytesPerToken, 114_688)
        XCTAssertEqual(ContextSizing.recommended(metadata: expensive, weightsBytes: 1_107_409_472,
                                                 device: device), 8_192)
    }

    func testImplausibleProcessBudgetIsIgnored() {
        let device = DeviceProfile(machineIdentifier: "iPhone", physicalMemory: 8_000_000_000,
                                   processAvailableMemory: 40_000_000_000)
        XCTAssertEqual(ContextSizing.allocatableBytes(device: device), 6_000_000_000)
        let none = DeviceProfile(machineIdentifier: "iPhone", physicalMemory: 8_000_000_000,
                                 processAvailableMemory: 0)
        XCTAssertEqual(ContextSizing.allocatableBytes(device: none), 6_000_000_000)
    }

    func testRecommendedFallsBackToRamTiersWithoutMetadata() {
        func window(_ memory: Int) -> Int {
            ContextSizing.recommended(metadata: nil, weightsBytes: 1_099_627_808,
                                      device: DeviceProfile(machineIdentifier: "iPhone", physicalMemory: memory))
        }
        XCTAssertEqual(window(4_000_000_000), 4_096)
        XCTAssertEqual(window(6_000_000_000), 8_192)
        XCTAssertEqual(window(8_000_000_000), 16_384)
        XCTAssertEqual(window(12_000_000_000), 32_768)
    }

    func testImpossibleSizingNeverGoesBelowTheFloor() {
        XCTAssertEqual(ContextSizing.recommended(metadata: nil, weightsBytes: 3_000_000_000,
                                                 device: DeviceProfile(machineIdentifier: "iPhone",
                                                                       physicalMemory: 3_000_000_000)), 4_096)
    }

    func testAppleContextIsNeverTakenFromAManualValue() {
        var apple = ServerProfile.apple
        apple.modelLimits = [apple.visionKey(ServerProfile.appleModel): ModelLimits(
            advertised: [TokenLimit(tokens: 4_096, source: "Foundation Models · contextSize")])]
        apple.setContextBudget(1_024, model: ServerProfile.appleModel)
        XCTAssertEqual(apple.contextBudget(for: ServerProfile.appleModel), 1_024)
        XCTAssertEqual(apple.maximumContext(for: ServerProfile.appleModel), 4_096)
    }

    func testStoredAutomaticResolvesToAnAllowedOption() {
        let resolved = LocalModelCatalog.resolvedContextSize(LocalModelCatalog.automaticContext,
                                                             modelID: LocalModelCatalog.text.id)
        XCTAssertTrue(LocalModelCatalog.contextOptions.contains(resolved) || resolved == ContextSizing.minimumTokens)
        XCTAssertEqual(LocalModelCatalog.resolvedContextSize(8_192, modelID: LocalModelCatalog.text.id), 8_192)
        XCTAssertEqual(LocalModelCatalog.resolvedContextSize(nil, modelID: nil), LocalModelCatalog.allocatedContextTokens)
    }

    /// La vue de chat relit la fenêtre des dizaines de fois par frappe : l'en-tête du modèle
    /// (jusqu'à 32 Mo) ne doit être lu qu'une fois par fichier installé.
    func testAutomaticWindowReadsTheModelHeaderOncePerInstalledFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(LocalModelCatalog.text.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(try XCTUnwrap(LocalModelCatalog.text.assets.first).filename)
        try header(headCountKV: le32(8)).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        var reads = 0
        let read: (URL) -> GGUFMetadata? = { url in
            reads += 1
            return GGUFMetadata.parse((try? Data(contentsOf: url)) ?? Data())
        }
        let first = LocalModelCatalog.automaticTokens(for: LocalModelCatalog.text, root: root, readMetadata: read)
        XCTAssertEqual(reads, 1)
        for _ in 0..<20 {
            XCTAssertEqual(LocalModelCatalog.automaticTokens(for: LocalModelCatalog.text, root: root, readMetadata: read), first)
        }
        XCTAssertEqual(reads, 1)

        // Un fichier remplacé (taille différente) est redimensionné une seule fois.
        try (header(headCountKV: le32(8)) + Data(repeating: 0, count: 1_024)).write(to: file)
        _ = LocalModelCatalog.automaticTokens(for: LocalModelCatalog.text, root: root, readMetadata: read)
        XCTAssertEqual(reads, 2)
        _ = LocalModelCatalog.automaticTokens(for: LocalModelCatalog.text, root: root, readMetadata: read)
        XCTAssertEqual(reads, 2)
    }
    // MARK: - Catalogue lisible

    /// Le catalogue affiche la famille sur la fiche « i » de chaque modèle : le champ
    /// reste obligatoire, même si l'écran catalogue ne regroupe plus par famille.
    func testEveryModelDeclaresAFamilyForItsDetailSheet() {
        for model in LocalModelCatalog.models {
            XCTAssertFalse(model.family.isEmpty, model.id)
        }
    }

    /// Aucune phrase du catalogue ne promet un contexte que l'iPhone n'atteint pas :
    /// le maximum du modèle n'est plus une information d'écran.
    func testStrengthsMentionNoModelContext() {
        for model in LocalModelCatalog.models {
            let strength = model.strength.lowercased()
            XCTAssertFalse(strength.contains("mots"), model.id)
            XCTAssertFalse(strength.contains("256k"), model.id)
        }
    }

    /// L'écran catalogue range par capacité : un modèle lit les images ou non, et
    /// chacun apparaît une seule fois, dans la catégorie qui le décrit.
    func testCapabilitySectionsCoverEveryModelExactlyOnce() {
        let ids = LocalModelCatalog.capabilitySections.flatMap { $0.models.map(\.id) }
        XCTAssertEqual(ids.count, LocalModelCatalog.models.count)
        XCTAssertEqual(Set(ids), Set(LocalModelCatalog.models.map(\.id)))
    }

    /// Dans une catégorie, le plus léger d'abord : un nouveau modèle se place tout
    /// seul, sans entretien.
    func testCapabilitySectionsSortModelsFromLightestToHeaviest() {
        for section in LocalModelCatalog.capabilitySections {
            let weights = section.models.map(\.downloadBytes)
            XCTAssertEqual(weights, weights.sorted(), section.name)
        }
    }

    /// Le logo chat / œil ne ment jamais : la catégorie « texte + vision » ne contient
    /// que des modèles qui lisent les images, l'autre aucun. La phrase de section est
    /// vraie par construction — elle décrit ce que la catégorie contient.
    func testCapabilitySectionLogosAndPhrasesHoldForEveryModel() {
        XCTAssertEqual(LocalModelCatalog.capabilitySections.map(\.supportsImages), [false, true])
        for section in LocalModelCatalog.capabilitySections {
            XCTAssertEqual(section.models.allSatisfy { $0.supportsImages }, section.supportsImages,
                           section.name)
            XCTAssertFalse(section.summary.isEmpty, section.name)
            for model in section.models {
                XCTAssertEqual(model.capabilityDescription,
                               section.supportsImages ? "Modèle texte + vision" : "Modèle texte",
                               model.id)
            }
        }
        // Les deux logos de la capture validée : chat pour le texte, œil pour la vision.
        XCTAssertEqual(LocalModelCatalog.capabilitySections.first?.icon,
                       "bubble.left.and.text.bubble.right")
        XCTAssertEqual(LocalModelCatalog.capabilitySections.last?.icon, "eye")
    }

    func testRecommendationsOnARecentPhoneCoverTheThreeUses() {
        let device = DeviceProfile(machineIdentifier: "iPhone17,1", physicalMemory: 8_000_000_000)
        let recommendations = LocalModelCatalog.recommendations(device: device)
        XCTAssertEqual(recommendations.map(\.role), [.conversation, .reasoning, .vision])
        XCTAssertEqual(recommendations.first { $0.role == .conversation }?.model.id, "qwen35_2b")
        XCTAssertEqual(recommendations.first { $0.role == .reasoning }?.model.id, "qwen35_4b")
        XCTAssertEqual(recommendations.first { $0.role == .vision }?.model.id, "lfm3-vision")
    }

    func testRecommendationsOfferOneModelPerUseAndAlwaysFromTheCatalog() {
        let recommendations = LocalModelCatalog.recommendations()
        // Une intention, un modèle : pas de liste de choix dans « Que veux-tu faire ? ».
        XCTAssertEqual(recommendations.count, Set(recommendations.map(\.role)).count)
        // Le modèle d'Apple n'est pas un modèle du catalogue : toute recommandation
        // doit pointer sur un modèle local, jamais sur lui.
        for recommendation in recommendations {
            XCTAssertTrue(LocalModelCatalog.models.contains { $0.id == recommendation.model.id },
                          "\(recommendation.model.id) ne vient pas du catalogue")
        }
    }

    func testRecommendationsNeverOfferAModelThePhoneCannotHold() {
        for memory in [1_000_000_000, 2_000_000_000, 3_000_000_000, 4_000_000_000] {
            let device = DeviceProfile(machineIdentifier: "iPhone12,1", physicalMemory: memory)
            for recommendation in LocalModelCatalog.recommendations(device: device) {
                XCTAssertTrue(recommendation.model.compatibility(device: device).isSupported,
                              "\(recommendation.model.title) sur \(memory)")
            }
        }
        // Sur 2 Go, seul le plus léger du catalogue reste proposable : les autres
        // raccourcis disparaissent plutôt que d'offrir un échec.
        let tiny = DeviceProfile(machineIdentifier: "iPhone12,1", physicalMemory: 2_000_000_000)
        XCTAssertEqual(LocalModelCatalog.recommendations(device: tiny).map(\.role), [.conversation])
        XCTAssertEqual(LocalModelCatalog.recommendations(device: tiny).first?.model.id, "qwen35_08b")
        // Sur 1 Go, plus rien ne tient : aucun raccourci.
        let minuscule = DeviceProfile(machineIdentifier: "iPhone12,1", physicalMemory: 1_000_000_000)
        XCTAssertTrue(LocalModelCatalog.recommendations(device: minuscule).isEmpty)
    }

    func testPreferenceListsOnlyReferenceCatalogueModels() {
        let ids = Set(LocalModelCatalog.models.map(\.id))
        for role in LocalModelCatalog.Role.allCases {
            XCTAssertFalse(LocalModelCatalog.preference(for: role).isEmpty, role.rawValue)
            for model in LocalModelCatalog.preference(for: role) {
                XCTAssertTrue(ids.contains(model.id), "\(role.rawValue) → \(model.id)")
            }
        }
    }
}
