import SwiftUI

enum ServerEditorSection: String {
    case server, model
}

struct ServerEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ServerProfile
    @State private var apiKey = ""
    @State private var availableModels: [String] = []
    @State private var showModels = false
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testSucceeded = false
    @State private var keyLoadFailed = false
    @State private var testTask: Task<Void, Never>?
    @StateObject private var metadataRefresh = ModelMetadataRefresh()
    private let isEditing: Bool
    private let isDuplicate: Bool
    private let initialSection: ServerEditorSection?

    init(profile: ServerProfile? = nil, initialSection: ServerEditorSection? = nil) {
        isDuplicate = false
        self.initialSection = initialSection
        isEditing = profile != nil
        _profile = State(initialValue: profile ?? ServerProfile())
    }

    init(duplicating original: ServerProfile) {
        initialSection = nil
        isEditing = false
        isDuplicate = true
        _profile = State(initialValue: original.duplicate())
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            Form {
                Section {
                    LabeledContent("Nom") {
                        TextField("Spark GB10", text: $profile.name)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(Palette.muted)
                            .accessibilityLabel("Nom du serveur")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Adresse API")
                        TextField("http://192.168.1.10:8000/v1", text: $profile.baseURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.subheadline)
                            .foregroundStyle(Palette.muted)
                            .accessibilityLabel("Adresse de base de l’API")
                    }
                    Picker("Protocole", selection: $profile.protocolKind) {
                        ForEach(APIProtocol.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("server.protocol")
                    LabeledContent("Clé API") {
                        SecureField("Facultative", text: Binding(
                            get: { apiKey },
                            set: { apiKey = $0; resetTest() }
                        ))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Palette.muted)
                        .accessibilityLabel("Clé API, facultative")
                    }
                } header: {
                    Text("Serveur").id(ServerEditorSection.server)
                } footer: {
                    if profile.protocolKind == .responses {
                        if profile.usesOpenAIBackground {
                            Text("Responses : historique transmis explicitement. OpenAI conserve temporairement les données de réponse pour permettre leur récupération. La créativité utilise le défaut du fournisseur ; outils et audio non pris en charge.")
                        } else {
                            Text("Responses : historique transmis explicitement, conservation API demandée désactivée. La créativité utilise le défaut du fournisseur ; outils et audio non pris en charge.")
                        }
                    }
                    if isDuplicate { Text("Copie sans clé API. Renseigne une clé si nécessaire ; la connexion originale reste inchangée.") }
                    Text("Les messages sont envoyés à cette adresse.")
                }
                .listRowBackground(Palette.surface)
                .listRowSeparatorTint(Palette.border)
                Section {
                    Toggle("Autoriser HTTP", isOn: $profile.allowsHTTP)
                } footer: {
                    Text("HTTP ne chiffre ni les messages ni la clé API. Réserve-le à un réseau de confiance ou à un VPN.")
                }
                .listRowBackground(Palette.surface)
                .listRowSeparatorTint(Palette.border)
                Section {
                    Button(action: test) {
                        HStack(spacing: 10) {
                            if isTesting { ProgressView().tint(Palette.onAccent) }
                            Label("Tester et charger les modèles", systemImage: "antenna.radiowaves.left.and.right")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isTesting || metadataRefresh.isLoading || keyLoadFailed || profile.baseURL.isEmpty)
                    .accessibilityIdentifier("server.testModels")
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    if let testMessage {
                        Label(testMessage, systemImage: testSucceeded ? "checkmark.circle" : "info.circle")
                            .font(.footnote).foregroundStyle(testSucceeded ? Palette.accent : Palette.muted)
                            .accessibilityIdentifier("server.testResult")
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    Button { showModels = true } label: {
                        ServerModelSelectionLabel(model: profile.model)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
                            .padding(.top, 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTesting || keyLoadFailed)
                    .accessibilityIdentifier("server.modelPicker")
                    .accessibilityHint("Ouvre la liste des modèles")
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Modèle").id(ServerEditorSection.model)
                } footer: {
                    if availableModels.isEmpty && profile.model.isEmpty {
                        Text("Teste la connexion pour charger la liste, puis choisis un modèle.")
                    }
                }
                .listRowBackground(Palette.surface)
                .listRowSeparatorTint(Palette.border)
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Format du thinking", selection: Binding(
                            get: { profile.thinkingFormat(for: profile.model) },
                            set: { profile.setThinkingFormat($0, for: profile.model) }
                        )) {
                            ForEach(profile.availableThinkingFormats(for: profile.model)) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minHeight: 44)
                        .disabled(profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("model.thinkingFormat")

                        Picker("Niveau de thinking", selection: Binding(
                            get: { profile.thinkingMode(for: profile.model) },
                            set: { profile.setThinkingMode($0, for: profile.model) }
                        )) {
                            ForEach(profile.thinkingOptions(for: profile.model)) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minHeight: 44)
                        .disabled(profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("model.thinking")
                        Text("Automatique laisse l’API utiliser son réglage par défaut.")
                            .font(.caption).foregroundStyle(Palette.muted)
                        if profile.thinkingFormat(for: profile.model) == .automatic && profile.hasDetectedThinkingLevels(for: profile.model) {
                            Text("Niveaux indiqués par l’API pour ce modèle.")
                                .font(.caption).foregroundStyle(Palette.muted)
                        } else if profile.thinkingFormat(for: profile.model) == .automatic && profile.thinkingOptions(for: profile.model).count <= 1 {
                            if profile.hasAdvertisedReasoning(for: profile.model) {
                                Text("L’API annonce le raisonnement sans préciser ses niveaux.")
                                    .font(.caption).foregroundStyle(Palette.muted)
                            } else {
                                Text("Aucun niveau n’a été détecté pour ce modèle.")
                                    .font(.caption).foregroundStyle(Palette.muted)
                            }
                            Text("Pour choisir un niveau manuellement, sélectionne ci-dessus un format compatible avec ton API.")
                                .font(.caption).foregroundStyle(Palette.muted)
                        } else if profile.thinkingFormat(for: profile.model) != .automatic {
                            Text("Les options ci-dessus dépendent du format choisi. Vérifie sa compatibilité dans la documentation de ton API : un mauvais choix peut provoquer une erreur.")
                                .font(.caption).foregroundStyle(Palette.muted)
                        }
                    }.padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Afficher le raisonnement", isOn: Binding(
                            get: { profile.showsReasoning(for: profile.model) },
                            set: { profile.setShowsReasoning($0, for: profile.model) }
                        ))
                        .disabled(profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("model.showReasoning")
                        Text("Affiche le raisonnement transmis dans le chat.")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }.padding(.vertical, 4)
                    Text("Actualisation automatique à chaque changement de modèle")
                        .font(.caption).foregroundStyle(Palette.muted)
                    ModelOutputCapacityView(profile: profile, model: profile.model)
                } header: {
                    Text("Réglages du modèle")
                }
                .listRowBackground(Palette.surface)
                .listRowSeparatorTint(Palette.border)
                Section {
                    TextField("Instruction système", text: Binding(
                        get: { profile.effectiveInstruction }, set: { profile.systemInstruction = $0 }), axis: .vertical)
                        .lineLimit(3...8).autocorrectionDisabled()
                    VStack {
                        HStack {
                            Text("Créativité")
                            Spacer()
                            Text(profile.effectiveCreativity, format: .number.precision(.fractionLength(1)))
                                .foregroundStyle(Palette.muted)
                        }
                        Slider(value: Binding(get: { profile.effectiveCreativity }, set: { profile.creativity = $0 }),
                               in: 0...2, step: 0.1).accessibilityLabel("Créativité")
                    }
                } header: { Text("Réponses") }
                .listRowBackground(Palette.surface)
                .listRowSeparatorTint(Palette.border)
                Section {
                    if profile.isApple {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Contexte maximal du modèle").fixedSize(horizontal: false, vertical: true)
                            Text(profile.maximumContext(for: profile.model).map { "\($0.formatted()) tokens" }
                                ?? "Communiqué par Apple Intelligence")
                                .foregroundStyle(Palette.muted)
                            Text("Apple Intelligence fixe lui-même cette fenêtre : elle n’est pas modifiable dans Eudes. Le contexte se règle uniquement pour les modèles téléchargés depuis Hugging Face.")
                                .font(.footnote).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ContextBudgetEditor(profile: profile, model: profile.model, requestedOutput: store.data.requestedMaxTokens,
                            budget: Binding(get: { profile.contextBudget(for: profile.model) },
                                            set: { profile.setContextBudget($0, model: profile.model) }))
                    }
                } header: { metadataHeader("Contexte maximal", field: .context) }
                .listRowBackground(Palette.surface)
                Section {
                    ModelCapabilitiesView(profile: profile, model: profile.model)
                    Toggle("Autoriser les images manuellement", isOn: Binding(
                        get: { profile.manuallyAllowsImages(profile.model) },
                        set: { profile.setManualImages($0, model: profile.model) }))
                        .disabled(profile.model.isEmpty || profile.isApple || profile.capabilities(for: profile.model).images == .unsupported)
                        .accessibilityIdentifier("model.manualImages")
                } header: { metadataHeader("Capacités", field: .capabilities) }
                .listRowBackground(Palette.surface)
                .listRowSeparatorTint(Palette.border)
                if let error = metadataRefresh.error {
                    Text(error).font(.footnote).foregroundStyle(Palette.warningText)
                }
            }
            .disabled(store.isGenerating)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .foregroundStyle(Palette.ink)
            .tint(Palette.accent)
            .toolbarBackground(Palette.background, for: .navigationBar)
            .textFieldStyle(.plain)
            .navigationTitle(isDuplicate ? "Dupliquer la connexion" : (isEditing ? "Modifier le serveur" : "Connecter un serveur"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer", action: save)
                        .fontWeight(.semibold)
                        .disabled(isTesting || metadataRefresh.isLoading || keyLoadFailed || profile.baseURL.isEmpty || profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showModels) {
                DetectedModelsView(models: availableModels, selection: $profile.model, serverName: profile.name, isNVIDIA: URL(string: profile.baseURL)?.scheme?.lowercased() == "https" && URL(string: profile.baseURL)?.host?.lowercased() == "integrate.api.nvidia.com")
            }
            .onAppear {
                if let initialSection { scroll.scrollTo(initialSection, anchor: UnitPoint(x: 0.5, y: 0.14)) }
            }
            .task {
                availableModels = profile.availableModels ?? []
                guard isEditing else { return }
                do { apiKey = try store.key(for: profile) }
                catch {
                    DiagnosticLog.record(error, context: "lecture de la clé")
                    keyLoadFailed = true
                    testMessage = friendlyError(error)
                }
            }
            .onDisappear { testTask?.cancel(); metadataRefresh.cancel() }
            .onChange(of: profile.model) { _, _ in refreshMetadata([.context, .capabilities], automatic: true) }
            .onChange(of: profile.protocolKind) { _, _ in resetTest() }
            .onChange(of: profile.baseURL) { _, _ in resetTest() }
            .onChange(of: profile.allowsHTTP) { _, _ in resetTest() }
            }
        }
    }

    private func resetTest() {
        metadataRefresh.cancel()
        testTask?.cancel()
        testTask = nil
        isTesting = false
        availableModels = []
        profile.availableModels = nil
        testMessage = nil
        testSucceeded = false
    }

    private func test() {
        metadataRefresh.cancel()
        isTesting = true
        testMessage = nil
        testSucceeded = false
        let candidate = profile
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        testTask = Task {
            do {
                let catalog = try await store.fetchCatalog(profile: candidate, key: key)
                let models = catalog.ids
                guard !Task.isCancelled else { return }
                availableModels = models
                profile.apply(catalog)
                if profile.model.isEmpty { profile.model = models.first ?? "" }
                testSucceeded = true
                testMessage = models.isEmpty
                    ? "Serveur accessible. Aucun modèle annoncé dans sa liste."
                    : "Connexion réussie · \(models.count) modèle(s) disponible(s)."
            } catch {
                guard !Task.isCancelled else { return }
                DiagnosticLog.record(error, context: "test de connexion")
                testMessage = friendlyError(error)
            }
            isTesting = false
        }
    }

    private func metadataHeader(_ title: String, field: ModelMetadataField) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { refreshMetadata([field]) } label: {
                Label("Actualiser", systemImage: "arrow.clockwise")
            }
            .textCase(nil)
            .accessibilityLabel("Actualiser " + title.lowercased())
            .disabled(isTesting || metadataRefresh.isLoading || keyLoadFailed || profile.baseURL.isEmpty || profile.model.isEmpty)
        }
    }

    private func refreshMetadata(_ fields: Set<ModelMetadataField>, automatic: Bool = false) {
        testTask?.cancel(); testTask = nil; isTesting = false
        guard !keyLoadFailed, !profile.baseURL.isEmpty, !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            metadataRefresh.cancel(); return
        }
        let candidate = profile
        let identity = candidate.visionKey(candidate.model)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        metadataRefresh.request(identity: identity, fields: fields, debounce: automatic) {
            try await store.fetchCatalog(profile: candidate, key: key)
        } apply: { catalog, requested in
            guard profile.visionKey(profile.model) == identity else { return }
            profile.applyMetadata(catalog, model: candidate.model, fields: requested)
        }
    }

    private func save() {
        do {
            profile.baseURL = try LocalEndpoint(profile.baseURL, allowsHTTP: profile.allowsHTTP).baseURL.absoluteString
            profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if profile.name.isEmpty { profile.name = "Mon serveur" }
            profile.model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.saveServer(profile, key: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            DiagnosticLog.record(error, context: "enregistrement du serveur")
            testSucceeded = false
            testMessage = friendlyError(error)
        }
    }
}

private struct ServerModelSelectionLabel: View {
    let model: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Modèle").font(.caption).foregroundStyle(Palette.muted)
                if model.isEmpty {
                    Text("Choisir un modèle").font(.body.weight(.semibold))
                } else {
                    Text(model).font(.body.weight(.semibold))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}


private struct ModelCatalogEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack")
                .font(.title2)
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            Text("Aucun modèle disponible")
                .font(.headline)
            Text("Reviens au serveur et touche « Tester et charger les modèles » pour obtenir sa liste.")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

struct DetectedModelsView: View {
    @Environment(\.dismiss) private var dismiss
    let models: [String]
    @Binding var selection: String
    var serverName = ""
    var isNVIDIA = false
    @State private var search = ""
    @State private var freeOnly = false
    @State private var freeIDs: Set<String>?
    @State private var freeError = false
    @State private var freeLoading = false
    @State private var freeRefresh = 0

    private var matchingModels: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // An existing selection remains usable when an API omits its model list.
        let choices = Set(models + [selection]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return choices.sorted().filter { model in
            (!freeOnly || (freeIDs?.contains(model) == true)) &&
                (query.isEmpty || model.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Modèles pour \(serverName)")
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if isNVIDIA {
                    Section {
                        Toggle("NVIDIA NIM Free", isOn: $freeOnly)
                            .accessibilityIdentifier("models.nvidiaFree")
                        if freeOnly {
                            if freeLoading { ProgressView("Chargement du catalogue NVIDIA…") }
                            else if freeError {
                                Text("Catalogue NVIDIA indisponible. Désactive le filtre ou réessaie.")
                                    .foregroundStyle(Palette.muted)
                                Button("Réessayer") { freeRefresh += 1 }
                            } else if freeIDs != nil {
                                Text("Selon le catalogue NVIDIA. Les noms sont comparés exactement : certains modèles peuvent manquer. La disponibilité dépend de ton compte et peut changer.")
                                    .font(.footnote).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }
                ForEach(matchingModels, id: \.self) { model in
                Button {
                    selection = model
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if !models.contains(model) {
                                Text("Sélection actuelle")
                                    .font(.caption).foregroundStyle(Palette.muted)
                            }
                        }
                        Spacer(minLength: 0)
                        if model == selection {
                            Image(systemName: "checkmark").accessibilityLabel("Sélectionné")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("detectedModel." + model)
                .listRowBackground(Palette.surface)
                .listRowSeparatorTint(Palette.border)
                }
                if freeOnly && freeIDs != nil && matchingModels.isEmpty {
                    Text("Aucun modèle correspondant dans le catalogue NVIDIA Free.")
                        .foregroundStyle(Palette.muted)
                } else if matchingModels.isEmpty && !freeOnly && !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Aucun modèle trouvé.").foregroundStyle(Palette.muted)
                } else if matchingModels.isEmpty && !freeOnly {
                    ModelCatalogEmptyState()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("models.empty")
                }
            }
            .task(id: "\(freeOnly)-\(freeRefresh)") {
                guard freeOnly else { freeLoading = false; return }
                freeIDs = nil
                freeError = false
                freeLoading = true
                do {
                    let ids = try await NVIDIAFreeCatalog.fetch()
                    guard !Task.isCancelled else { return }
                    freeIDs = ids
                } catch {
                    guard !Task.isCancelled else { return }
                    freeError = true
                }
                freeLoading = false
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Rechercher un modèle")
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .foregroundStyle(Palette.ink)
            .tint(Palette.accent)
            .toolbarBackground(Palette.background, for: .navigationBar)
            .navigationTitle("Choisir un modèle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Fermer la liste des modèles")
                }
            }
        }
        .presentationDetents([.fraction(0.6), .large])
        .presentationDragIndicator(.visible)
    }
}

/// One cancellable catalogue request per selection; coalesces taps and rejects stale results.
@MainActor
final class ModelMetadataRefresh: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var identity: String?
    private var fields: Set<ModelMetadataField> = []

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        identity = nil; fields = []; isLoading = false; error = nil
    }

    func request(identity: String, fields: Set<ModelMetadataField>, debounce: Bool = false,
                 fetch: @escaping @MainActor () async throws -> ModelCatalog,
                 apply: @escaping @MainActor (ModelCatalog, Set<ModelMetadataField>) -> Void) {
        if isLoading && self.identity == identity { self.fields.formUnion(fields); return }
        cancel()
        self.identity = identity; self.fields = fields; isLoading = true
        let token = generation
        task = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(nanoseconds: 300_000_000) }
                try Task.checkCancellation()
                let catalog = try await fetch()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                apply(catalog, self.fields)
                self.isLoading = false; self.task = nil
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                DiagnosticLog.record(error, context: "métadonnées du modèle")
                self.error = friendlyError(error)
                self.isLoading = false; self.task = nil
            }
        }
    }
}
