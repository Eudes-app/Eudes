import XCTest
@testable import Eudes

final class WebSearchPolicyTests: XCTestCase {
    func testResearchBudgetDefaultPersistenceAndInvalidStoredValue() throws {
        let suite = "WebResearchBudgetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(WebResearchBudget.selected(defaults: defaults), 100)
        defaults.set(250, forKey: WebResearchBudget.defaultsKey)
        XCTAssertEqual(WebResearchBudget.selected(defaults: defaults), 250)
        defaults.set(-20, forKey: WebResearchBudget.defaultsKey)
        XCTAssertEqual(WebResearchBudget.selected(defaults: defaults), 100)
        XCTAssertEqual(WebResearchBudget.normalized(0), 1)
        XCTAssertEqual(WebResearchBudget.normalized(Int.max), Int.max)
    }

    func testLegacyCapabilitiesWithoutToolMetadataStillDecode() throws {
        let legacy = Data(#"{"images":"unknown","pdf":"unsupported","source":"old catalogue"}"#.utf8)
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: legacy)
        XCTAssertNil(decoded.tools)
        XCTAssertEqual(decoded.pdf, .unsupported)
        for tools in [true, false] {
            var updated = decoded
            updated.tools = tools
            XCTAssertEqual(try JSONDecoder().decode(ModelCapabilities.self, from: JSONEncoder().encode(updated)), updated)
        }
    }

    func testToolSupportUsesOnlyExplicitNonemptyMetadata() throws {
        let data = Data(#"""
        {"data":[
          {"id":"parameters-yes","supported_parameters":["temperature","tools"]},
          {"id":"parameters-no","supported_parameters":["temperature"]},
          {"id":"capabilities-yes","capabilities":["completion","tools"]},
          {"id":"capabilities-no","capabilities":["completion"]},
          {"id":"both-yes","supported_parameters":["tools"],"capabilities":["tools"]},
          {"id":"both-no","supported_parameters":["temperature"],"capabilities":["completion"]},
          {"id":"empty","supported_parameters":[],"capabilities":[]},
          {"id":"malformed","supported_parameters":["tools",true],"capabilities":true},
          {"id":"tool-calling-super-model"}
        ]}
        """#.utf8)
        let catalog = try ModelCatalog.decode(data)
        for id in ["parameters-yes", "capabilities-yes", "both-yes"] {
            XCTAssertEqual(catalog.capabilities[id]?.tools, true, id)
        }
        for id in ["parameters-no", "capabilities-no", "both-no"] {
            XCTAssertEqual(catalog.capabilities[id]?.tools, false, id)
        }
        for id in ["empty", "malformed", "tool-calling-super-model"] {
            XCTAssertNil(catalog.capabilities[id]?.tools, id)
        }
    }

    func testConflictingToolMetadataRemainsUnknownWithinAndAcrossRows() throws {
        let data = Data(#"""
        {"data":[
          {"id":"within-row","supported_parameters":["tools"],"capabilities":["completion"]},
          {"id":"opposite-within-row","supported_parameters":["temperature"],"capabilities":["tools"]},
          {"id":"duplicate","supported_parameters":["tools"]},
          {"id":"duplicate","supported_parameters":["temperature"]},
          {"id":"duplicate","supported_parameters":["tools"]},
          {"id":"missing-duplicate","supported_parameters":["tools"]},
          {"id":"missing-duplicate"}
        ]}
        """#.utf8)
        let catalog = try ModelCatalog.decode(data)
        for id in ["within-row", "opposite-within-row", "duplicate", "missing-duplicate"] {
            XCTAssertNil(catalog.capabilities[id]?.tools, id)
        }
    }

    func testModesHaveStableCodableValuesAndIdentities() throws {
        XCTAssertEqual(ChatWebSearchMode.allCases.map(\.rawValue), ["disabled", "perConversation", "allConversations"])
        XCTAssertEqual(VoiceWebSearchMode.allCases.map(\.rawValue), ["disabled", "onRequest", "always"])
        for mode in ChatWebSearchMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(ChatWebSearchMode.self, from: JSONEncoder().encode(mode)), mode)
        }
        for mode in VoiceWebSearchMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(VoiceWebSearchMode.self, from: JSONEncoder().encode(mode)), mode)
        }
    }

    func testDisabledAndAlwaysDoNotDependOnWording() {
        for question in ["", "Bonjour", "Ne cherche pas sur Internet", "Cherche sur Internet la météo", "« Cherche sur Internet »"] {
            XCTAssertFalse(VoiceWebSearchMode.disabled.shouldSearch(for: question), question)
            XCTAssertTrue(VoiceWebSearchMode.always.shouldSearch(for: question), question)
        }
    }

    func testExplicitFrenchRequestsWithCaseAccentsAndPoliteness() {
        let questions = [
            "Cherche sur Internet la météo", "recherche sur le Web les horaires",
            "Peux-tu chercher sur internet la météo de demain ?",
            "PEUX TU RECHERCHER SUR LE WEB LES HORAIRES ?",
            "Pourrais-tu me chercher sur Internet les horaires ?",
            "Peux-tu s’il te plaît me chercher sur Internet la météo ?",
            "Pourriez-vous rechercher sur le Web les horaires ?",
            "Est-ce que tu peux chercher sur Internet la météo ?",
            "Est-ce que vous pouvez rechercher sur le web la météo ?",
            "S’il te plaît, cherche sur Internet la météo.",
            "S'il vous plaît, recherchez sur Internet les horaires.",
            "Bonjour Eudes, peux-tu chercher sur Internet la météo ?",
            "Bonsoir, s'il te plaît, cherche la météo sur Internet.",
            "Cherche-moi les horaires sur le web, s'il te plaît.",
            "Fais une recherche sur Internet pour la météo.",
            "Lance une recherche sur le Web.",
            "Peux-tu faire une recherche sur Internet ?",
            "Je voudrais rechercher sur le Web les horaires.",
            "Merci de chercher sur Internet les horaires.",
            "Cherche sur Internet les pays sans littoral.",
            "Cherche sur Internet pourquoi mon wifi ne fonctionne pas.",
            "Cherche sur Internet pourquoi mon vol a été annulé.",
            "SVP, cherchez sur le Net les horaires.",
            "Tu peux nous chercher des horaires sur Internet ?"
        ]
        for question in questions { XCTAssertTrue(VoiceWebSearchMode.onRequest.shouldSearch(for: question), question) }
    }

    func testNegatedAndAmbiguousRequestsDoNotSearch() {
        let questions = [
            "Ne cherche pas sur Internet la météo.", "N’utilise pas Internet.",
            "Cherche pas sur Internet.", "Peux-tu ne pas chercher sur le Web ?",
            "Peux-tu chercher sans Internet ?", "Recherche sans aller sur le Web.",
            "Ne fais jamais une recherche sur Internet.", "Cherche sur Internet, non, annule.",
            "Cherche sur Internet puis oublie ma demande.",
            "Cherche sur Internet la météo, arrête la recherche.",
            "Je ne voudrais pas rechercher sur le Web.", "Cherche la météo mais pas sur Internet.",
            "Cherche sur Internet, finalement non.", "Cherche sur Internet, ne le fais pas."
        ]
        for question in questions { XCTAssertFalse(VoiceWebSearchMode.onRequest.shouldSearch(for: question), question) }
    }

    func testOrdinaryInternetMentionsAndInformationalQuestionsDoNotSearch() {
        let questions = [
            "Quelle est la météo ?", "Comment fonctionne Internet ?", "Internet est-il sûr ?",
            "Comment chercher sur Internet ?", "Pourquoi rechercher sur le Web ?",
            "Explique comment faire une recherche sur Internet.", "Peux-tu expliquer comment chercher sur le Web ?",
            "Tu sais rechercher sur Internet ?", "Il cherche sur Internet la météo.",
            "Je cherche sur Internet une recette.", "Peux-tu me dire ce que signifie recherche Web ?",
            "Cherche dans mes notes la météo.", "Recherche le mot Internet dans ce texte.",
            "Cherche dans mes notes un article sur Internet.",
            "Recherche dans ce document un paragraphe sur le Web.",
            "Recherche Internet", "Search the web for weather", "Bonjour"
        ]
        for question in questions { XCTAssertFalse(VoiceWebSearchMode.onRequest.shouldSearch(for: question), question) }
    }

    func testQuotedCommandsDoNotActivateSearch() {
        let questions = [
            "\"cherche sur Internet la météo\"", "« cherche sur Internet la météo »",
            "“cherche sur Internet la météo”", "‘cherche sur Internet la météo’",
            "'cherche sur Internet la météo'", "`cherche sur Internet la météo`",
            "\"cherche sur Internet la météo", "« cherche sur Internet la météo",
            "'cherche sur Internet la météo", "’cherche sur Internet la météo",
            "Répète : « Peux-tu chercher sur Internet ? »",
            "Que veut dire \"cherche sur Internet\" ?",
            "Bonjour, « cherche sur Internet la météo »",
            "Cherche dans mes notes la phrase « sur Internet ».",
            "« Un exemple » cherche sur Internet la météo."
        ]
        for question in questions { XCTAssertFalse(VoiceWebSearchMode.onRequest.shouldSearch(for: question), question) }
    }

    func testQuotedTopicKeepsExplicitUnquotedCommand() {
        XCTAssertTrue(VoiceWebSearchMode.onRequest.shouldSearch(for: "Cherche sur Internet « Swift 6 »"))
        XCTAssertTrue(VoiceWebSearchMode.onRequest.shouldSearch(for: "Peux-tu rechercher \"Paris météo\" sur le Web ?"))
    }

    func testOnRequestOnlyAppliesToCurrentQuestion() {
        let mode = VoiceWebSearchMode.onRequest
        XCTAssertTrue(mode.shouldSearch(for: "Cherche sur Internet la météo."))
        XCTAssertFalse(mode.shouldSearch(for: "Et demain ?"))
        XCTAssertFalse(mode.shouldSearch(for: "Merci, raconte-moi une histoire."))
        XCTAssertTrue(mode.shouldSearch(for: "Peux-tu chercher sur Internet les horaires ?"))
    }

    func testEmptyOrExcessiveRequestsDoNotTriggerOptionalSearch() {
        XCTAssertFalse(VoiceWebSearchMode.onRequest.shouldSearch(for: " \n\t"))
        XCTAssertFalse(VoiceWebSearchMode.onRequest.shouldSearch(for: "Cherche sur Internet " + String(repeating: "a", count: 4_001)))
    }
}
