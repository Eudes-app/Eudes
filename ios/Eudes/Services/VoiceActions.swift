import Foundation

/// The model proposes data, never executable code or arbitrary URL schemes.
struct VoiceAction: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case app, website, search, map, route, sms, reminder, event, clarification, none }
    var kind: Kind
    var value: String
    var body: String? = nil
    var date: String? = nil
    var endDate: String? = nil
    var id: String { "\(kind.rawValue):\(value):\(body ?? ""):\(date ?? "")" }

    static let apps: [String: String] = [
        "deezer": "deezer://", "spotify": "spotify:", "waze": "waze://", "youtube": "youtube://",
        "whatsapp": "whatsapp://", "plans": "maps://",
        "messages": "sms:", "mail": "mailto:"
    ]

    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mayRequestAction(_ text: String) -> Bool {
        let value = normalized(text)
        let starts = ["ouvre ", "lance ", "recherche ", "cherche ", "itineraire ", "emmene-moi ",
            "ecris ", "envoie ", "previens ", "rappelle-moi ", "ajoute ", "cree ", "bloque ",
            "appelle ", "prepare ", "va sur ", "trouve ", "mets ", "demarre ", "eteins ", "allume ",
            "je veux ", "je voudrais ", "j'aimerais ", "il faut que ", "peux-tu ", "pourrais-tu ",
            "est-ce que tu peux ", "aide-moi "]
        return starts.contains { value.hasPrefix($0) }
    }

    /// Explicit Web research belongs to the conversational research pipeline,
    /// not to the separate action that opens a search page. Do not change
    /// existing action handling when voice research is disabled.
    static func shouldInterpretAction(_ text: String, hasClarification: Bool,
                                      voiceWebMode: VoiceWebSearchMode) -> Bool {
        if hasClarification { return true }
        if voiceWebMode != .disabled && VoiceWebSearchMode.onRequest.shouldSearch(for: text) { return false }
        return mayRequestAction(text)
    }

    static func requiresForeground(_ text: String) -> Bool {
        if let action = direct(text), action.kind != .search { return true }
        let text = normalized(text)
        for prefix in ["peux-tu ", "pourrais-tu ", "je veux ", "je voudrais ", "j'aimerais "] where text.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
            if ["ouvrir ", "lancer ", "envoyer un sms ", "creer un rappel ", "creer un evenement "].contains(where: { rest.hasPrefix($0) }) { return true }
            return requiresForeground(rest)
        }
        return ["ouvre ", "lance ", "rappelle-moi ", "ecris a ", "envoie un sms ", "previens ",
                "ajoute un rappel ", "cree un rappel ", "ajoute un evenement ", "cree un evenement ",
                "itineraire vers "].contains { text.hasPrefix($0) }
    }

    /// Intentionally anchored: a quotation or a question about a command isn't an instruction.
    static func direct(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> VoiceAction? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = normalized(clean).trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        for prefix in ["ouvre ", "lance "] where folded.hasPrefix(prefix) {
            let target = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
            var name = normalized(target)
            var explicitlyNamedApp = false
            for qualifier in ["l'application ", "l'appli ", "l'app ", "application ", "appli ", "app "] where name.hasPrefix(qualifier) {
                name = String(name.dropFirst(qualifier.count)).trimmingCharacters(in: .whitespaces)
                explicitlyNamedApp = true
                break
            }
            if apps[name] != nil { return .init(kind: .app, value: name) }
            if explicitlyNamedApp {
                return .init(kind: .clarification, value: "Cette application n’est pas encore prise en charge par Eudes. Les applications disponibles sont : " + apps.keys.sorted().joined(separator: ", ") + ".")
            }
            if websiteURL(target) != nil { return .init(kind: .website, value: target) }
            return nil
        }
        for (prefix, kind) in [("recherche sur le web ", Kind.search), ("cherche dans plans ", .map), ("itineraire vers ", .route)] {
            if folded.hasPrefix(prefix) {
                let value = String(clean.dropFirst(prefix.count))
                return value.isEmpty ? nil : .init(kind: kind, value: value)
            }
        }
        if let captures = captures("^ecris a (.+?)\\s*:\\s*(.+)$", in: folded),
           let colon = clean.firstIndex(of: ":") {
            return .init(kind: .sms, value: captures[0], body: String(clean[clean.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        if let parts = captures("^rappelle-moi de (.+) (demain|aujourd'hui) a ([0-9]{1,2})(?:\\s*h\\s*|:)([0-9]{2})?$", in: folded),
           let hour = Int(parts[2]), hour < 24, let minute = Int(parts[3].isEmpty ? "0" : parts[3]), minute < 60,
           let day = calendar.date(byAdding: .day, value: parts[1] == "demain" ? 1 : 0, to: now),
           let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) {
            return .init(kind: .reminder, value: String(clean.dropFirst("rappelle-moi de ".count).prefix(parts[0].count)), date: ISO8601DateFormatter().string(from: date))
        }
        if let parts = captures("^ajoute (.+) (demain|aujourd'hui) a ([0-9]{1,2}) h(?: ([0-9]{2}))? pendant ([0-9]{1,3}) (heure|heures|minute|minutes)$", in: folded),
           let hour = Int(parts[2]), hour < 24, let minute = Int(parts[3].isEmpty ? "0" : parts[3]), minute < 60,
           let duration = Int(parts[4]), duration > 0, duration <= 120,
           let day = calendar.date(byAdding: .day, value: parts[1] == "demain" ? 1 : 0, to: now),
           let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) {
            let seconds = Double(duration * (parts[5].hasPrefix("heure") ? 3600 : 60))
            return .init(kind: .event, value: String(clean.dropFirst("ajoute ".count).prefix(parts[0].count)),
                date: ISO8601DateFormatter().string(from: start),
                endDate: ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)))
        }
        return nil
    }

    static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    static func websiteURL(_ text: String) -> URL? {
        guard !text.contains(where: { $0.isWhitespace }), text.contains(".") else { return nil }
        let raw = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: raw), components.scheme == "https",
              let host = components.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    func validated() throws -> Self {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 500,
              (body?.count ?? 0) <= 4000 else { throw VoiceActionError.invalid }
        switch kind {
        case .app: guard Self.apps[Self.normalized(value)] != nil else { throw VoiceActionError.unknownApp }
        case .website: guard Self.websiteURL(value) != nil else { throw VoiceActionError.invalid }
        case .sms: guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceActionError.invalid }
        case .reminder, .event:
            guard let date, let start = ISO8601DateFormatter().date(from: date) else { throw VoiceActionError.missingDate }
            if kind == .event {
                guard let endDate, let end = ISO8601DateFormatter().date(from: endDate), end > start,
                      end.timeIntervalSince(start) <= 7 * 86400 else { throw VoiceActionError.missingDate }
            }
        default: break
        }
        return self
    }

    var url: URL? {
        switch kind {
        case .app: return Self.apps[Self.normalized(value)].flatMap(URL.init(string:))
        case .website: return Self.websiteURL(value)
        case .search, .map, .route:
            var components = URLComponents(string: kind == .search ? "https://www.google.com/search" : "https://maps.apple.com/")!
            components.queryItems = [URLQueryItem(name: kind == .route ? "daddr" : "q", value: value)]
            return components.url
        default: return nil
        }
    }

    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 16_384, let data = text.data(using: .utf8) else { throw VoiceActionError.invalid }
        // No extraction from prose/fences, no array of actions and no partial JSON.
        let action = try JSONDecoder().decode(Self.self, from: data)
        return try action.validated()
    }

    static func instructions(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        """
        Classify the user's request for the iPhone assistant Eudes. Return ONE JSON object only, no markdown:
        {"kind":"none","value":"conversation"} for questions/conversation, quoted/hypothetical commands, or advice.
        Supported kinds: app, website, search, map, route, sms, reminder, event, clarification, none.
        value: app identifier, explicit HTTPS website, search/place/destination, SMS recipient, reminder/event title.
        app identifiers: \(apps.keys.sorted().joined(separator: ", ")). Unknown apps: clarification explaining unsupported app.
        sms: body is the message; do not invent a number. A contact name will be selected by the user on the phone.
        reminder/event: date is ISO8601 with time zone; event also needs endDate. Ask for missing date/time/duration.
        Current instant: \(ISO8601DateFormatter().string(from: now)); user's time zone: \(timeZone.identifier).
        clarification: value is a short French question for missing/ambiguous information or unsupported actions.
        If several actions are requested, ask which to perform first. Do not execute or claim success.
        Only explicit requests to perform actions qualify. Never infer an action merely from a topic.
        Never invent a website URL. No shortcuts, settings changes, deletion, purchases or automatic message sending.
        """
    }
}

enum VoiceActionError: LocalizedError {
    case invalid, unknownApp, missingDate, foreground, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid: "Je n’ai pas pu interpréter cette action. Reformule la demande en précisant les informations nécessaires."
        case .unknownApp: "Cette application n’est pas encore prise en charge par Eudes."
        case .missingDate: "Précise la date et l’heure, ainsi que la durée pour un événement."
        case .foreground: "Cette action nécessite qu'Eudes soit affiché à l’écran. Ouvre Eudes pour continuer."
        case .unavailable: "Cette action n’est pas disponible sur cet iPhone, ou l’autorisation a été refusée."
        }
    }
}
