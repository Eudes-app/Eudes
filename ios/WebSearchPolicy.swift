import Foundation

enum WebResearchBudget {
    static let defaultMaximumCalls = 100
    static let defaultsKey = "webToolCallLimit"

    static func normalized(_ value: Int) -> Int { max(1, value) }

    static func selected(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultMaximumCalls }
        let value = defaults.integer(forKey: defaultsKey)
        return value > 0 ? value : defaultMaximumCalls
    }
}

enum ChatWebSearchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case perConversation
    case allConversations

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .disabled: return "Désactivé"
        case .perConversation: return "Par conversation"
        case .allConversations: return "Toutes les conversations"
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .disabled: return "Tes messages du chat sont envoyés sans recherche Web."
        case .perConversation: return "Active la recherche Web dans les conversations de ton choix."
        case .allConversations: return "Le Web est disponible dans toutes les conversations. Le modèle décide quand rechercher s’il accepte les outils ; sinon Eudes recherche à chaque message."
        }
    }
}

enum VoiceWebSearchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case onRequest
    case always

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .disabled: return "Désactivé"
        case .onRequest: return "À la demande"
        case .always: return "En permanence"
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .disabled: return "Tes questions vocales sont envoyées sans recherche Web."
        case .onRequest: return "Dis par exemple « Cherche sur Internet la météo » ou « Peux-tu rechercher sur le Web… ». La recherche concerne uniquement ta question en cours."
        case .always: return "Le Web est disponible pour chaque question vocale. Le modèle décide quand rechercher s’il accepte les outils ; sinon Eudes lance la recherche."
        }
    }

    func shouldSearch(for question: String) -> Bool {
        switch self {
        case .disabled: return false
        case .always: return true
        case .onRequest: return ExplicitWebSearchRequest.matches(question)
        }
    }
}

/// Deliberately narrow, deterministic recognition of a French command directed to Eudes.
/// It accepts a leading search command (with common greetings/polite prefixes) plus an
/// unquoted "sur Internet", "sur le Web" or "sur le Net". It does not infer intent from
/// topic words, quoted commands, informational questions or a negated search command.
/// Negation is checked before the Web marker, while an explicit cancellation also wins
/// after it. Negative words in the topic after that marker do not disable the search.
enum ExplicitWebSearchRequest {
    static func matches(_ question: String) -> Bool {
        guard question.count <= 4_000 else { return false }
        let withoutQuotes = removingQuotedText(question)
        // Incomplete quotation marks are ambiguous too. Apostrophes inside words remain valid.
        guard withoutQuotes.rangeOfCharacter(from: CharacterSet(charactersIn: "\"«»“”‘`")) == nil,
              withoutQuotes.range(of: #"(?:^|\s)['’]"#, options: .regularExpression) == nil else { return false }
        let folded = withoutQuotes.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        var words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return false }

        // Remove only recognized prefixes at the beginning, never arbitrary text before
        // the command ("comment", "il a dit", "explique", etc. must remain non-commands).
        let politePrefixes = [
            ["s", "il", "te", "plait"], ["s", "il", "vous", "plait"],
            ["bonjour"], ["bonsoir"], ["salut"], ["eudes"], ["stp"], ["svp"]
        ]
        for _ in 0..<4 {
            guard let prefix = politePrefixes.first(where: { words.starts(with: $0) }) else { break }
            words.removeFirst(prefix.count)
        }

        let requestPrefixes = [
            ["est", "ce", "que", "tu", "peux"], ["est", "ce", "que", "vous", "pouvez"],
            ["pourrais", "tu"], ["pourriez", "vous"], ["peux", "tu"], ["pouvez", "vous"],
            ["tu", "peux"], ["vous", "pouvez"], ["je", "voudrais"], ["je", "souhaite"], ["merci", "de"]
        ]
        let requestPrefix = requestPrefixes.first(where: { words.starts(with: $0) })
        if let requestPrefix { words.removeFirst(requestPrefix.count) }
        if requestPrefix != nil,
           let politeness = politePrefixes.prefix(2).first(where: { words.starts(with: $0) }) {
            words.removeFirst(politeness.count)
        }
        if requestPrefix != nil, ["me", "nous"].contains(words.first ?? "") { words.removeFirst() }

        let commands: [[String]]
        if requestPrefix != nil {
            commands = [["chercher"], ["rechercher"], ["faire", "une", "recherche"], ["lancer", "une", "recherche"]]
        } else {
            commands = [["cherche"], ["recherche"], ["cherchez"], ["recherchez"],
                        ["fais", "une", "recherche"], ["faites", "une", "recherche"],
                        ["lance", "une", "recherche"], ["lancez", "une", "recherche"]]
        }
        guard let command = commands.first(where: { words.starts(with: $0) }) else { return false }
        words.removeFirst(command.count)

        let webPhrases = [["sur", "internet"], ["sur", "l", "internet"], ["sur", "le", "web"], ["sur", "le", "net"]]
        guard let markerStart = words.indices.first(where: { index in
            webPhrases.contains { words[index...].starts(with: $0) }
        }), let marker = webPhrases.first(where: { words[markerStart...].starts(with: $0) }) else { return false }

        let beforeWeb = Array(words[..<markerStart])
        let negation: Set<String> = ["ne", "n", "pas", "jamais", "sans", "aucun", "aucune", "ni", "non"]
        guard !beforeWeb.contains(where: negation.contains) else { return false }

        // A subject mentioning Internet doesn't override an explicitly requested local source.
        let localSources = [
            ["dans", "mes", "notes"], ["dans", "tes", "notes"], ["dans", "nos", "notes"],
            ["dans", "le", "texte"], ["dans", "ce", "texte"], ["dans", "cet", "article"],
            ["dans", "ce", "document"], ["dans", "le", "document"], ["dans", "mes", "documents"],
            ["dans", "mes", "fichiers"], ["dans", "mon", "fichier"],
            ["dans", "la", "conversation"], ["dans", "cette", "conversation"],
            ["dans", "ta", "memoire"], ["dans", "ton", "contexte"]
        ]
        guard !localSources.contains(where: { contains($0, in: beforeWeb) }) else { return false }

        let afterWeb = Array(words.dropFirst(markerStart + marker.count))
        let cancellations = [
            ["non", "annule"], ["finalement", "non"], ["non", "finalement"],
            ["oublie", "ma", "demande"], ["oublie", "cette", "demande"],
            ["annule", "ma", "demande"], ["annule", "la", "recherche"], ["annule", "cette", "recherche"],
            ["arrete", "la", "recherche"], ["arrete", "cette", "recherche"],
            ["ne", "cherche", "pas"], ["ne", "recherche", "pas"],
            ["ne", "le", "fais", "pas"], ["sans", "faire", "de", "recherche"]
        ]
        if [["non"], ["annule"], ["ou", "pas"]].contains(afterWeb) { return false }
        return !cancellations.contains(where: { contains($0, in: afterWeb) })
    }

    private static func contains(_ phrase: [String], in words: [String]) -> Bool {
        words.indices.contains { index in
            words[index...].starts(with: phrase)
        }
    }

    private static func removingQuotedText(_ value: String) -> String {
        // Keep a marker so a quoted prefix cannot disappear and expose a later command.
        // Single quote boundaries exclude apostrophes inside French words such as s'il.
        let patterns = [#""[^"]*""#, #"«[^»]*»"#, #"“[^”]*”"#, #"‘[^’]*’"#, #"`[^`]*`"#,
                        #"(?<![\p{L}\p{N}])'[^']*'(?![\p{L}\p{N}])"#]
        return patterns.reduce(value) { text, pattern in
            text.replacingOccurrences(of: pattern, with: " citation ", options: .regularExpression)
        }
    }
}
