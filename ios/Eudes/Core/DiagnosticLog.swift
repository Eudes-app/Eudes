import Foundation

/// Catégorie d'un événement du journal technique.
enum DiagnosticCategory: String, CaseIterable, Identifiable, Sendable {
    case session, generation, network, server, web, appleWeb, model, apple, voice, speech, storage, error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: return "Session"
        case .generation: return "Génération"
        case .network: return "Réseau"
        case .server: return "Serveur"
        case .web: return "Recherche Web"
        case .appleWeb: return "Outils Apple"
        case .model: return "Modèle local"
        case .apple: return "Modèle Apple"
        case .voice: return "Synthèse vocale"
        case .speech: return "Dictée"
        case .storage: return "Stockage"
        case .error: return "Erreur"
        }
    }
}

enum DiagnosticLevel: String, Sendable {
    case info, warning, error

    var label: String {
        switch self {
        case .info: return "info"
        case .warning: return "alerte"
        case .error: return "erreur"
        }
    }
}

struct DiagnosticEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Ordre réel d'émission, indépendant de l'ordre d'arrivée sur le fil principal.
    let sequence: UInt64
    let date: Date
    let category: DiagnosticCategory
    let level: DiagnosticLevel
    let message: String
    /// Métadonnée explicative déjà expurgée (message rédigé par l'app ou code numérique).
    let detail: String?
    var repeatCount: Int
}

/// Erreur traduite en une entrée de journal sûre.
struct DiagnosticFault: Equatable, Sendable {
    let category: DiagnosticCategory
    let label: String
    let detail: String?
    let level: DiagnosticLevel
}

/// Tampon du journal : borné, ordonné, agrégé, jamais écrit sur disque.
///
/// Toute mutation passe par un verrou unique, y compris la numérotation, pour que
/// deux événements venus d'acteurs différents gardent leur ordre réel. Aucune entrée
/// ne peut contenir de donnée privée : le texte est produit par l'app ou par
/// `DiagnosticLog.describe`, jamais repris d'une erreur système.
final class DiagnosticStore: @unchecked Sendable {
    static let shared = DiagnosticStore()

    static let maximumEntries = 400
    static let maximumMessageLength = 600
    /// Deux erreurs identiques rapprochées sont agrégées au lieu de saturer le tampon.
    static let aggregationInterval: TimeInterval = 5

    private let lock = NSLock()
    private var buffer: [DiagnosticEntry] = []
    private var sequence: UInt64 = 0
    private var publishPending = false

    init() {}

    /// Ajoute une entrée. Renvoie `false` si le message est vide (rien n'est écrit).
    @discardableResult
    func append(category: DiagnosticCategory, level: DiagnosticLevel = .info,
                message: String, detail: String? = nil, date: Date = Date()) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let text = String(trimmed.prefix(Self.maximumMessageLength))
        let cleanDetail = detail.map { String($0.prefix(Self.maximumMessageLength)) }

        lock.lock()
        defer { lock.unlock() }
        if var last = buffer.last, last.category == category, last.message == text,
           last.detail == cleanDetail, date.timeIntervalSince(last.date) <= Self.aggregationInterval {
            last.repeatCount += 1
            buffer[buffer.count - 1] = last
            return true
        }
        sequence += 1
        buffer.append(DiagnosticEntry(id: UUID(), sequence: sequence, date: date, category: category,
                                      level: level, message: text, detail: cleanDetail, repeatCount: 1))
        if buffer.count > Self.maximumEntries {
            buffer.removeFirst(buffer.count - Self.maximumEntries)
        }
        return true
    }

    func snapshot() -> [DiagnosticEntry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// Un seul rafraîchissement d'interface par lot d'entrées.
    func claimPublish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !publishPending else { return false }
        publishPending = true
        return true
    }

    func releasePublish() {
        lock.lock()
        publishPending = false
        lock.unlock()
    }
}

/// Journal technique consultable depuis les Réglages.
///
/// Point de passage unique des erreurs de l'app : chaque échec affiché ou converti
/// en valeur de repli laisse une entrée lisible. Les entrées vivent en mémoire
/// uniquement, pour être copiées au moment du problème ; rien n'est envoyé ni écrit
/// sur disque, et aucune donnée privée (prompt, réponse, URL, clé, transcription)
/// n'y entre.
@MainActor
final class DiagnosticLog: ObservableObject {
    static let shared = DiagnosticLog()

    @Published private(set) var entries: [DiagnosticEntry] = []

    private init() {
        entries = DiagnosticStore.shared.snapshot()
    }

    // MARK: Enregistrement, appelable depuis n'importe quel contexte

    nonisolated static func log(_ category: DiagnosticCategory, _ message: String,
                                detail: String? = nil, level: DiagnosticLevel = .info) {
        guard DiagnosticStore.shared.append(category: category, level: level,
                                            message: message, detail: detail) else { return }
        schedulePublish()
    }

    /// Journalise une erreur réelle, à l'endroit où elle est affichée ou remplacée.
    /// La catégorie est déduite du type d'erreur sauf indication contraire.
    nonisolated static func record(_ error: Error, context: String,
                                   category: DiagnosticCategory? = nil) {
        let fault = describe(error)
        log(category ?? fault.category, "\(context) — \(fault.label)",
            detail: fault.detail, level: fault.level)
    }

    private nonisolated static func schedulePublish() {
        guard DiagnosticStore.shared.claimPublish() else { return }
        Task { @MainActor in shared.publish() }
    }

    func publish() {
        // Libérer avant de lire : une entrée ajoutée entre-temps planifie son propre rafraîchissement.
        DiagnosticStore.shared.releasePublish()
        entries = DiagnosticStore.shared.snapshot()
    }

    func clear() {
        DiagnosticStore.shared.clear()
        entries = []
    }

    /// Texte complet, prêt à être copié ou partagé.
    func text() -> String {
        DiagnosticFormatter.text(entries)
    }
}

// MARK: - Traduction sûre des erreurs

extension DiagnosticLog {
    /// Décrit une erreur sans jamais reprendre de texte système.
    ///
    /// Seuls les messages rédigés dans l'app et les codes numériques sont conservés.
    /// Un `URLError` ne livre jamais son URL, un `NSError` jamais son `userInfo` :
    /// un échec réseau ne peut donc pas copier la question privée dans le journal.
    nonisolated static func describe(_ error: Error) -> DiagnosticFault {
        switch error {
        case is CancellationError:
            return DiagnosticFault(category: .error, label: "annulé", detail: nil, level: .info)
        case let error as WebSearchError:
            return DiagnosticFault(category: .web, label: String(describing: error),
                                   detail: error.localizedDescription, level: .warning)
        case let error as WebPageError:
            return DiagnosticFault(category: .web, label: String(describing: error),
                                   detail: error.localizedDescription, level: .warning)
        case let error as WebResearchModelError:
            return DiagnosticFault(category: .web, label: String(describing: error),
                                   detail: "Le modèle n’a pas appelé les outils Web.",
                                   level: .warning)
        case let error as AppleModelError:
            return DiagnosticFault(category: .apple, label: String(describing: error),
                                   detail: error.localizedDescription, level: .error)
        case let error as EudesError:
            return DiagnosticFault(category: Self.category(for: error), label: String(describing: error),
                                   detail: error.localizedDescription, level: .error)
        case let error as LocalModelPrompt.PromptError:
            return DiagnosticFault(category: .model, label: String(describing: error),
                                   detail: error.localizedDescription, level: .error)
        case let error as LocalLlamaEngine.EngineError:
            return DiagnosticFault(category: .model, label: String(describing: error),
                                   detail: error.localizedDescription, level: .error)
        case let error as ImageAttachmentError:
            return DiagnosticFault(category: .generation, label: String(describing: error),
                                   detail: error.localizedDescription, level: .error)
        case let error as PocketTTSError:
            return DiagnosticFault(category: .voice, label: String(describing: error),
                                   detail: error.localizedDescription, level: .error)
        case let error as PocketCoreMLError:
            return DiagnosticFault(category: .voice, label: String(describing: error),
                                   detail: error.localizedDescription, level: .error)
        case let error as AppleSpeechError:
            return DiagnosticFault(category: .speech, label: String(describing: error),
                                   detail: error.localizedDescription, level: .error)
        case let error as VoiceAssistantError:
            return DiagnosticFault(category: .speech, label: String(describing: error),
                                   detail: error.localizedDescription, level: .error)
        case let error as VoiceActionError:
            return DiagnosticFault(category: .speech, label: String(describing: error),
                                   detail: error.localizedDescription, level: .error)
        case let error as BackgroundVoiceError:
            return DiagnosticFault(category: .speech, label: String(describing: error),
                                   detail: nil, level: .error)
        case let error as VoiceActivityError:
            return DiagnosticFault(category: .speech, label: String(describing: error),
                                   detail: nil, level: .error)
        case let error as SiriAssistantError:
            return DiagnosticFault(category: .speech, label: String(describing: error),
                                   detail: nil, level: .error)
        case let error as EudesShortcutError:
            return DiagnosticFault(category: .speech, label: String(describing: error),
                                   detail: nil, level: .error)
        case let error as URLError:
            return DiagnosticFault(category: .network, label: "URLError \(error.code.rawValue)",
                                   detail: nil, level: .warning)
        default:
            let nsError = error as NSError
            return DiagnosticFault(category: .error,
                                   label: "\(type(of: error)) [\(nsError.domain) \(nsError.code)]",
                                   detail: nil, level: .error)
        }
    }

    nonisolated private static func category(for error: EudesError) -> DiagnosticCategory {
        switch error {
        case .server, .invalidAddress, .publicAddress, .insecureHTTP, .redirect, .invalidResponse, .keychain:
            return .server
        case .storage:
            return .storage
        default:
            return .generation
        }
    }
}

// MARK: - Mise en forme

enum DiagnosticFormatter {
    static func line(_ entry: DiagnosticEntry, formatter: DateFormatter) -> String {
        let repetition = entry.repeatCount > 1 ? " (×\(entry.repeatCount))" : ""
        let detail = entry.detail.map { " | \($0)" } ?? ""
        return "[\(formatter.string(from: entry.date))] \(entry.category.rawValue) \(entry.level.label): "
            + "\(entry.message)\(detail)\(repetition)"
    }

    static func text(_ entries: [DiagnosticEntry]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "fr_FR")
        return entries.map { line($0, formatter: formatter) }.joined(separator: "\n")
    }
}

// MARK: - Mesures du moteur local

/// Mesures d'une génération locale, affichées dans Réglages › Diagnostic.
///
/// Aucune donnée privée n'y entre : ni prompt, ni réponse, seulement des comptes de
/// tokens, des durées et l'état thermique du téléphone.
struct LocalGenerationMetrics: Equatable, Sendable {
    let modelID: String
    let modelTitle: String
    let promptTokens: Int
    let cachedTokens: Int
    let prefillSeconds: Double
    let answerTokens: Int
    let decodeSeconds: Double
    let thermal: String
    let lowPower: Bool
    let date: Date

    /// Tokens de prompt réellement envoyés au décodeur : le cache fait le reste.
    var decodedPromptTokens: Int { max(0, promptTokens - cachedTokens) }

    var prefillRate: Double {
        guard decodedPromptTokens > 0, prefillSeconds > 0 else { return 0 }
        return Double(decodedPromptTokens) / prefillSeconds
    }

    var decodeRate: Double {
        guard answerTokens > 0, decodeSeconds > 0 else { return 0 }
        return Double(answerTokens) / decodeSeconds
    }

    /// Décodage sous 3 tokens/s ou prefill sous 10 : le seul cas qui écrit dans le
    /// journal sans que la bascule de traçage soit active.
    var isSlowerThanUsual: Bool {
        (decodeRate > 0 && decodeRate < 3) || (prefillRate > 0 && prefillRate < 10)
    }

    var needsAttention: Bool { isSlowerThanUsual || thermal != "nominal" || lowPower }

    var journalMessage: String {
        let cached = cachedTokens > 0 ? " (\(cachedTokens) du cache)" : ""
        let power = lowPower ? " · économie d’énergie" : ""
        return String(format: "%@ · prefill %d tok%@ %.1f s · décodage %d tok %.1f s · %.1f tok/s · thermique %@%@",
                      modelTitle, promptTokens, cached, prefillSeconds,
                      answerTokens, decodeSeconds, decodeRate, thermal, power)
    }
}

struct LocalVerificationMetrics: Equatable, Sendable {
    let modelID: String
    let modelTitle: String
    let seconds: Double
    /// `true` quand l'empreinte venait du cache : aucun hachage n'a eu lieu.
    let reused: Bool
    let date: Date
}

/// Réglage partagé : écrire chaque génération dans le journal au lieu de ne garder
/// que les mesures de la dernière réponse.
enum LocalEngineDiagnostics {
    static let traceKey = "diagnostic.traceEngine"

    static var tracesEveryGeneration: Bool {
        UserDefaults.standard.bool(forKey: traceKey)
    }
}

extension ProcessInfo.ThermalState {
    /// Libellé court en français, sans jargon système.
    var localLabel: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "tiède"
        case .serious: return "chaud"
        case .critical: return "critique"
        @unknown default: return "inconnu"
        }
    }
}

/// Point de collecte des mesures du moteur local, lu par l'écran Diagnostic.
@MainActor
final class LocalEngineReport: ObservableObject {
    static let shared = LocalEngineReport()

    @Published private(set) var generation: LocalGenerationMetrics?
    @Published private(set) var verification: LocalVerificationMetrics?

    func record(generation metrics: LocalGenerationMetrics) { generation = metrics }
    func record(verification metrics: LocalVerificationMetrics) { verification = metrics }
}
