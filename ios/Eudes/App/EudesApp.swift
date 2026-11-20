import SwiftUI
import AppIntents

@main
struct EudesApp: App {
    @UIApplicationDelegateAdaptor(LocalModelAppDelegate.self) private var localModelAppDelegate
    @StateObject private var store: AppStore

    init() {
        defer { EudesShortcuts.updateAppShortcutParameters() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let id = UUID().uuidString
            let appStore = AppStore(
                storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("EudesTestHost-" + id),
                defaults: UserDefaults(suiteName: "EudesTestHost." + id)!,
                client: OfflineModelDemo(), readKey: { _ in "" })
            _store = StateObject(wrappedValue: appStore)
            AppDependencyManager.shared.add(dependency: appStore)
            return
        }
        if Bundle.main.bundleIdentifier == "fr.eudes.app",
           ProcessInfo.processInfo.arguments.contains("--lue-isolated-qa") {
            let floatingQA = ProcessInfo.processInfo.environment["EUDES_QA_FLOATING"] == "1"
            let historyQA = ProcessInfo.processInfo.environment["EUDES_QA_HISTORY"] == "1"
            let webBudgetQA = ProcessInfo.processInfo.environment["EUDES_QA_WEB_BUDGET"] == "1"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(webBudgetQA ? "EudesUIQA-WebBudget" : (historyQA ? "EudesUIQA-CompactHistory" : (floatingQA ? "EudesUIQA-118" : "EudesUIQA-12-14-15")))
            let defaults = UserDefaults(suiteName: webBudgetQA ? "EudesUIQA.WebBudget" : (historyQA ? "EudesUIQA.CompactHistory" : "EudesUIQA.12-14-15"))!
            if ProcessInfo.processInfo.environment["EUDES_QA_REPLAY_KEYBOARD"] == "1" {
                defaults.set(false, forKey: "keyboardIntroductionV1Seen")
            }
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("workspace.json").path) {
                var data = AppData()
                var server = ServerProfile(name: "QA fictif hors ligne", baseURL: "https://192.168.254.254/v1", model: "alpha", availableModels: ["alpha", "beta"])
                if ProcessInfo.processInfo.environment["EUDES_QA_CLIPBOARD"] == "1" {
                    server.availableModels = ["alpha", "beta", "gamma"]
                    server.imageCompatibility = [server.visionKey("alpha"): "supported", server.visionKey("gamma"): "unsupported"]
                    defaults.set(true, forKey: "keyboardIntroductionV1Seen")
                }
                data.servers = [server]; data.selectedServerID = server.id
                data.conversations = (1...18).map { index in
                    Conversation(title: "Conversation fictive \(index)", serverID: server.id, model: "alpha",
                                 messages: [ChatMessage(role: .user, text: "Question fictive"), ChatMessage(role: .assistant, text: floatingQA ? (1...14).map { "Paragraphe fictif \($0) : ce texte de démonstration permet de vérifier la lecture derrière les boutons flottants, sans contacter un serveur." }.joined(separator: "\n\n") : "Réponse fictive")])
                }
                if ProcessInfo.processInfo.environment["EUDES_QA_EMPTY"] == "1" {
                    data = AppData()
                }
                if historyQA {
                    let folders = ["Travail", "Personnel", "Idées"].map { ConversationFolder(name: $0) }
                    data.folders = folders
                    let titles = ["Préparer mon voyage", "Idées pour Eudes", "Résumé du document",
                                  "Recette de ce soir", "Programme de la semaine", "Choisir un casque",
                                  "Notes de lecture"]
                    data.conversations = (0..<60).map { index in
                        Conversation(title: index < titles.count ? titles[index] : "Conversation de démonstration \(index + 1)",
                                     serverID: server.id, model: "alpha",
                                     messages: [ChatMessage(role: .user, text: "Contenu recherchable hors ligne")],
                                     updatedAt: Date().addingTimeInterval(-Double(index) * 60))
                    }
                    for folder in folders {
                        for index in 1...24 {
                            var conversation = Conversation(title: "\(folder.name) · sujet \(index)", serverID: server.id,
                                                            model: "alpha",
                                                            messages: [ChatMessage(role: .user, text: "Contenu recherchable hors ligne")])
                            conversation.folderID = folder.id
                            data.conversations.append(conversation)
                        }
                    }
                    defaults.set("left", forKey: "conversationMenuMode")
                    defaults.set(true, forKey: "keyboardIntroductionV1Seen")
                }
                if webBudgetQA {
                    let sources = (1...6).map { number in
                        WebSource(url: URL(string: "https://example.org/source-\(number)")!,
                                  title: ["Choisir sa couchette", "Préparer le départ", "Les trajets directs",
                                          "Comparer les horaires", "Bagages à bord", "Conditions d’échange"][number - 1],
                                  excerpt: "Extrait fictif pour vérifier la présentation sans accès au réseau.",
                                  kind: number <= 3 ? .page : .searchSnippet)
                    }
                    var answer = ChatMessage(role: .assistant,
                        text: "Je privilégierais une **couchette** pour mieux dormir, puis un trajet direct. [1]\n\nCompare aussi les horaires et les conditions d’échange. [2, 3]\n\nLes nombres 2026 et 42 restent visibles, comme le code `tableau[1]`.")
                    answer.webContext = WebSearchContext(query: "trains de nuit", fetchedAt: Date(), sources: sources)
                    var trace = WebResearchTrace(toolsOffered: true, maximumToolCalls: 100, budgetExhausted: false,
                                                 state: .completed, finishedAt: Date())
                    trace.calls = (0..<6).map { index in
                        WebToolActivity(tool: index < 3 ? .webSearch : .webFetch, origin: .model,
                                        state: .succeeded, query: index < 3 ? "trains de nuit \(index + 1)" : nil,
                                        url: index >= 3 ? sources[index - 3].url : nil,
                                        startedAt: Date(), finishedAt: Date())
                    }
                    answer.webResearchTrace = trace
                    let conversation = Conversation(title: "Recherche Web · démonstration", serverID: server.id,
                        model: "alpha", messages: [ChatMessage(role: .user, text: "Que privilégier pour voyager en train de nuit ?"), answer],
                        webSearchEnabled: true)
                    data.conversations = [conversation]
                    data.selectedConversationID = conversation.id
                    defaults.set(true, forKey: "keyboardIntroductionV1Seen")
                }
                try? PrivateStorage(directory: directory).save(data)
                defaults.set(true, forKey: "conversationMenuIntroductionV1Completed")
            }
            let appStore = AppStore(storageDirectory: directory, defaults: defaults,
                                                       client: OfflineModelDemo(), appleAvailability: {
                    ProcessInfo.processInfo.environment["EUDES_QA_APPLE_UNAVAILABLE"] == "1"
                        ? .ineligible : AppleModelClient.availability()
                }, readKey: { _ in "" },
                siriAssistant: SiriAssistantService(
                    persistence: .keychain(SiriAssistantKeychain(service: "fr.eudes.app.siri-qa")),
                    client: OfflineModelDemo()))
            _store = StateObject(wrappedValue: appStore)
            AppDependencyManager.shared.add(dependency: appStore)
            return
        }
        if Bundle.main.bundleIdentifier == "fr.eudes.app.lue03preview",
           ProcessInfo.processInfo.arguments.contains("--lue03-demo") {
            if ProcessInfo.processInfo.environment["EUDES_DEMO_CLIPBOARD"] == "synthetic" {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                    UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                    UIColor.white.setFill(); context.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
                }
                UIPasteboard.general.setItems([["public.png": image.pngData()!]], options: [.localOnly: true])
            }
            let appStore = AppStore(client: OfflineModelDemo(), readKey: { _ in "" })
            _store = StateObject(wrappedValue: appStore)
            AppDependencyManager.shared.add(dependency: appStore)
            return
        }
        #endif
        let appStore = AppStore()
        _store = StateObject(wrappedValue: appStore)
        AppDependencyManager.shared.add(dependency: appStore)
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var attemptedLocalPreload = false

    @MainActor private func preloadLocalModelIfRequested() {
        guard !attemptedLocalPreload, UserDefaults.standard.bool(forKey: AppStore.loadAtStartupKey),
              UIApplication.shared.isProtectedDataAvailable,
              let profile = store.selectedServer, profile.isLocalLFM else { return }
        attemptedLocalPreload = true
        Task { try? await LocalModelRuntime.shared.prepare(modelID: profile.model, useGPU: true,
                                                             contextTokens: LocalModelCatalog.resolvedContextSize(profile.localContextTokens, modelID: profile.model)) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Palette.accent)
                .background(WindowAppearance(appearance: store.appearance))
                .task {
                    if scenePhase == .active {
                        store.resumeLocalAfterForegroundReturn()
                        store.warmAutomaticContext()
                        preloadLocalModelIfRequested()
                    }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--lue-isolated-qa"),
                       ProcessInfo.processInfo.environment["EUDES_QA_BACKGROUND_VOICE"] == "1" {
                        try? await BackgroundVoiceSession.shared.start()
                    }
                    #endif
                }
                .overlay {
                    if scenePhase != .active {
                        ZStack {
                            ThemeBackground()
                            BrandMark(size: 72)
                        }
                        .accessibilityLabel("Eudes, contenu masqué")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                    store.protectedDataWillBecomeUnavailable()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    store.resumeLocalAfterForegroundReturn()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    if scenePhase == .active { store.resumeLocalAfterForegroundReturn() }
                }
                .onReceive(NotificationCenter.default.publisher(for: BackgroundVoiceSession.didEnd)) { _ in
                    if scenePhase == .active { store.importSiriConversations() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { preloadLocalModelIfRequested() }
                    store.sceneChanged(phase)
                    #if DEBUG
                    if phase == .background,
                       ProcessInfo.processInfo.arguments.contains("--lue-isolated-qa"),
                       ProcessInfo.processInfo.environment["EUDES_QA_EXPIRE"] == "1" {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            store.expireBackgroundGeneration()
                        }
                    }
                    #endif
                }
        }
    }
}

enum EudesShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case emptyQuestion, unlock, busy, noModel, sendFailed, saveFailed
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyQuestion: "Pose une question à Eudes."
        case .unlock: "Déverrouille ton iPhone pour utiliser Eudes."
        case .busy: "Eudes répond déjà à une question. Réessaie après la réponse."
        case .noModel: "Choisis d’abord un serveur et un modèle dans Eudes."
        case .sendFailed: "Eudes n’a pas pu obtenir de réponse. Ouvre Eudes pour vérifier la connexion."
        case .saveFailed: "La réponse n’a pas pu être enregistrée dans Eudes."
        }
    }
}

/// Headless Siri path: Siri handles dictation and speech, Eudes only processes text.
/// The published type and phrase are retained for existing shortcuts.
struct AskEudesIntent: AppIntent {
    static let title: LocalizedStringResource = "Poser une question à Eudes"
    static let description = IntentDescription("Pose une question avec Siri sans ouvrir Eudes. Active Siri, écran verrouillé dans les réglages d'Eudes avant le premier usage.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Question", requestValueDialog: "Quelle est ta question ?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Poser \(\.$question) à Eudes")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply = try await SiriAssistantService.shared.answer(question)
        return .result(value: reply, dialog: "\(reply)")
    }
}

/// The published shortcut now starts the same hands-free session in every launch context.
struct OpenEudesVoiceIntent: AppIntent, LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Ouvrir l’assistant vocal Eudes"
    static let description = IntentDescription("Démarre Eudes mains libres. Touche son activité pour afficher la même conversation. Active d’abord Siri, écran verrouillé dans Eudes.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func perform() async throws -> some IntentResult {
        guard #available(iOS 18.0, *) else { throw BackgroundVoiceError.needsNewerSystem }
        if await BackgroundVoiceSession.shared.isRunning { return .result() }
        try await BackgroundVoiceSession.shared.start()
        return .result()
    }
}

@available(iOS 18.0, *)
extension OpenEudesVoiceIntent: AudioRecordingIntent {}

/// Explicit opt-in background entry point; it never opens protected UI.
struct StartEudesHandsFreeIntent: AppIntent, LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Parler à Eudes mains libres"
    static let description = IntentDescription("Démarre la conversation vocale dans l’île dynamique, même écran verrouillé. Active d’abord Siri, écran verrouillé dans Eudes. Les actions nécessitant un écran demandent d’ouvrir Eudes.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var openAppWhenRun: Bool { false }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func perform() async throws -> some IntentResult {
        guard #available(iOS 18.0, *) else { throw BackgroundVoiceError.needsNewerSystem }
        if await BackgroundVoiceSession.shared.isRunning { return .result() }
        try await BackgroundVoiceSession.shared.start()
        return .result()
    }
}

@available(iOS 18.0, *)
extension StartEudesHandsFreeIntent: AudioRecordingIntent {}

struct EudesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartEudesHandsFreeIntent(), phrases: ["Parler à \(.applicationName) mains libres", "Démarrer \(.applicationName) mains libres"],
                    shortTitle: "Parler mains libres", systemImageName: "waveform")
        AppShortcut(intent: AskEudesIntent(), phrases: ["Poser une question à \(.applicationName)"],
                    shortTitle: "Demander à Eudes", systemImageName: "bubble.left")
        AppShortcut(intent: OpenEudesVoiceIntent(), phrases: ["Ouvrir l’assistant vocal de \(.applicationName)", "Démarrer l’assistant vocal \(.applicationName)", "Ouvre l’assistant vocal \(.applicationName)"],
                    shortTitle: "Ouvrir l’assistant", systemImageName: "waveform")
    }
}

#if DEBUG
/// Explicit isolated UI-test configuration: never reads credentials or opens a connection.
private struct OfflineModelDemo: EudesAPIClient {
    func checkConnection(profile: ServerProfile, key: String) async throws -> ConnectionProof {
        let scenario = ProcessInfo.processInfo.environment["EUDES_DEMO_CONNECTION"] ?? "success"
        try await Task.sleep(for: .milliseconds(scenario == "slow" ? 5000 : 700))
        switch scenario {
        case "timeout": throw URLError(.timedOut)
        case "auth": throw EudesError.server(401)
        case "unverified": return .unverified
        default: return .reachable
        }
    }
    func models(profile: ServerProfile, key: String) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(500))
        switch ProcessInfo.processInfo.environment["EUDES_DEMO_MODELS"] {
        case "one": return ["alpha"]
        case "empty": return []
        case "error": throw URLError(.notConnectedToInternet)
        default: return ["alpha", "beta"]
        }
    }
    func catalog(profile: ServerProfile, key: String) async throws -> ModelCatalog {
        let ids = try await models(profile: profile, key: key)
        guard ProcessInfo.processInfo.environment["EUDES_QA_LIMITS"] == "known" else { return ModelCatalog(ids: ids) }
        return ModelCatalog(ids: ids, limits: Dictionary(uniqueKeysWithValues: ids.map {
            ($0, ModelLimits(advertised: [TokenLimit(tokens: 8192, source: "Fixture · models.context_length")],
                server: [TokenLimit(tokens: 4096, source: "Fixture · models.max_model_len")],
                output: [TokenLimit(tokens: 1024, source: "Fixture · models.top_provider.max_completion_tokens")]))
        }))
    }
    func stream(profile: ServerProfile, key: String, model: String, messages: [ChatMessage], systemPrompt: String,
                temperature: Double, maxTokens: Int?, onText: @escaping @MainActor (String) -> Void) async throws {
        if ProcessInfo.processInfo.environment["EUDES_QA_STREAM"] == "long" {
            for index in 1...12 {
                try Task.checkCancellation()
                await onText("Réponse fictive hors ligne — étape \(index) sur 12.")
                try await Task.sleep(for: .seconds(1))
            }
            return
        }
        if ProcessInfo.processInfo.environment["EUDES_DEMO_CONNECTION"] == "success" {
            await onText("Réponse fictive")
            try await Task.sleep(for: .milliseconds(600))
            await onText("Réponse fictive : image reçue dans le test hors ligne.")
        } else { throw URLError(.notConnectedToInternet) }
    }
}
#endif
