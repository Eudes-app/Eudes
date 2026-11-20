import XCTest
@testable import Eudes

/// Le journal doit rester ordonné, borné, agrégé et surtout incapable de recopier
/// une donnée privée (URL de requête, texte système) dans ce que l'utilisateur copie.
final class DiagnosticLogTests: XCTestCase {
    func testOrderIsStableUnderConcurrentWriters() {
        let store = DiagnosticStore()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            store.append(category: .web, message: "événement \(index)")
        }
        let entries = store.snapshot()
        XCTAssertEqual(entries.count, 200)
        XCTAssertEqual(entries.map(\.sequence), (1...200).map { UInt64($0) })
        XCTAssertEqual(entries.map(\.message), entries.sorted { $0.sequence < $1.sequence }.map(\.message))
    }

    func testBufferKeepsOnlyTheMostRecentEntries() {
        let store = DiagnosticStore()
        for index in 0..<(DiagnosticStore.maximumEntries + 100) {
            store.append(category: .generation, message: "ligne \(index)")
        }
        let entries = store.snapshot()
        XCTAssertEqual(entries.count, DiagnosticStore.maximumEntries)
        XCTAssertEqual(entries.last?.message, "ligne \(DiagnosticStore.maximumEntries + 99)")
        XCTAssertEqual(entries.first?.sequence, UInt64(101))
    }

    func testLongMessageIsTruncated() {
        let store = DiagnosticStore()
        store.append(category: .error, message: String(repeating: "a", count: 5_000))
        XCTAssertEqual(store.snapshot().first?.message.count, DiagnosticStore.maximumMessageLength)
    }

    func testEmptyMessageIsIgnored() {
        let store = DiagnosticStore()
        XCTAssertFalse(store.append(category: .error, message: "   \n "))
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testIdenticalFailuresAreAggregated() {
        let store = DiagnosticStore()
        let start = Date()
        store.append(category: .web, message: "recherche Web échouée", detail: "blocked", date: start)
        store.append(category: .web, message: "recherche Web échouée", detail: "blocked",
                     date: start.addingTimeInterval(1))
        store.append(category: .web, message: "recherche Web échouée", detail: "blocked",
                     date: start.addingTimeInterval(2))
        let entries = store.snapshot()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.repeatCount, 3)

        // Un détail différent reste une information distincte.
        store.append(category: .web, message: "recherche Web échouée", detail: "noResults",
                     date: start.addingTimeInterval(3))
        XCTAssertEqual(store.snapshot().count, 2)
    }

    func testSeparatedFailuresAreNotAggregated() {
        let store = DiagnosticStore()
        let start = Date()
        store.append(category: .web, message: "recherche Web échouée", date: start)
        store.append(category: .web, message: "recherche Web échouée",
                     date: start.addingTimeInterval(DiagnosticStore.aggregationInterval + 1))
        XCTAssertEqual(store.snapshot().count, 2)
    }

    func testDescribeNeverRepeatsSystemText() {
        let secret = URL(string: "https://private.example/search?q=question-privee")!
        let urlError = URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorFailingURLErrorKey: secret,
            "NSErrorFailingURLStringKey": secret.absoluteString
        ])
        let nsError = NSError(domain: "EudesTest", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "https://private.example/search?q=question-privee"
        ])
        for error in [urlError as Error, nsError as Error] {
            let fault = DiagnosticLog.describe(error)
            let text = [fault.label, fault.detail ?? ""].joined(separator: " | ")
            XCTAssertFalse(text.contains("private.example"), "une URL privée a fuité : \(text)")
            XCTAssertFalse(text.contains("question-privee"), "la question privée a fuité : \(text)")
            XCTAssertEqual(fault.category, error is URLError ? DiagnosticCategory.network : DiagnosticCategory.error)
        }
    }

    func testDescribeCoversAppDefinedErrors() {
        let errors: [Error] = [
            WebSearchError.blocked,
            WebSearchError.httpStatus(429),
            WebPageError.timedOut,
            WebPageError.httpStatus(503),
            WebResearchModelError.unsupportedTools,
            EudesError.contextExceeded,
            EudesError.server(500),
            EudesError.storage("Le profil n’a pas pu être enregistré."),
            AppleModelError.context,
            ImageAttachmentError.invalid,
            LocalModelPrompt.PromptError.modelUnavailable,
            LocalLlamaEngine.EngineError.contextLimit
        ]
        for error in errors {
            let fault = DiagnosticLog.describe(error)
            XCTAssertFalse(fault.label.isEmpty, "libellé vide pour \(type(of: error))")
            XCTAssertNotNil(fault.detail, "aucun détail pour \(type(of: error))")
            XCTAssertFalse(fault.label.contains("private.example"))
        }
        XCTAssertEqual(DiagnosticLog.describe(WebSearchError.blocked).category, .web)
        XCTAssertEqual(DiagnosticLog.describe(AppleModelError.context).category, .apple)
        XCTAssertEqual(DiagnosticLog.describe(EudesError.server(500)).category, .server)
    }

    func testCopiedTextStaysReadable() {
        let store = DiagnosticStore()
        store.append(category: .web, message: "recherche Web échouée", detail: "blocked")
        store.append(category: .web, message: "recherche Web échouée", detail: "blocked")
        let text = DiagnosticFormatter.text(store.snapshot())
        XCTAssertTrue(text.contains("web"), text)
        XCTAssertTrue(text.contains("recherche Web échouée"), text)
        XCTAssertTrue(text.contains("blocked"), text)
        XCTAssertTrue(text.contains("(×2)"), text)
        XCTAssertFalse(text.contains("private.example"), text)
    }

    func testSessionEntryNeedsNoPrivateData() {
        let fault = DiagnosticLog.describe(EudesError.contextExceeded)
        XCTAssertEqual(fault.level, .error)
        XCTAssertFalse(fault.label.isEmpty)
    }
}
