import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [SettingsDestination]

    init(openServerConfiguration: Bool = false) {
        _path = State(initialValue: openServerConfiguration ? [.connections] : [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsHomeView()
                .disabled(store.isGenerating || store.isPreparingSend)
                .toolbar {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .topBarLeading) {
                            Text("Eudes").font(.title3.weight(.medium)).fixedSize()
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            Text("Eudes").font(.title3.weight(.medium)).fixedSize()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Terminé") { dismiss() }.fontWeight(.semibold)
                    }
                }
                .navigationDestination(for: SettingsDestination.self) { destination in
                    SettingsDestinationView(destination: destination)
                        .disabled(store.isGenerating || store.isPreparingSend)
                        .navigationTitle(Text(destination.title))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Terminé") { dismiss() }.fontWeight(.semibold)
                            }
                        }
                }
        }
        .tint(Palette.accent)
        .onAppear { store.refreshAppleAvailability() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refreshAppleAvailability() }
        }
    }
}

private enum SettingsDestination: String, Hashable {
    case connections, voice, web, appearance, conversations, diagnostics, about

    var title: LocalizedStringResource {
        switch self {
        case .connections: "Modèles et serveurs"
        case .voice: "Assistant vocal"
        case .web: "Recherche Web"
        case .appearance: "Apparence"
        case .conversations: "Conversations"
        case .diagnostics: "Diagnostic"
        case .about: "À propos d'Eudes"
        }
    }

    var subtitle: LocalizedStringResource? {
        switch self {
        case .connections: "Sur cet iPhone ou via une API"
        case .voice: "Voix, transcription et Siri"
        case .web: "Chat et mode vocal"
        case .appearance: "Thème, icône et transparence"
        case .conversations: "Menu, clavier et historique"
        case .diagnostics: "Journaux techniques"
        case .about: nil
        }
    }

    var symbol: String {
        switch self {
        case .connections: "server.rack"
        case .voice: "waveform"
        case .web: "globe"
        case .appearance: "circle.lefthalf.filled"
        case .conversations: "bubble.left"
        case .diagnostics: "ladybug"
        case .about: "info.circle"
        }
    }
}

private struct SettingsHomeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsHomeHeader()
                SettingsMenuGroup(title: "TON ASSISTANT") {
                    SettingsMenuRow(destination: .connections)
                    SettingsMenuDivider()
                    SettingsMenuRow(destination: .voice)
                    SettingsMenuDivider()
                    SettingsMenuRow(destination: .web)
                }
                SettingsMenuGroup(title: "PRÉFÉRENCES") {
                    SettingsMenuRow(destination: .appearance)
                    SettingsMenuDivider()
                    SettingsMenuRow(destination: .conversations)
                    SettingsMenuDivider()
                    SettingsMenuRow(destination: .diagnostics)
                }
                SettingsMenuRow(destination: .about)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .accessibilityIdentifier("settings.home")
    }
}

private struct SettingsHomeHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Réglages")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Ton IA, chez toi.")
                .font(.body)
                .foregroundStyle(Palette.muted)
        }
        .padding(.bottom, 4)
    }
}

private struct SettingsMenuGroup<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 14)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

private struct SettingsMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: Palette.separatorWidth)
            .padding(.leading, 68)
            .accessibilityHidden(true)
    }
}

private struct SettingsMenuRow: View {
    let destination: SettingsDestination

    var body: some View {
        NavigationLink(value: destination) {
            HStack(spacing: 14) {
                Image(systemName: destination.symbol)
                    .font(.title3.weight(.regular))
                    .frame(width: 40, height: 40)
                    .background(Palette.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination.title)
                        .font(.body.weight(destination == .about ? .medium : .semibold))
                    if let subtitle = destination.subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(minHeight: destination == .about ? 64 : 78)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings." + destination.rawValue)
    }
}

private struct SettingsDestinationView: View {
    let destination: SettingsDestination

    var body: some View {
        switch destination {
        case .connections:
            ConnectionSettingsView()
        case .voice:
            SettingsForm {
                VoiceModelSettingsSection()
                VoiceInstructionSettingsSection()
            }
        case .web:
            SettingsForm {
                WebSearchSettingsSection()
                WebToolBudgetSettingsSection()
            }
        case .appearance:
            AppearanceSettingsView()
        case .conversations:
            ConversationSettingsView()
        case .diagnostics:
            DiagnosticsSettingsView()
        case .about:
            AboutEudesSettingsView()
        }
    }
}

private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .scrollContentBackground(.hidden)
            .themedPanel()
    }
}

private struct ConnectionSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var inventory = LocalModelInventory()
    @State private var addServer = false
    @State private var editingServer: ServerProfile?
    @State private var duplicatingServer: ServerProfile?
    @State private var deletingServer: ServerProfile?

    var body: some View {
        SettingsForm {
            if store.connectionChoices.contains(where: { $0.isApple }) {
            Section {
                    Button {
                        store.selectServer(ServerProfile.appleID)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Modèle d'Apple").foregroundStyle(Palette.ink)
                                Text("Sur l'iPhone, sans réglage.").font(.caption).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            if store.selectedServer?.isApple == true {
                                Image(systemName: "checkmark").accessibilityLabel("Sélectionné")
                            }
                        }
                    }
                    .disabled(store.isPreparingSend)
                    NavigationLink {
                        ModelChoiceView(inventory: inventory)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Modèles").foregroundStyle(Palette.ink)
                            Text(catalogSummary).font(.caption).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .multilineTextAlignment(.leading)
                    }
                    .accessibilityIdentifier("models.choice")
            } header: { Text("Sur cet iPhone") }
            footer: { Text("Ces modèles tournent dans l'app : aucun message ne quitte l'appareil.") }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)
            }
            Section("Serveurs API") {
                ForEach(store.data.servers) { profile in
                    Button { editingServer = profile } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(profile.name).foregroundStyle(Palette.ink)
                                    if store.selectedServer?.id == profile.id {
                                        Text("Sélectionné").font(.caption).foregroundStyle(Palette.muted)
                                    }
                                }
                                Text(profile.baseURL).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                                Text(profile.model).font(.caption2).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                    .contextMenu { Button("Dupliquer", systemImage: "doc.on.doc") { duplicatingServer = profile } }
                    .swipeActions(edge: .leading) { Button("Dupliquer") { duplicatingServer = profile }.tint(Palette.accent) }
                    .swipeActions { Button("Supprimer") { deletingServer = profile }.tint(Palette.accent) }
                }
                Button { addServer = true } label: { Label("Ajouter un serveur", systemImage: "plus.circle") }
            }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)
        }
        .navigationTitle(Text("Modèles et serveurs"))
        .task { await inventory.refresh() }
        .sheet(isPresented: $addServer) { ServerEditorView() }
        .sheet(item: $editingServer) { ServerEditorView(profile: $0) }
        .sheet(item: $duplicatingServer) { ServerEditorView(duplicating: $0) }
        .alert("Supprimer ce serveur ?", isPresented: Binding(get: { deletingServer != nil }, set: { if !$0 { deletingServer = nil } })) {
            Button("Annuler", role: .cancel) { deletingServer = nil }
            Button("Supprimer") {
                if let profile = deletingServer { store.deleteServer(profile) }
                deletingServer = nil
            }
        } message: { Text("La clé API sera supprimée. Les anciennes conversations resteront lisibles, sans connexion à ce serveur.") }
    }

    /// Dit ce qu'on trouve derrière le chevron sans mentir sur l'état du disque :
    /// avant le premier balayage, une seule chose est sûre, le nombre de modèles.
    private var catalogSummary: String {
        let total = LocalModelCatalog.models.count
        guard inventory.hasScanned else { return "\(total) modèles" }
        let installed = inventory.installedCount
        return installed == 0 ? "\(total) modèles à télécharger" : "\(installed) sur \(total) installés"
    }
}

/// Immutable progress makes SwiftUI observe changes to a URLSessionTask,
/// whose state and byte counts mutate without changing the task's identity.
private struct LocalModelDownloadSnapshot: Equatable {
    let taskIdentifier: Int
    let taskDescription: String?
    let state: URLSessionTask.State
    let countOfBytesReceived: Int64

    init(_ task: URLSessionTask) {
        taskIdentifier = task.taskIdentifier
        taskDescription = task.taskDescription
        state = task.state
        countOfBytesReceived = task.countOfBytesReceived
    }
}

/// Une seule alerte pour les deux gestes : deux `.alert` sur la même vue, la seconde
/// remplace la première et le téléchargement ne demanderait plus jamais confirmation.
private enum PendingModelAction: Equatable {
    case download(LocalModelCatalog.Model)
    case remove(LocalModelCatalog.Model)

    var model: LocalModelCatalog.Model {
        switch self {
        case .download(let model), .remove(let model): model
        }
    }

    var isRemoval: Bool {
        if case .remove = self { return true }
        return false
    }
}

/// Inventaire partagé par les écrans du catalogue. Sorti de la vue parce que la liste
/// des familles et la fiche d'un modèle lisent le même état : un téléchargement lancé
/// sur une fiche doit apparaître dans la liste, et une empreinte déjà vérifiée ne doit
/// pas être recalculée à chaque retour.
private final class LocalModelInventory: ObservableObject {
    @Published private(set) var tasks: [String: [LocalModelDownloadSnapshot]] = [:]
    @Published private(set) var verified: Set<String> = []
    @Published private(set) var checking: Set<String> = []
    @Published private(set) var loadedID: String?
    @Published private(set) var loadedContext: Int?
    @Published private(set) var presentOnDisk: Set<String> = []
    @Published private(set) var invalidFiles: Set<String> = []
    @Published private(set) var hasScanned = false
    @Published var errorMessage: String?

    func isInstalled(_ model: LocalModelCatalog.Model) -> Bool {
        presentOnDisk.contains(model.id)
    }

    func activeTasks(_ model: LocalModelCatalog.Model) -> [LocalModelDownloadSnapshot] {
        tasks[model.id] ?? []
    }

    /// Nombre de modèles dont les fichiers sont sur l'appareil, sans attendre la
    /// vérification d'empreinte : une empreinte en cours ne rend pas le fichier absent.
    var installedCount: Int {
        LocalModelCatalog.models.filter { presentOnDisk.contains($0.id) }.count
    }

    @MainActor func markLoaded(_ id: String, context: Int) {
        loadedID = id
        loadedContext = context
    }

    @MainActor func clearLoaded() {
        loadedID = nil
        loadedContext = nil
    }

    @MainActor func reloadLoadedState() async {
        loadedID = await LocalModelRuntime.shared.loadedModelID()
        loadedContext = await LocalModelRuntime.shared.loadedContextSize()
    }

    @MainActor func refresh() async {
        let current = await LocalModelDownloads.shared.tasks()
        let snapshots = current.map(LocalModelDownloadSnapshot.init).sorted { $0.taskIdentifier < $1.taskIdentifier }
        tasks = Dictionary(grouping: snapshots.filter { LocalModelDownloads.resolve($0.taskDescription) != nil }, by: { LocalModelDownloads.resolve($0.taskDescription)!.0.id })
        loadedID = await LocalModelRuntime.shared.loadedModelID()
        loadedContext = await LocalModelRuntime.shared.loadedContextSize()
        for model in LocalModelCatalog.models {
            let onDisk = LocalModelDownloads.isInstalled(model)
            if onDisk {
                presentOnDisk.insert(model.id)
            } else {
                presentOnDisk.remove(model.id)
                invalidFiles.remove(model.id)
                // Un modèle supprimé ne doit pas garder sa validation : sinon l'écran
                // proposerait encore de charger un fichier absent.
                verified.remove(model.id)
            }
            // Un modèle chargé par le moteur prouve que ses fichiers sont bons : inutile de rehasher.
            if onDisk, loadedID == model.id { verified.insert(model.id); invalidFiles.remove(model.id) }
            guard onDisk, !verified.contains(model.id), !checking.contains(model.id),
                  tasks[model.id, default: []].isEmpty else { continue }
            checking.insert(model.id)
            Task {
                do { try await LocalModelRuntime.shared.verify(modelID: model.id); verified.insert(model.id); invalidFiles.remove(model.id) }
                catch is CancellationError {
                    // rien : une nouvelle vérification reprendra
                } catch {
                    // Une suppression ou une annulation pendant la vérification ne doit pas
                    // être présentée comme une empreinte fausse.
                    if LocalModelDownloads.isInstalled(model) {
                        invalidFiles.insert(model.id)
                        errorMessage = "L’empreinte de \(model.title) ne correspond pas au fichier attendu. Relance le téléchargement."
                    }
                }
                checking.remove(model.id)
            }
        }
        hasScanned = true
    }
}

/// L'écran des modèles : une seule décision à la fois. En haut le modèle utilisé,
/// ensuite la question qui compte pour qui découvre l'app, puis deux lignes discrètes
/// vers le catalogue complet et les réglages. Rien d'autre : ni identifiant d'appareil,
/// ni contexte maximal du modèle, ni nom de moteur.
private struct ModelChoiceView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var inventory: LocalModelInventory
    @State private var info: LocalModelCatalog.Model?
    @State private var showingInfo = false

    private var currentModel: LocalModelCatalog.Model? {
        guard store.selectedServer?.isLocalLFM == true,
              let model = LocalModelCatalog.models.first(where: { $0.id == store.selectedServer?.model }),
              inventory.isInstalled(model) else { return nil }
        return model
    }

    /// Qui répond aujourd'hui : le modèle local utilisé, sinon le modèle réel. Dérivé
    /// du magasin seul, sans balayage du disque : la ligne d'état ne clignote pas.
    private var engineTitle: String {
        guard let selected = store.selectedServer else { return "Aucun modèle" }
        if selected.isApple { return "Modèle d'Apple" }
        if selected.isLocalLFM {
            return LocalModelCatalog.models.first { $0.id == selected.model }?.title ?? "Aucun modèle"
        }
        return selected.name
    }

    private var engineSubtitle: String {
        guard let selected = store.selectedServer else { return "Choisis un usage ci-dessous." }
        if selected.isApple { return "L'iPhone répond, sans téléchargement." }
        if selected.isLocalLFM { return "Fichiers absents : télécharge-le depuis la liste ci-dessous." }
        return "Les réponses viennent de ce serveur."
    }

    var body: some View {
        SettingsForm {
            Section {
                if let model = currentModel {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(Palette.muted)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.title).foregroundStyle(Palette.ink)
                            Text(model.supportsImages ? "Texte et images · \(model.sizeLabel)" : "Texte · \(model.sizeLabel)")
                                .font(.caption).foregroundStyle(Palette.muted)
                            Text("Utilisé pour les messages")
                                .font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    // Le moteur réel, pas une absence : Apple ou un serveur API répondent
                    // aussi, et l'écran doit le dire. Dérivé du magasin seul, donc la
                    // ligne ne clignote pas pendant le premier balayage du disque.
                    Text(engineTitle).foregroundStyle(Palette.ink)
                    Text(engineSubtitle).font(.caption).foregroundStyle(Palette.muted)
                }
            } header: { Text("Modèle utilisé") }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)

            Section {
                ForEach(LocalModelCatalog.recommendations()) { recommendation in
                    ModelSummaryRow(model: recommendation.model, inventory: inventory,
                                    headline: recommendation.role.headline) {
                        info = recommendation.model
                        showingInfo = true
                    }
                }
            } header: { Text("Que veux-tu faire ?") }
            footer: { Text("Un seul suffit. Un modèle se télécharge une fois, puis fonctionne sans réseau.") }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)

            Section {
                NavigationLink {
                    ModelCatalogueView(inventory: inventory)
                } label: {
                    LabeledContent("Catalogue", value: "\(LocalModelCatalog.models.count) modèles · \(LocalModelCatalog.families.count) familles")
                }
                .accessibilityIdentifier("models.catalogue")
                NavigationLink {
                    AdvancedModelSettingsView(inventory: inventory)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Réglages avancés")
                        Text("Fenêtre, raisonnement, chargement").font(.caption).foregroundStyle(Palette.muted)
                    }
                    .multilineTextAlignment(.leading)
                }
                .accessibilityIdentifier("models.advanced")
            }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)
        }
        .navigationTitle(Text("Modèles"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingInfo) {
            if let info { ModelDetailView(model: info, inventory: inventory) }
        }
        .task { await inventory.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LocalModelDownloads.didChange)) { _ in
            Task { await inventory.refresh() }
        }
    }
}

/// Le catalogue complet, rangé par familles : c'est la vue « pour aller plus loin »,
/// pas le parcours de premier lancement.
private struct ModelCatalogueView: View {
    @ObservedObject var inventory: LocalModelInventory

    /// Ce qui est déjà sur l'appareil, par famille : sans cela, le compteur
    /// « N sur 13 installés » est invérifiable depuis le catalogue.
    private func installedCount(in family: LocalModelCatalog.Family) -> Int {
        family.models.filter { inventory.isInstalled($0) }.count
    }

    private func sizesLine(for family: LocalModelCatalog.Family) -> String {
        let installed = installedCount(in: family)
        guard installed > 0 else { return family.sizesLabel }
        return family.sizesLabel + " · " + (installed == 1 ? "1 installé" : "\(installed) installés")
    }

    var body: some View {
        SettingsForm {
            Section {
                ForEach(LocalModelCatalog.families) { family in
                    NavigationLink {
                        ModelFamilyView(family: family, inventory: inventory)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(family.name).font(.subheadline.weight(.semibold))
                            Text(family.summary).font(.caption).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(sizesLine(for: family)).font(.caption2).foregroundStyle(Palette.muted)
                        }
                        .multilineTextAlignment(.leading)
                    }
                }
            }
            footer: { Text("Un modèle téléchargé reste sur l'iPhone et fonctionne sans réseau. Les modèles trop lourds pour cet appareil restent visibles ; leur fiche dit la mémoire demandée.") }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)
        }
        .navigationTitle(Text("Tous les modèles"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await inventory.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LocalModelDownloads.didChange)) { _ in
            Task { await inventory.refresh() }
        }
    }
}

/// Un effort de raisonnement nommé : c'est la valeur de tokens qui part au moteur,
/// mais l'utilisateur choisit une intention, jamais un nombre.
private struct ReasoningTier: Identifiable {
    let tokens: Int
    let title: String
    var id: Int { tokens }
}

/// Les réglages qui servent à qui connaît déjà les modèles : moteur, fenêtre de
/// conversation, effort de raisonnement, chargement. Tout ce qui n'a pas sa place sur
/// les deux écrans principaux vit ici, et rien n'y est caché.
private struct AdvancedModelSettingsView: View {
    @EnvironmentObject private var store: AppStore
    /// Même clé que `AppStore.loadAtStartupKey` : la garde du préchargement et la case
    /// des Réglages doivent lire exactement la même préférence.
    @AppStorage("lfm.loadAtStartup") private var loadAtStartup = false
    /// L'inventaire reçu de l'écran Modèles : un seul état partagé, un seul balayage.
    @ObservedObject var inventory: LocalModelInventory
    @State private var loadingID: String?

    private static let tiers = [ReasoningTier(tokens: 512, title: "Rapide"),
                                ReasoningTier(tokens: 1024, title: "Équilibré"),
                                ReasoningTier(tokens: 2048, title: "Approfondi")]

    private var selectedModel: LocalModelCatalog.Model? {
        guard store.selectedServer?.isLocalLFM == true else { return nil }
        return LocalModelCatalog.models.first { $0.id == store.selectedServer?.model }
    }

    private var engineLabel: String {
        guard let selected = store.selectedServer else { return "Aucun" }
        if selected.isLocalLFM {
            return LocalModelCatalog.models.first { $0.id == selected.model }?.title ?? "Aucun"
        }
        if selected.isApple { return "Modèle d'Apple" }
        return selected.name
    }

    private var busy: Bool { store.isGenerating || store.isPreparingSend || loadingID != nil }

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Modèle utilisé", value: engineLabel)
                NavigationLink { ConnectionSettingsView() } label: { Text("Modèles et serveurs") }
            } header: { Text("Qui répond") }
            footer: { Text("Sur cet iPhone, rien ne quitte l'appareil. Une API envoie les messages au serveur configuré.") }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)

            Section {
                Picker("Fenêtre de conversation", selection: Binding(
                    get: { store.localContextStoredTokens }, set: { store.setLocalContextTokens($0) }
                )) {
                    Text("Automatique (\(store.automaticContextTokens.formatted()) tokens)")
                        .tag(LocalModelCatalog.automaticContext)
                    // Masquer l'option figée qui vaut déjà le calcul automatique : sinon deux
                    // entrées identiques et une coche ambiguë.
                    ForEach(LocalModelCatalog.contextOptions.filter { $0 != store.automaticContextTokens }, id: \.self) { value in
                        Text("\(value.formatted()) tokens").tag(value)
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("lfm.contextSize")
            } header: { Text("Fenêtre de conversation") }
            footer: { Text("C'est la mémoire gardée pour la conversation en cours. « Automatique » l'ajuste à la mémoire libre de l'iPhone.") }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)

            Section {
                Picker("Effort", selection: Binding(
                    get: { store.localReasoningTokens }, set: { store.setLocalReasoningTokens($0) }
                )) {
                    ForEach(Self.tiers) { tier in
                        Text(tier.title).tag(tier.tokens)
                    }
                    if !Self.tiers.contains(where: { $0.tokens == store.localReasoningTokens }) {
                        Text("\(store.localReasoningTokens.formatted()) tokens").tag(store.localReasoningTokens)
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("lfm.reasoningSize")
            } header: { Text("Qualité du raisonnement") }
            footer: { Text("Rapide répond tout de suite, Approfondi prend plus de temps sur les questions difficiles. Le raisonnement partage la fenêtre de conversation.") }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)

            Section {
                Toggle("Charger à l'ouverture d'Eudes", isOn: $loadAtStartup)
                    .onChange(of: loadAtStartup) { _, enabled in
                        // Décocher doit se voir tout de suite : sans ce déchargement le modèle
                        // reste résident jusqu'au prochain passage en arrière-plan et le
                        // réglage semble ignoré.
                        guard !enabled else { return }
                        Task { await unloadSelectedModel() }
                    }
                if let model = selectedModel {
                    Button {
                        loadingID = model.id
                        let selectedContext = store.localContextTokens
                        Task {
                            do {
                                try await LocalModelRuntime.shared.prepare(modelID: model.id, useGPU: true,
                                                                           contextTokens: selectedContext)
                                inventory.markLoaded(model.id, context: selectedContext)
                                inventory.errorMessage = nil
                            } catch {
                                await inventory.reloadLoadedState()
                                inventory.errorMessage = error.localizedDescription
                            }
                            loadingID = nil
                        }
                    } label: {
                        if loadingID == model.id { Label("Chargement…", systemImage: "hourglass") }
                        else if inventory.loadedID == model.id && inventory.loadedContext == store.localContextTokens { Label("Modèle chargé", systemImage: "checkmark.circle") }
                        else if inventory.loadedID == model.id { Label("Recharger avec la fenêtre choisie", systemImage: "arrow.clockwise") }
                        else { Label("Charger le modèle maintenant", systemImage: "play.circle") }
                    }
                    .disabled(!inventory.verified.contains(model.id) || loadingID != nil || (inventory.loadedID == model.id && inventory.loadedContext == store.localContextTokens))
                }
                if let message = inventory.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
            } header: { Text("Chargement") }
            footer: { Text("Un modèle chargé répond sans attente mais garde sa place en mémoire. Décoché, il se charge à la première question.") }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)
        }
        .navigationTitle(Text("Réglages avancés"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await inventory.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LocalModelDownloads.didChange)) { note in
            if let message = note.userInfo?["error"] as? String { inventory.errorMessage = message }
            Task { await inventory.refresh() }
        }
    }

    /// Décharge le modèle quand « Charger à l'ouverture » est décoché. Une génération en
    /// cours garde le moteur : le déchargement aura lieu au passage en arrière-plan.
    @MainActor private func unloadSelectedModel() async {
        guard !store.isGenerating, loadingID == nil else { return }
        try? await LocalModelRuntime.shared.unload()
        inventory.clearLoaded()
    }
}

/// Une famille : ses tailles, dans l'ordre du catalogue. Chaque ligne porte deux gestes
/// explicites — télécharger à droite, ouvrir les informations par le « i » — plutôt qu'une
/// navigation unique : sans cela, rien n'annonce qu'un modèle se télécharge depuis sa fiche.
private struct ModelFamilyView: View {
    let family: LocalModelCatalog.Family
    @ObservedObject var inventory: LocalModelInventory
    @State private var info: LocalModelCatalog.Model?
    @State private var showingInfo = false

    var body: some View {
        SettingsForm {
            Section {
                ForEach(family.models) { model in
                    ModelSummaryRow(model: model, inventory: inventory) {
                        info = model
                        showingInfo = true
                    }
                }
            } footer: { Text(family.summary) }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)
        }
        .navigationTitle(Text(family.name))
        .navigationBarTitleDisplayMode(.inline)
        // `LocalModelCatalog.Model` n'est pas `Hashable` : la destination se pilote donc
        // par un booléen, le modèle retenu étant gardé à côté.
        .navigationDestination(isPresented: $showingInfo) {
            if let info { ModelDetailView(model: info, inventory: inventory) }
        }
        .task { await inventory.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LocalModelDownloads.didChange)) { note in
            if let message = note.userInfo?["error"] as? String { inventory.errorMessage = message }
            Task { await inventory.refresh() }
        }
        .alert("Téléchargement impossible", isPresented: Binding(
            get: { inventory.errorMessage != nil }, set: { if !$0 { inventory.errorMessage = nil } })) {
            Button("OK", role: .cancel) { inventory.errorMessage = nil }
        } message: {
            Text(inventory.errorMessage ?? "")
        }
    }
}

/// Une ligne de modèle : le résumé à gauche, puis le téléchargement et le « i ».
private struct ModelSummaryRow: View {
    @EnvironmentObject private var store: AppStore
    let model: LocalModelCatalog.Model
    @ObservedObject var inventory: LocalModelInventory
    /// Quand la ligne répond à « Que veux-tu faire ? », le titre est l'intention et le
    /// modèle passe en second : c'est la question qui mène, pas le nom du fichier.
    var headline: String? = nil
    var onInfo: () -> Void

    @State private var confirmingDownload = false

    private var tooHeavy: String? { model.compatibilityLabel() }
    private var active: [LocalModelDownloadSnapshot] { inventory.activeTasks(model) }
    private var installed: Bool { inventory.isInstalled(model) }

    /// Part du poids déjà reçue : un fichier terminé compte pour sa taille entière, même
    /// si sa tâche n'apparaît plus dans la liste des téléchargements en cours.
    private var progress: Double {
        guard !active.isEmpty else { return 0 }
        let received = active.reduce(Int64(0)) { $0 + max(0, $1.countOfBytesReceived) }
            + model.assets.filter { asset in
                !active.contains { $0.taskDescription == LocalModelDownloads.identity(model: model, asset: asset) }
                    && FileManager.default.fileExists(atPath: LocalModelDownloads.destination(model: model, asset: asset).path)
            }.reduce(Int64(0)) { $0 + $1.size }
        return min(1, Double(received) / Double(max(1, model.downloadBytes)))
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let headline {
                    Text(headline).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("\(model.title) · \(model.sizeLabel)\(stateSuffix)").font(.caption).foregroundStyle(Palette.muted)
                } else {
                    Text(model.title).foregroundStyle(Palette.ink)
                    Text(model.capabilityDescription).font(.caption).foregroundStyle(Palette.muted)
                    Text("\(model.sizeLabel)\(stateSuffix)").font(.caption).foregroundStyle(Palette.muted)
                }
                if let tooHeavy {
                    Text(tooHeavy).font(.caption).foregroundStyle(Palette.warningText)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            downloadControl

            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.system(size: 19))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Informations sur \(model.title)")
            .accessibilityIdentifier("model.row.info.\(model.id)")
        }
        .alert("Télécharger le modèle ?", isPresented: $confirmingDownload) {
            Button("Télécharger \(model.title)") {
                inventory.errorMessage = nil
                Task {
                    await LocalModelDownloads.shared.start(model: model)
                    await inventory.refresh()
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            let size = ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file)
            Text("Taille : \(size). Le téléchargement peut continuer en arrière-plan et utiliser les données mobiles.")
        }
    }

    @ViewBuilder private var downloadControl: some View {
        if tooHeavy != nil {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 22))
                .foregroundStyle(Palette.muted.opacity(0.4))
                .frame(width: 32, height: 32)
                .accessibilityLabel("Téléchargement indisponible sur cet iPhone")
        } else if !active.isEmpty {
            // Un anneau plutôt qu'un bouton : le geste utile (pause, annuler) est sur la
            // fiche, et une icône cliquable pendant le transfert inviterait au doublon.
            ZStack {
                Circle().stroke(Palette.border, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            .frame(width: 32, height: 32)
            .accessibilityElement()
            .accessibilityLabel("Téléchargement de \(model.title)")
            .accessibilityValue("\(Int(progress * 100)) %")
            .accessibilityIdentifier("model.row.progress.\(model.id)")
        } else if installed && isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Palette.ink)
                .frame(width: 32, height: 32)
                .accessibilityLabel("\(model.title) est utilisé pour les messages")
        } else if installed {
            Button("Utiliser") { store.selectLocalModel(model.id) }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .disabled(store.isPreparingSend)
                .accessibilityLabel("Utiliser \(model.title) pour les messages")
                .accessibilityIdentifier("model.row.use.\(model.id)")
        } else {
            Button { confirmingDownload = true } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Télécharger \(model.title)")
            .accessibilityIdentifier("model.row.download.\(model.id)")
        }
    }

    private var isSelected: Bool {
        store.selectedServer?.isLocalLFM == true && store.selectedServer?.model == model.id
    }

    private var stateSuffix: String {
        if !active.isEmpty { return " · téléchargement en cours" }
        if installed && isSelected { return " · utilisé" }
        if installed { return " · installé" }
        return ""
    }
}

/// La fiche d'un modèle : ce qu'il sait faire, ce qu'il coûte en mémoire, et les deux
/// gestes utiles (télécharger, utiliser). Supprimer reste possible, une fois installé.
private struct ModelDetailView: View {
    @EnvironmentObject private var store: AppStore
    let model: LocalModelCatalog.Model
    @ObservedObject var inventory: LocalModelInventory
    var role: LocalModelCatalog.Role? = nil
    @State private var pendingAction: PendingModelAction?

    private var tooHeavy: String? { model.compatibilityLabel() }
    private var installed: Bool { inventory.isInstalled(model) }
    private var isSelected: Bool {
        store.selectedServer?.isLocalLFM == true && store.selectedServer?.model == model.id
    }
    /// Ce que le modèle demande pour tourner : poids du fichier plus le cache minimal.
    /// Un fait, pas un maximum théorique que l'iPhone n'atteindra jamais.
    private var memoryRequired: String {
        ByteCountFormatter.string(fromByteCount: Int64(model.compatibility().required), countStyle: .memory)
    }

    var body: some View {
        SettingsForm {
            Section {
                if let role {
                    Text(role.detail).font(.caption).foregroundStyle(Palette.muted)
                }
                Text(model.strength).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Taille", value: model.sizeLabel)
                LabeledContent("Mémoire requise", value: memoryRequired)
                LabeledContent("Images", value: model.supportsImages ? "lues" : "non")
                LabeledContent("Licence", value: model.licence)
            } header: { Text(model.title) }
            footer: { Text("Le nom technique et la licence servent à retrouver le fichier ; c’est le seul endroit de l’app où ils apparaissent.") }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)

            Section {
                if let tooHeavy {
                    Text(tooHeavy).font(.caption).foregroundStyle(Palette.warningText)
                }
                if installed && isSelected {
                    Label("Utilisé pour les messages", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(Palette.muted)
                } else if installed {
                    Button("Utiliser ce modèle") {
                        store.selectLocalModel(model.id)
                    }
                    .disabled(store.isPreparingSend || tooHeavy != nil)
                    .accessibilityIdentifier("model.use")
                }
                modelControls
                    .disabled(tooHeavy != nil)
            } footer: { Text("Un modèle téléchargé reste disponible sans réseau, qu’il soit utilisé ou non.") }
            .listRowBackground(Palette.surface)

            if installed {
                Section {
                    // Un geste visible plutôt qu'un balayage, qui n'est pas découvrable.
                    Button("Supprimer le modèle", role: .destructive) { pendingAction = .remove(model) }
                        .accessibilityIdentifier("model.delete")
                } footer: { Text("La suppression libère la place occupée par les fichiers. Tes conversations restent intactes.") }
                .listRowBackground(Palette.surface)
            }
        }
        .navigationTitle(Text(model.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { await inventory.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LocalModelDownloads.didChange)) { note in
            if let message = note.userInfo?["error"] as? String { inventory.errorMessage = message }
            Task { await inventory.refresh() }
        }
        // Une alerte au lieu d'un confirmationDialog : accroché à la section, il s'ancre
        // en bas de la page et passe inaperçu quand la ligne est loin dans la liste.
        .alert(pendingAction?.isRemoval == true ? "Supprimer le modèle ?" : "Télécharger le modèle ?",
               isPresented: Binding(
                get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            if let action = pendingAction {
                switch action {
                case .download(let target):
                    Button("Télécharger \(target.title)") {
                        inventory.errorMessage = nil
                        Task { await LocalModelDownloads.shared.start(model: target); await inventory.refresh() }
                    }
                case .remove(let target):
                    Button("Supprimer \(target.title)", role: .destructive) {
                        inventory.errorMessage = nil
                        Task {
                            do { try await store.deleteLocalModel(target.id) }
                            catch { inventory.errorMessage = error.localizedDescription }
                            await inventory.refresh()
                        }
                    }
                }
            }
            Button("Annuler", role: .cancel) { pendingAction = nil }
        } message: {
            if let action = pendingAction {
                let size = ByteCountFormatter.string(fromByteCount: action.model.downloadBytes, countStyle: .file)
                switch action {
                case .download:
                    Text("Taille : \(size). Le téléchargement peut continuer en arrière-plan et utiliser les données mobiles.")
                case .remove:
                    Text("\(size) seront libérés. Tes conversations restent intactes.")
                }
            }
        }
    }

    @ViewBuilder private var modelControls: some View {
        let active = inventory.activeTasks(model)
        if tooHeavy != nil {
            // La fiche entière est limitée : le bouton doit le dire, sinon il ressemble
            // à un téléchargement possible.
            Text("Indisponible sur cet iPhone").font(.caption).foregroundStyle(Palette.warningText)
        } else if !active.isEmpty {
            let bytes = active.reduce(Int64(0)) { $0 + max(0, $1.countOfBytesReceived) }
                + model.assets.filter { asset in !active.contains { $0.taskDescription == LocalModelDownloads.identity(model: model, asset: asset) } && FileManager.default.fileExists(atPath: LocalModelDownloads.destination(model: model, asset: asset).path) }.reduce(Int64(0)) { $0 + $1.size }
            ProgressView(value: min(1, Double(bytes) / Double(model.downloadBytes)))
            HStack {
                Text(active.allSatisfy { $0.state == .suspended } ? "En pause" : "Téléchargement…").font(.caption).foregroundStyle(Palette.muted)
                Spacer()
                Button(active.allSatisfy { $0.state == .suspended } ? "Reprendre" : "Pause") {
                    let pause = !active.allSatisfy { $0.state == .suspended }
                    Task { await LocalModelDownloads.shared.setPaused(pause, model: model); await inventory.refresh() }
                }
                Button("Annuler", role: .destructive) { Task { await LocalModelDownloads.shared.cancel(model: model); await inventory.refresh() } }
            }.font(.caption)
        } else if inventory.checking.contains(model.id) {
            Text("Vérification…").font(.caption).foregroundStyle(Palette.muted)
        } else if inventory.invalidFiles.contains(model.id) {
            // Le fichier est là mais son empreinte ne correspond pas : le dire, plutôt que
            // reproposer un téléchargement comme si rien n'était installé.
            HStack(spacing: 8) {
                Text("Fichier invalide").font(.caption).foregroundStyle(Palette.warningText)
                Button("Relancer le téléchargement") { pendingAction = .download(model) }
                    .font(.caption)
            }
        } else if inventory.verified.contains(model.id) {
            Label(inventory.loadedID == model.id ? "Téléchargé · chargé" : "Téléchargé", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(Palette.muted)
        } else if installed {
            // Le fichier occupe la bonne place : ne jamais afficher « Télécharger ».
            Text("Téléchargé · vérification en attente").font(.caption).foregroundStyle(Palette.muted)
        } else {
            Button("Télécharger · \(ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file))") { pendingAction = .download(model) }
                .font(.caption)
                .accessibilityIdentifier("model.download")
        }
    }
}

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var appliedIcon = UIApplication.shared.alternateIconName
    @State private var showIconChoice = false
    @State private var changingIcon = false
    @State private var iconError: String?

    var body: some View {
        SettingsForm {
            Section {
                Picker("Couleur", selection: Binding(
                    get: { store.appearance }, set: { store.setAppearance($0) }
                )) {
                    ForEach([AppAppearance.light, .dark, .automatic]) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .accessibilityIdentifier("appearance.mode")
                Toggle("Liquid Glass", isOn: Binding(
                    get: { store.liquidGlassEnabled }, set: { store.setLiquidGlassEnabled($0) }
                )).accessibilityIdentifier("appearance.liquidGlass")
                Text("Champs et boutons translucides sur iOS 26 ou ultérieur. Désactive cette option pour retrouver le style classique. Réduire la transparence conserve un fond opaque.")
                    .font(.caption).foregroundStyle(Palette.muted)
            } header: { Text("Apparence") }
            footer: { Text("Automatique suit l’apparence d’iOS. Le changement s’applique immédiatement.") }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)
            Section("Icône de l’app") {
                Button { showIconChoice = true } label: {
                    HStack(spacing: 14) {
                        Image(appliedIcon == "AppIconWhite" ? "RibbonWhite" : "RibbonDark")
                            .resizable().scaledToFit().frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                            .accessibilityHidden(true)
                        Text("Icône d'Eudes")
                        Spacer()
                        Text(appliedIcon == "AppIconWhite" ? "Blanche" : "Sombre")
                            .foregroundStyle(Palette.muted)
                    }
                }
                .accessibilityLabel("Changer l’icône d'Eudes")
                .accessibilityIdentifier("appearance.icon")
                .disabled(changingIcon || !UIApplication.shared.supportsAlternateIcons)
                if let iconError {
                    Text(iconError).font(.footnote).foregroundStyle(Palette.warningText)
                }
            }
            .listRowBackground(Palette.surface)
        }
        .confirmationDialog("Icône d'Eudes", isPresented: $showIconChoice, titleVisibility: .visible) {
            Button("Sombre") { changeIcon(nil) }
            Button("Blanche") { changeIcon("AppIconWhite") }
            Button("Annuler", role: .cancel) {}
        }
        .onAppear { appliedIcon = UIApplication.shared.alternateIconName }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { appliedIcon = UIApplication.shared.alternateIconName }
        }
    }

    private func changeIcon(_ name: String?) {
        guard !changingIcon, UIApplication.shared.supportsAlternateIcons,
              name != UIApplication.shared.alternateIconName else { return }
        changingIcon = true
        iconError = nil
        UIApplication.shared.setAlternateIconName(name) { error in
            Task { @MainActor in
                appliedIcon = UIApplication.shared.alternateIconName
                changingIcon = false
                if let error { iconError = "iOS a signalé un problème : " + error.localizedDescription + ". Le choix affiché correspond à l’état actuel du système." }
            }
        }
    }
}

private struct ConversationSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmErase = false

    var body: some View {
        SettingsForm {
            Section {
                Picker("Menu des conversations", selection: Binding(
                    get: { store.conversationMenuMode }, set: { store.setConversationMenuMode($0) }
                )) {
                    ForEach(ConversationMenuMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("conversationMenu.mode")
            } header: { Text("Présentation") }
            footer: { Text(store.conversationMenuMode.explanation) }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)
            Section {
                Toggle("Balayer pour une nouvelle conversation", isOn: $store.newConversationSwipeEnabled)
                    .accessibilityIdentifier("conversation.newConversationSwipe")
            } header: { Text("Nouvelle conversation") }
            footer: {
                Text("Dans les messages, balaie du bord droit vers le centre pour ouvrir une conversation vide. L’échange précédent reste dans l’historique. Le geste est inactif pendant une réponse.")
                if store.conversationMenuMode == .right {
                    Text("Quand ce geste est activé, utilise le bouton du menu pour ouvrir l’historique à droite.")
                }
            }
            .listRowBackground(Palette.surface)
            Section {
                Toggle("Ouvrir le clavier automatiquement", isOn: Binding(
                    get: { store.automaticKeyboard }, set: { store.setAutomaticKeyboard($0) }
                )).accessibilityIdentifier("keyboard.automatic")
            } header: { Text("Clavier des conversations") }
            footer: { Text("À l’entrée dans une conversation. Désactivé, touche le champ pour écrire. Ton brouillon reste conservé.") }
            .listRowBackground(Palette.surface)
            Section {
                Toggle("Correction et vérification orthographiques", isOn: Binding(
                    get: { store.spellCheckEnabled }, set: { store.setSpellCheckEnabled($0) }
                )).accessibilityIdentifier("keyboard.spellCheck")
            } header: { Text("Correcteur") }
            footer: { Text("Le clavier iOS souligne les fautes et peut corriger les mots automatiquement pendant la frappe, selon la langue et le clavier utilisés.") }
            .listRowBackground(Palette.surface)
            Section("Historique") {
                Button("Effacer toutes les conversations", role: .destructive) { confirmErase = true }
            }
            .listRowBackground(Palette.surface)
        }
        .alert("Effacer l’historique ?", isPresented: $confirmErase) {
            Button("Annuler", role: .cancel) {}
            Button("Tout effacer", role: .destructive) { store.eraseHistory() }
        } message: {
            Text("Toutes les conversations de cet iPhone seront supprimées. Les serveurs et leurs clés sont conservés.")
        }
    }
}

private struct AboutEudesSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                BrandMark(size: 72)
                VStack(spacing: 6) {
                    Text("Eudes").font(.title.bold())
                    Text("Ton IA, chez toi.").foregroundStyle(Palette.muted)
                    Text("Version \(AppRelease.displayVersion)")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
                Text("Conçu pour discuter simplement avec un modèle local. Connexion compatible OpenAI Chat Completions ou Responses ; pas de compte ni d’abonnement dans l’app.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.muted)
            }
            .padding(24)
            .padding(.top, 24)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .themedPanel()
    }
}

private struct WebSearchSettingsSection: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Section {
            Picker("Chat", selection: Binding(
                get: { store.chatWebSearchMode },
                set: { store.setChatWebSearchMode($0) }
            )) {
                ForEach(ChatWebSearchMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("webSearch.chatMode")

            Picker("Vocal", selection: Binding(
                get: { store.voiceWebSearchMode },
                set: { store.setVoiceWebSearchMode($0) }
            )) {
                ForEach(VoiceWebSearchMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("webSearch.voiceMode")
        }
        .listRowBackground(Palette.surface)
        .listRowSeparatorTint(Palette.border)
    }
}

private struct WebToolBudgetSettingsSection: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Section {
            WebToolBudgetEditor(limit: Binding(
                get: { store.webToolCallLimit },
                set: { store.setWebToolCallLimit($0) }
            ))
            .disabled(store.isGenerating || store.isPreparingSend)

            LabeledContent("À la limite", value: "Rédiger la réponse")
                .font(.subheadline)
        } header: {
            Text("Outils du modèle")
        } footer: {
            Text("Le compteur repart de zéro à chaque réponse. Ce réglage s’applique aux outils utilisés par le modèle.")
        }
        .listRowBackground(Palette.surface)
        .listRowSeparatorTint(Palette.border)
    }
}

private struct WebToolBudgetEditor: View {
    @Binding var limit: Int
    @State private var entry = ""
    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var valueFontSize = 44

    private var parsedEntry: Int? {
        guard let value = Int(entry.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Maximum d’appels par réponse")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                WebToolBudgetStepButton(symbol: "minus", label: "Retirer dix appels", identifier: "webSearch.toolLimit.decrease") {
                    change(by: -10)
                }
                .disabled(limit <= 1)

                VStack(spacing: 4) {
                    TextField("100", text: Binding(
                        get: { entry },
                        set: { value in
                            entry = value
                            if let parsedEntry { limit = parsedEntry }
                        }
                    ))
                    .keyboardType(.numberPad)
                    .focused($isFocused)
                    .font(.system(size: valueFontSize, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Maximum d’appels par réponse")
                    .accessibilityIdentifier("webSearch.toolLimit")
                    .onSubmit { finishEditing() }
                    Text("appels maximum")
                        .font(.caption).foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)

                WebToolBudgetStepButton(symbol: "plus", label: "Ajouter dix appels", identifier: "webSearch.toolLimit.increase") {
                    change(by: 10)
                }
                .disabled(limit == Int.max)
            }
            .padding(.vertical, 6)
            if isFocused, !entry.isEmpty, parsedEntry == nil {
                Text("Saisis un nombre entier supérieur à zéro.")
                    .font(.caption).foregroundStyle(Palette.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Recherches et lectures de pages partagent ce plafond. Le modèle peut s’arrêter dès qu’il a assez d’informations.")
                .font(.caption).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .onAppear { entry = String(limit) }
        .onChange(of: limit) { _, value in
            if !isFocused { entry = String(value) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { finishEditing() }
        }
        .onDisappear { finishEditing() }
        .toolbar {
            if isFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Terminé") { isFocused = false }
                }
            }
        }
    }

    private func finishEditing() {
        if let parsedEntry { limit = parsedEntry }
        entry = String(limit)
    }

    private func change(by delta: Int) {
        let value = (parsedEntry ?? limit).addingReportingOverflow(delta)
        limit = value.overflow ? Int.max : max(1, value.partialValue)
        entry = String(limit)
    }
}

private struct WebToolBudgetStepButton: View {
    let symbol: String
    let label: LocalizedStringResource
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 44, height: 44)
                .background(Palette.background, in: Circle())
                .overlay(Circle().stroke(Palette.border, lineWidth: Palette.separatorWidth))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }
}

private struct VoiceInstructionSettingsSection: View {
    @EnvironmentObject private var store: AppStore

    private var usesDefaultInstruction: Bool {
        store.voiceResponseInstruction == VoiceResponseInstruction.defaultText
    }

    var body: some View {
        Section {
            NavigationLink {
                VoiceInstructionEditorView(instruction: store.voiceResponseInstruction)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.title3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instruction vocale")
                        if usesDefaultInstruction {
                            Text("Réponses très brèves, sans emojis")
                                .font(.footnote)
                                .foregroundStyle(Palette.muted)
                        } else {
                            Text("Instruction personnalisée")
                                .font(.footnote)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("voice.instruction.settings")
        } header: {
            Text("RÉPONSES VOCALES")
        } footer: {
            Text("Une instruction personnalisable, utilisée uniquement en mode vocal.")
        }
        .listRowBackground(Palette.surface)
        .listRowSeparatorTint(Palette.border)
    }
}

private struct VoiceInstructionEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @FocusState private var editorFocused: Bool

    init(instruction: String) {
        _draft = State(initialValue: VoiceResponseInstruction.effectiveText(instruction))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VoiceInstructionEditorHeader()
                VoiceInstructionEditorField(draft: $draft, focused: $editorFocused)
                VoiceInstructionEditorActions(draft: $draft)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .navigationTitle("Instruction vocale")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            Button("Enregistrer") {
                editorFocused = false
                store.setVoiceResponseInstruction(draft)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("voice.instruction.save")
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .background(Palette.background)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Masquer le clavier", systemImage: "keyboard.chevron.compact.down") {
                    editorFocused = false
                }
                .labelStyle(.iconOnly)
            }
        }
        .accessibilityIdentifier("voice.instruction.editor")
    }
}

private struct VoiceInstructionEditorHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Des réponses faites pour l’oral.")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Cette instruction s’applique uniquement aux échanges vocaux.")
                .foregroundStyle(Palette.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VoiceInstructionEditorField: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    @ScaledMetric(relativeTo: .body) private var editorHeight = 360.0

    private var usesDefaultInstruction: Bool {
        VoiceResponseInstruction.effectiveText(draft) == VoiceResponseInstruction.defaultText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("INSTRUCTION")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 12)
                if usesDefaultInstruction {
                    Text("Par défaut")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Palette.surface, in: Capsule())
                }
            }
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .focused(focused)
                .frame(minHeight: editorHeight)
                .padding(12)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Instruction vocale")
                .accessibilityHint("Modifie le texte puis touche Enregistrer pour l’appliquer au mode vocal.")
                .accessibilityIdentifier("voice.instruction.text")
        }
    }
}

private struct VoiceInstructionEditorActions: View {
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("L’instruction par défaut est en anglais. Elle demande de répondre dans la langue de ta demande.")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                draft = VoiceResponseInstruction.defaultText
            } label: {
                Label("Rétablir l’instruction par défaut", systemImage: "arrow.counterclockwise")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(draft == VoiceResponseInstruction.defaultText)
            .accessibilityIdentifier("voice.instruction.reset")
        }
    }
}

private struct VoiceModelSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    private let apple = AppleSpeechModelManager.shared
    private let pocket = PocketTTSModelManager.shared
    @AppStorage(SpeechOutputEngine.preferenceKey) private var speechEngine = SpeechOutputEngine.system
    @AppStorage("voice.reply.identifier") private var voiceIdentifier = ""
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var checkingApple = true
    @State private var showSiriInformation = false
    @State private var showDownloadConfirmation = false
    @State private var showCellularConfirmation = false
    @State private var showLegacyRemoval = false
    @State private var legacyRemovalError: String?
    @AppStorage(BackgroundVoiceSession.lastErrorKey) private var backgroundVoiceError = ""
    private let backgroundSession = BackgroundVoiceSession.shared
    @Environment(\.scenePhase) private var scenePhase

    private var selectedVoiceTitle: String {
        guard !voiceIdentifier.isEmpty else { return "Par défaut" }
        return voices.first { $0.identifier == voiceIdentifier }?.name ?? "Indisponible"
    }

    private func refreshVoices() {
        voices = VoiceChoiceSettingsView.frenchVoices()
    }

    private var controlsBusy: Bool {
        apple.isPreparing || apple.isTranscribing || pocket.isDownloading
            || backgroundSession.isRunning || store.voiceAssistantRequested
    }

    private var appleStatus: LocalizedStringKey {
        if apple.isPreparing { return "Préparation…" }
        if checkingApple { return "Vérification…" }
        if !apple.isAvailable { return "Indisponible" }
        return apple.isReady ? "Modèle disponible" : "À préparer"
    }

    private var pocketStatus: LocalizedStringKey {
        if pocket.isDownloading { return "Téléchargement…" }
        return pocket.isDownloaded ? "Téléchargé" : "Non téléchargé"
    }

    var body: some View {
        Section {
            LabeledContent("Transcription") {
                Text("Apple · local").foregroundStyle(Palette.muted)
            }
            .accessibilityIdentifier("voice.transcription.engine")
            LabeledContent("Apple") {
                Text(appleStatus).foregroundStyle(Palette.muted)
            }
            .accessibilityIdentifier("voice.apple.status")
            if !checkingApple && apple.isAvailable && !apple.isReady {
                Text("Ouvre l’assistant vocal dans Eudes une première fois pour préparer la transcription avant de l’utiliser avec Siri.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            if let message = apple.errorMessage {
                Text(message).font(.footnote).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("voice.apple.message")
            }
            HStack {
                Toggle("Siri, écran verrouillé", isOn: Binding(
                    get: { store.siriWhileLockedEnabled },
                    set: { store.setSiriWhileLocked($0) }
                ))
                .accessibilityIdentifier("voice.siri.locked")
                Button {
                    showSiriInformation = true
                } label: {
                    Image(systemName: "info.circle")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Informations sur Siri et l’écran verrouillé")
                .accessibilityIdentifier("voice.siri.info")
            }
            .alert("Siri, écran verrouillé", isPresented: $showSiriInformation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Dis « Siri, parler à Eudes mains libres » pour discuter sans ouvrir l’écran d'Eudes, même écran verrouillé si cette option est activée. « Siri, ouvre l’assistant vocal Eudes » démarre également cette même session mains libres. Touche l’activité pour afficher l’interface et utiliser les actions sur l’iPhone, après déverrouillage si nécessaire. Une activité affiche l’écoute mains libres et permet de l’arrêter. Le serveur, sa clé et les échanges en attente restent accessibles après le premier déverrouillage. Le fonctionnement dans CarPlay reste à vérifier.")
            }
            if let error = store.siriConfigurationError {
                Text(error).font(.footnote).foregroundStyle(Palette.warningText)
                    .accessibilityIdentifier("voice.siri.error")
            }
            if !backgroundVoiceError.isEmpty {
                Text(backgroundVoiceError).font(.footnote).foregroundStyle(Palette.warningText)
                    .accessibilityIdentifier("voice.background.error")
            }
            if backgroundSession.isRunning {
                Button("Arrêter l’assistant vocal", systemImage: "stop.circle") {
                    Task { await backgroundSession.stop() }
                }
                .accessibilityIdentifier("voice.background.stop")
                Text("Arrête l’assistant vocal avant de changer de voix.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }

            Picker("Synthèse vocale", selection: $speechEngine) {
                ForEach(SpeechOutputEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .accessibilityIdentifier("voice.speech.engine")
            .onChange(of: speechEngine) { _, _ in
                backgroundVoiceError = ""
            }

            if speechEngine == .pocketTTS {
                Picker("Modèle PocketTTS", selection: Binding(
                    get: { pocket.variant },
                    set: { pocket.selectVariant($0) }
                )) {
                    ForEach(PocketTTSVariant.allCases) { variant in
                        Text(variant.title).tag(variant)
                    }
                }
                .disabled(controlsBusy)
                .accessibilityIdentifier("voice.pocket.variant")
                LabeledContent("PocketTTS") {
                    Text(pocketStatus).foregroundStyle(Palette.muted)
                }
                .accessibilityIdentifier("voice.pocket.status")
                if pocket.isDownloading {
                    VStack(spacing: 8) {
                        ModelDownloadProgressView(stage: pocket.downloadStage)
                            .accessibilityIdentifier("voice.pocket.downloadProgress")
                        Button("Annuler le téléchargement") { pocket.cancelDownload() }
                            .disabled(pocket.downloadStage == .cancelling)
                    }
                } else if pocket.isDownloaded {
                    NavigationLink {
                        PocketTTSSettingsView()
                    } label: {
                        HStack {
                            Label("Voix PocketTTS", systemImage: "waveform")
                            Spacer()
                            Text((pocket.availableVoices.first { $0.id == PocketTTSVoices.selected().id } ?? pocket.availableVoices.first { $0.id == PocketTTSVoices.defaultID })?.displayName ?? "Estelle")
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityIdentifier("voice.pocket.settings")
                } else {
                    Button {
                        showDownloadConfirmation = true
                    } label: {
                        Label("Télécharger PocketTTS · environ \(pocket.estimatedDownloadMegabytes) Mo", systemImage: "arrow.down.circle")
                    }
                    .disabled(controlsBusy)
                    .accessibilityIdentifier("voice.pocket.download")
                }
                if pocket.hasLegacyModel {
                    Button("Supprimer l’ancien modèle ONNX") { showLegacyRemoval = true }
                        .disabled(controlsBusy)
                        .accessibilityIdentifier("voice.pocket.removeLegacy")
                }
                if let legacyRemovalError {
                    Text(legacyRemovalError).font(.footnote).foregroundStyle(Palette.warningText)
                }
                if let error = pocket.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(Palette.warningText)
                        .accessibilityIdentifier("voice.pocket.error")
                }
                Text("PocketTTS lit tes réponses en français sur cet iPhone. Le modèle n’est téléchargé qu’après ton accord, puis fonctionne hors ligne.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            } else {
                NavigationLink {
                    VoiceChoiceSettingsView()
                } label: {
                    HStack {
                        Label("Voix de l’assistant", systemImage: "speaker.wave.2")
                        Spacer()
                        Text(selectedVoiceTitle)
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("voice.output.settings")
            }
        } header: {
            Text("Assistant vocal")
        } footer: {
            Text("Apple transcrit ta voix sur cet iPhone. Seul le texte est transmis au modèle de conversation choisi s’il est distant. Pour la lecture, choisis les voix système iOS ou le modèle local PocketTTS.")
        }
        .listRowBackground(Palette.surface)
        .listRowSeparatorTint(Palette.border)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            refreshVoices()
            checkingApple = true
            await apple.refreshAvailability()
            checkingApple = false
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            refreshVoices()
        }
        .alert("Télécharger PocketTTS ?", isPresented: $showDownloadConfirmation) {
            Button("Annuler", role: .cancel) {}
            Button("Télécharger") {
                Task { @MainActor in
                    if NetworkMonitor.requiresCellularConfirmation(usesCellular: await NetworkMonitor.usesCellular()) {
                        showCellularConfirmation = true
                    } else {
                        await pocket.download()
                    }
                }
            }
        } message: {
            Text("Le modèle PocketTTS et ses voix (environ \(pocket.estimatedDownloadMegabytes) Mo) seront téléchargés depuis Hugging Face, puis utilisés hors ligne sur cet iPhone.")
        }
        .alert("Supprimer l’ancien modèle ?", isPresented: $showLegacyRemoval) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) {
                do { try pocket.removeLegacyModel(); legacyRemovalError = nil }
                catch { legacyRemovalError = "Impossible de supprimer l’ancien modèle : " + error.localizedDescription }
            }
        } message: {
            Text("Le modèle Core ML et tes conversations seront conservés.")
        }
        .alert("Utiliser les données cellulaires ?", isPresented: $showCellularConfirmation) {
            Button("Annuler", role: .cancel) {}
            Button("Télécharger en cellulaire") {
                Task { @MainActor in await pocket.download() }
            }
        } message: {
            Text("Tu es connecté en données cellulaires. Ce téléchargement d’environ \(pocket.estimatedDownloadMegabytes) Mo peut être facturé par ton opérateur.")
        }
    }


}

/// Chooses among installed system voices; audio preview never changes selection.
@MainActor
private struct VoiceChoiceSettingsView: View {
    @AppStorage("voice.reply.identifier") private var voiceIdentifier = ""
    @AppStorage("voice.reply.rate") private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @Environment(\.scenePhase) private var scenePhase
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var synthesizer = Self.makePreviewSynthesizer()

    private static func makePreviewSynthesizer() -> AVSpeechSynthesizer {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.usesApplicationAudioSession = false
        return synthesizer
    }

    static func frenchVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("fr-") || $0.language.lowercased() == "fr" }
            .sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.identifier < $1.identifier : comparison == .orderedAscending
            }
    }

    private var selectedVoiceUnavailable: Bool {
        !voiceIdentifier.isEmpty && !voices.contains { $0.identifier == voiceIdentifier }
    }

    var body: some View {
        Form {
            Section {
                choiceRow(identifier: "", title: "Par défaut", detail: "Voix française automatique")
                ForEach(voices, id: \.identifier) { voice in
                    choiceRow(identifier: voice.identifier, title: voice.name, detail: voiceDetail(voice))
                }
            } header: {
                Text("Choisis une voix")
            } footer: {
                Text("Voix françaises disponibles sur cet iPhone. Pour en ajouter, consulte les réglages d’accessibilité d’iOS.")
            }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)

            if selectedVoiceUnavailable {
                Section {
                    Text("La voix choisie n’est plus disponible. La voix par défaut sera utilisée ; tu peux en choisir une autre.")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }
                .listRowBackground(Palette.surface)
            }

            Section {
                HStack {
                    Text("Vitesse de la voix")
                    Spacer()
                    Text(rate == Double(AVSpeechUtteranceDefaultSpeechRate) ? "Normale" : (rate / Double(AVSpeechUtteranceDefaultSpeechRate)).formatted(.percent.precision(.fractionLength(0))))
                        .foregroundStyle(Palette.muted)
                }
                Slider(value: $rate, in: 0.35...0.6, step: 0.01)
                    .accessibilityLabel("Vitesse de la voix")
                    .accessibilityIdentifier("voice.output.rate")
                Button("Rétablir la vitesse normale") {
                    rate = Double(AVSpeechUtteranceDefaultSpeechRate)
                }
            }
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.border)
        }
        .scrollContentBackground(.hidden)
        .themedPanel()
        .navigationTitle("Voix de l’assistant")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { voices = Self.frenchVoices() }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            voices = Self.frenchVoices()
        }
        .onDisappear { synthesizer.stopSpeaking(at: .immediate) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { voices = Self.frenchVoices() }
            else { synthesizer.stopSpeaking(at: .immediate) }
        }
    }

    private func voiceDetail(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium: quality = "Premium"
        case .enhanced: quality = "Améliorée"
        default: quality = "Standard"
        }
        return "\(voice.language) · \(quality)"
    }

    private func choiceRow(identifier: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Button {
                synthesizer.stopSpeaking(at: .immediate)
                voiceIdentifier = identifier
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).foregroundStyle(Palette.ink)
                        Text(detail).font(.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    if voiceIdentifier == identifier || (identifier.isEmpty && selectedVoiceUnavailable) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Palette.ink)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(voiceIdentifier == identifier || (identifier.isEmpty && selectedVoiceUnavailable) ? "Sélectionnée" : "")
            .accessibilityIdentifier(identifier.isEmpty ? "voice.output.default" : "voice.output.choice.\(identifier)")

            Button {
                synthesizer.stopSpeaking(at: .immediate)
                let utterance = VoiceOutputSettings.makeUtterance(
                    text: "Bonjour, je suis ton assistante Eudes. Comment puis-je t’aider ?",
                    voiceIdentifier: identifier,
                    rate: rate
                )
                synthesizer.speak(utterance)
            } label: {
                Image(systemName: "play.fill")
                    .frame(width: 44, height: 44)
                    .background(Palette.surface, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Écouter la voix \(title)")
        }
    }
}

/// Shared progress view for on-demand model downloads in settings.
struct ModelDownloadProgressView: View {
    let stage: ModelDownloadStage

    var body: some View {
        switch stage {
        case .listing:
            ProgressView("Recherche des fichiers du modèle…")
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Téléchargement du modèle · estimation")
                    Spacer()
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .font(.subheadline)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Téléchargement du modèle vocal")
            }
            .frame(maxWidth: .infinity)
        case .preparing:
            ProgressView("Préparation du modèle…")
        case .cancelling:
            ProgressView("Annulation du téléchargement…")
        }
    }
}

/// PocketTTS voice picker and model management. Only commercial-safe voices
/// (CC0 / CC-BY-4.0 sources) are listed; the CC-NC presets are excluded.
struct PocketTTSSettingsView: View {
    private let manager = PocketTTSModelManager.shared
    @AppStorage(PocketTTSVoices.preferenceKey) private var selectedVoiceID = PocketTTSVoices.defaultID
    @State private var confirmRemoval = false
    @State private var confirmLegacyRemoval = false
    @State private var removalError: String?
    @State private var previewError: String?
    @State private var voiceSelectionChanged = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewingVoiceID: String?
    @AppStorage(SpeechOutputEngine.preferenceKey) private var speechEngine = SpeechOutputEngine.system.rawValue

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 110, height: 110)
                        .background(Palette.surface, in: Circle())
                    Text("PocketTTS")
                        .font(.title.bold())
                    Text("Synthèse vocale en français sur cet iPhone")
                        .foregroundStyle(Palette.muted)
                }
                .padding(.top, 20)

                if voiceSelectionChanged {
                    Text("La voix précédemment sélectionnée n’est pas disponible avec ce modèle. Estelle est sélectionnée.")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }

                if manager.isDownloading {
                    VStack(spacing: 12) {
                        ModelDownloadProgressView(stage: manager.downloadStage)
                            .accessibilityIdentifier("voice.model.downloadProgress")
                        Button("Annuler le téléchargement") { manager.cancelDownload() }
                            .disabled(manager.downloadStage == .cancelling)
                    }
                } else if manager.isDownloaded {
                    Label("Modèle téléchargé", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.ink)
                        .accessibilityIdentifier("voice.model.downloaded")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voix disponibles (\(manager.availableVoices.count))")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                        Text("Seules les voix à licence compatible avec un usage commercial (CC0 ou CC-BY-4.0) sont proposées.")
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                    }
                    ForEach(manager.availableVoices) { voice in
                        HStack(spacing: 12) {
                            Button {
                                selectedVoiceID = voice.id
                            } label: {
                                HStack {
                                    Text(voice.displayName).foregroundStyle(Palette.ink)
                                    Spacer()
                                    if selectedVoiceID == voice.id {
                                        Image(systemName: "checkmark").foregroundStyle(Palette.ink)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("voice.pocket.choice.\(voice.id)")
                            Button {
                                previewError = nil
                                previewingVoiceID = voice.id
                                previewTask = Task { @MainActor in
                                    defer { previewingVoiceID = nil; previewTask = nil }
                                    do { try await manager.preview(voice) }
                                    catch is CancellationError { }
                                    catch { if !Task.isCancelled { previewError = error.localizedDescription } }
                                }
                            } label: {
                                Image(systemName: previewingVoiceID == voice.id ? "hourglass" : "play.fill")
                                    .frame(width: 44, height: 44)
                                    .background(Palette.surface, in: Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Écouter la voix \(voice.displayName)")
                            .disabled(previewingVoiceID != nil)
                        }
                    }
                    Button("Supprimer le modèle", role: .destructive) { confirmRemoval = true }
                        .accessibilityIdentifier("voice.model.remove")
                } else {
                    Text("Le modèle sera proposé au téléchargement depuis les réglages de l’assistant vocal.")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }

                if manager.hasLegacyModel {
                    Button("Supprimer l’ancien modèle ONNX") { confirmLegacyRemoval = true }
                        .disabled(manager.isDownloading)
                        .accessibilityIdentifier("voice.model.removeLegacy")
                    Text("L’ancien modèle téléchargé est conservé jusqu’à sa suppression.")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }

                if let message = manager.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Palette.warningText)
                        .accessibilityIdentifier("voice.model.error")
                }
                if let removalError {
                    Text(removalError)
                        .font(.footnote)
                        .foregroundStyle(Palette.warningText)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Crédits et licences")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text("PocketTTS par Kyutai (CC-BY-4.0) — attribution requise dans l’app.")
                    Link("Modèle PocketTTS et licence CC-BY-4.0", destination: URL(string: "https://huggingface.co/kyutai/pocket-tts")!)
                    Text("Moteur Core ML d'Eudes ; composants adaptés de FluidAudio (Apache-2.0) ; voix Kyutai (CC0, CC-BY-4.0).")
                    if manager.variant == .french6 {
                        Link("Conversion Core ML française par Line of Flight", destination: URL(string: "https://huggingface.co/lineofflight/pocket-tts-coreml")!)
                    }
                    Link("Composants libres et attribution", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
                    Link("Voix de référence Kyutai", destination: URL(string: "https://huggingface.co/kyutai/tts-voices")!)
                }
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .accessibilityIdentifier("voice.model.credits")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Licence de l’application")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Eudes est un logiciel libre distribué sous GNU GPL v3, avec une permission supplémentaire autorisant une distribution par les magasins d’applications. Le texte complet accompagne l’application et le code source correspondant est publié.")
                    Link("Texte de la licence (GPL v3)", destination: URL(string: "https://github.com/Eudes-app/Eudes/blob/main/LICENSE")!)
                    Link("Permission supplémentaire (section 7)", destination: URL(string: "https://github.com/Eudes-app/Eudes/blob/main/LICENSE-EXCEPTIONS.md")!)
                    Link("Code source d’Eudes", destination: URL(string: "https://github.com/Eudes-app/Eudes")!)
                }
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .accessibilityIdentifier("app.license")
            }
            .padding(20)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .themedPanel()
        .navigationTitle("PocketTTS")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !manager.availableVoices.contains(where: { $0.id == selectedVoiceID }) {
                selectedVoiceID = PocketTTSVoices.defaultID
                voiceSelectionChanged = true
            }
        }
        .onDisappear {
            previewTask?.cancel()
            manager.cancelSpeak()
        }
        .alert("Aperçu indisponible", isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) {
            Button("Utiliser les voix iOS") { speechEngine = SpeechOutputEngine.system.rawValue }
            Button("Fermer", role: .cancel) { previewError = nil }
        } message: {
            Text(previewError ?? "")
        }
        .alert("Supprimer l’ancien modèle ?", isPresented: $confirmLegacyRemoval) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) {
                do { try manager.removeLegacyModel(); removalError = nil }
                catch { removalError = "Impossible de supprimer l’ancien modèle : " + error.localizedDescription }
            }
        } message: {
            Text("Le modèle Core ML et tes conversations seront conservés.")
        }
        .alert("Supprimer le modèle PocketTTS ?", isPresented: $confirmRemoval) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) {
                do {
                    try manager.removeModel()
                    removalError = nil
                } catch {
                    removalError = "Impossible de supprimer le modèle : " + error.localizedDescription
                }
            }
        } message: {
            Text("Il faudra le télécharger à nouveau pour utiliser PocketTTS.")
        }
    }
}


struct ContextBudgetEditor: View {
    let profile: ServerProfile
    let model: String
    let requestedOutput: Int?
    @Binding var budget: Int?
    @State private var entry = ""
    private var invalid: Bool { !entry.isEmpty && (Int(entry) == nil || !(1...100_000_000).contains(Int(entry) ?? 0)) }
    private func refresh() { entry = profile.maximumContext(for: model).map(String.init) ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Contexte maximal du modèle").fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Non renseigné", text: Binding(get: { entry }, set: { text in
                    entry = text
                    if text.isEmpty { budget = nil }
                    else if let value = Int(text), (1...100_000_000).contains(value) { budget = value }
                }))
                .keyboardType(.numberPad)
                .accessibilityLabel("Contexte maximal du modèle en tokens")
                .accessibilityIdentifier("model.maximumContext")
                .disabled(model.isEmpty)
                Text("tokens").font(.footnote).foregroundStyle(Palette.muted)
            }
            if invalid { Text("Saisis un entier de 1 à 100 000 000.").font(.footnote).foregroundStyle(Palette.warningText) }
            Text(profile.hasManualContext(for: model) ? "Valeur saisie manuellement." : (profile.maximumContext(for: model) == nil ? "Non communiqué par l’API. Tu peux renseigner cette valeur." : "Valeur communiquée par l’API ou le modèle local."))
                .font(.footnote).foregroundStyle(Palette.muted)
        }
        .onAppear(perform: refresh)
        .onChange(of: profile.visionKey(model)) { _, _ in refresh() }
        .onChange(of: profile.maximumContext(for: model)) { _, _ in if !invalid { refresh() } }
    }
}

struct ModelCapabilitiesView: View {
    let profile: ServerProfile
    let model: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            capability("Images", status: profile.capabilities(for: model).images)
            capability("Documents PDF", status: profile.capabilities(for: model).pdf)
            Text("Selon les informations explicites du modèle. Eudes ne joint pas de PDF ; la prise en charge des images ne permet pas de la déduire.")
                .font(.footnote).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)

        }
    }
    private func capability(_ title: String, status: CapabilityStatus) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(status.title).foregroundStyle(Palette.muted).multilineTextAlignment(.trailing)
        }.accessibilityElement(children: .combine)
    }
}


struct ModelOutputCapacityView: View {
    let profile: ServerProfile
    let model: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Longueur maximale de la réponse du modèle").fixedSize(horizontal: false, vertical: true)
            if let value = profile.limits(for: model).outputLimit {
                Text("\(value) tokens").accessibilityIdentifier("model.outputCapacity")
                Text("Annoncée par l’API : " + profile.limits(for: model).output.map(\.source).joined(separator: ", "))
                    .font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Non renseignée").foregroundStyle(Palette.muted).accessibilityIdentifier("model.outputCapacity")
            }
        }.accessibilityElement(children: .combine)
    }
}

/// Journal technique consultable depuis les Réglages.
///
/// Sert à comprendre les échecs (recherche Web, modèle Apple, vocal) sans Mac ni Xcode.
/// Aucune donnée ne quitte l'iPhone et rien n'est écrit sur disque : les entrées vivent
/// en mémoire, le temps d'être copiées au moment du problème.
private struct DiagnosticsSettingsView: View {
    @StateObject private var log = DiagnosticLog.shared
    @StateObject private var report = LocalEngineReport.shared
    @State private var copied = false
    @State private var filter: DiagnosticCategory?
    @AppStorage(LocalEngineDiagnostics.traceKey) private var traceEngine = false

    private var visibleEntries: [DiagnosticEntry] {
        let entries = filter.map { category in log.entries.filter { $0.category == category } } ?? log.entries
        return Array(entries.reversed())
    }

    private var categories: [DiagnosticCategory] {
        DiagnosticCategory.allCases.filter { category in
            log.entries.contains { $0.category == category }
        }
    }

    var body: some View {
        SettingsForm {
            Section {
                if let generation = report.generation {
                    LabeledContent("Modèle", value: generation.modelTitle)
                    LabeledContent("Décodage", value: String(format: "%.1f tok/s", generation.decodeRate))
                    LabeledContent("Prefill", value: String(format: "%.0f tok/s en %.1f s",
                                                             generation.prefillRate, generation.prefillSeconds))
                    LabeledContent("Cache de prompt", value: generation.cachedTokens > 0
                                   ? "\(generation.cachedTokens) tokens réutilisés"
                                   : "aucun")
                    LabeledContent("Dernière réponse", value: String(format: "%d tokens en %.1f s",
                                                                     generation.answerTokens, generation.decodeSeconds))
                    LabeledContent("Téléphone", value: generation.lowPower
                                   ? "\(generation.thermal) · économie d’énergie"
                                   : generation.thermal)
                } else {
                    Text("Aucune réponse du modèle local depuis l’ouverture de l’app.")
                        .foregroundStyle(.secondary)
                }
                if let verification = report.verification {
                    LabeledContent("Vérification d’empreinte",
                                   value: String(format: "%.2f s%@", verification.seconds,
                                                 verification.reused ? " (cache)" : " (hachage)"))
                }
                Toggle("Tracer chaque génération", isOn: $traceEngine)
            } header: {
                Text("Moteur local")
            } footer: {
                Text(traceEngine
                     ? "Chaque réponse écrit ses mesures dans le journal ci-dessous."
                     : "Le journal ne retient que les mesures anormales : décodage lent, téléphone chaud ou mode économie d’énergie.")
            }
            if !log.entries.isEmpty {
                Section {
                    Picker("Catégorie", selection: $filter) {
                        Text("Toutes les catégories").tag(DiagnosticCategory?.none)
                        ForEach(categories) { category in
                            Text(category.label).tag(DiagnosticCategory?.some(category))
                        }
                    }
                }
            }

            Section {
                if visibleEntries.isEmpty {
                    Text(log.entries.isEmpty ? "Aucun événement enregistré."
                        : "Aucun événement pour cette catégorie.")
                        .foregroundStyle(Palette.muted)
                } else {
                    ForEach(visibleEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(entry.category.label.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Palette.muted)
                                if entry.repeatCount > 1 {
                                    Text("×\(entry.repeatCount)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                Text(entry.level.label)
                                    .font(.caption2)
                                    .foregroundStyle(levelColor(entry.level))
                            }
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = entry.detail, detail != entry.message {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(Palette.muted)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Événements récents")
            } footer: {
                Text("Ces journaux restent sur cet iPhone et ne sont jamais envoyés. "
                    + "\(log.entries.count) entrée(s) en mémoire ; le journal se vide à la fermeture de l’app.")
            }

            Section {
                Button(copied ? "Journal copié" : "Copier le journal") {
                    UIPasteboard.general.string = log.text()
                    copied = true
                }
                .disabled(visibleEntries.isEmpty)
                ShareLink(item: log.text()) {
                    Text("Partager le journal")
                }
                .disabled(log.entries.isEmpty)
                Button("Effacer", role: .destructive) { log.clear() }
                    .disabled(log.entries.isEmpty)
            }
        }
        .onDisappear { copied = false }
    }

    private func levelColor(_ level: DiagnosticLevel) -> Color {
        switch level {
        case .info: return Palette.muted
        case .warning: return Palette.ink
        case .error: return Palette.warningText
        }
    }
}

