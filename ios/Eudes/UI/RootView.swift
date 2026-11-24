import SwiftUI
import UIKit

private struct ServerEditorRoute: Identifiable {
    let id = UUID()
    let profile: ServerProfile
    let section: ServerEditorSection
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showIntroduction = false
    @State private var showHistory = false
    @State private var headerHeight: CGFloat = 0
    @State private var pendingDeletion: Conversation?
    @State private var showSettings = false
    @State private var showAddServer = false
    @State private var showConnection = false
    @State private var editorRoute: ServerEditorRoute?
    @State private var settingsAtServer = false
    @State private var backgroundVoice = BackgroundVoiceSession.shared
    @State private var hiddenVoiceSession: UUID?
    @State private var sessionLogged = false

    var body: some View {
        ZStack {
            ThemeBackground()
            if let error = store.startupError {
                VStack(spacing: 20) {
                    BrandMark(size: 64)
                    Text("Tes données restent protégées").font(.title2.bold())
                    Text(error).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                    Button("Réessayer après déverrouillage") { store.reload() }.buttonStyle(PrimaryButtonStyle())
                }.padding(28)
            } else {
                ZStack(alignment: .top) {
                    ChatView(showAddServer: $showAddServer, showConnection: $showConnection,
                             topControlsHeight: headerHeight,
                             covered: showHistory || showSettings || showAddServer || showConnection || editorRoute != nil || showIntroduction || pendingDeletion != nil || store.voiceAssistantRequested || (backgroundVoice.isRunning && backgroundVoice.sessionID != hiddenVoiceSession),
                             openHistory: {
                                 withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showHistory = true }
                             })
                        .accessibilityHidden(showHistory && store.conversationMenuMode != .bottom)
                    header
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
            }
            if showHistory && store.conversationMenuMode != .bottom {
                sideHistory
                    .zIndex(1)
            }
        }
        .foregroundStyle(Palette.ink)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let id = backgroundVoice.sessionID, hiddenVoiceSession == id {
                Button {
                    hiddenVoiceSession = nil
                } label: {
                    Label("Afficher l’assistant vocal", systemImage: "waveform")
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Palette.surface, in: Capsule())
                }
                .accessibilityIdentifier("voice.background.reopen")
                .padding(.vertical, 8)
            }
        }
        .sheet(item: $pendingDeletion) { ConversationDeletionSheet(conversation: $0) }
        .sheet(isPresented: Binding(
            get: { showHistory && store.conversationMenuMode == .bottom },
            set: { if !$0 { showHistory = false } }
        )) { HistoryView(onClose: closeHistory) }
        .fullScreenCover(isPresented: $showIntroduction) {
            MenuIntroductionView {
                store.completeMenuIntroduction(selection: $0)
                showIntroduction = false
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.refreshAppleAvailability() } }
        .onAppear {
            logSessionStart()
            store.refreshAppleAvailability()
            showIntroduction = !store.hasSeenMenuIntroduction && store.startupError == nil
        }
        .onChange(of: store.startupError) { _, error in
            if error == nil && !store.hasSeenMenuIntroduction { showIntroduction = true }
        }
        #if DEBUG
        .task {
            // Explicit offline QA only, never used in a normal launch or Release.
            if ProcessInfo.processInfo.arguments.contains("--lue-isolated-qa"),
               let scenario = ProcessInfo.processInfo.environment["EUDES_QA_COMPACT"] {
                store.setAutomaticKeyboard(false)
                store.setLiquidGlassEnabled(!scenario.contains("frosted"))
                store.setAppearance(scenario.contains("dark") ? .dark : .light)
                store.setConversationMenuMode(scenario.contains("right") ? .right : .left)
                if scenario.contains("locked"), let conversation = store.data.conversations.first {
                    store.selectConversation(conversation)
                } else { store.newConversation() }
                if scenario.contains("sheet") { settingsAtServer = true; showSettings = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--lue-isolated-qa"),
               ProcessInfo.processInfo.environment["EUDES_QA_VOICE"] != nil {
                try? store.requestVoiceAssistant()
            }
        }
        #endif
        .task(id: store.connectionIdentity) { await store.loadModels() }
        .onChange(of: showConnection) { _, requested in
            if requested {
                showConnection = false
                openServerEditor(section: .server)
            }
        }
        .sheet(item: $editorRoute) { route in
            ServerEditorView(profile: route.profile, initialSection: route.section)
        }
        .sheet(isPresented: $showSettings, onDismiss: { settingsAtServer = false }) {
            SettingsView(openServerConfiguration: settingsAtServer)
        }
        .sheet(isPresented: $showAddServer) { ServerEditorView() }
        .fullScreenCover(isPresented: $store.voiceAssistantRequested) {
            VoiceAssistantView()
                .environmentObject(store)
        }
        .fullScreenCover(isPresented: Binding(
            get: { backgroundVoice.isRunning && backgroundVoice.sessionID != hiddenVoiceSession },
            set: { if !$0 { hiddenVoiceSession = backgroundVoice.sessionID } }
        )) {
            if let id = backgroundVoice.sessionID {
                BackgroundVoiceVisual(session: backgroundVoice, sessionID: id) {
                    hiddenVoiceSession = id
                }
            }
        }
        .onChange(of: backgroundVoice.sessionID) { _, _ in hiddenVoiceSession = nil }
        .onOpenURL { url in
            guard let id = VoiceActivityAttributes.sessionID(from: url) else { return }
            guard backgroundVoice.sessionID == id else {
                store.notice = "Cette session vocale est terminée. Relance l’assistant avec Siri."
                return
            }
            showSettings = false
            showHistory = false
            hiddenVoiceSession = nil
        }
        .alert("Eudes", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("Fermer", role: .cancel) { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }

    /// En-tête de session : rend le journal relisible des jours plus tard.
    /// Version, build, iOS et type de modèle, sans adresse ni nom de serveur.
    private func logSessionStart() {
        guard !sessionLogged else { return }
        sessionLogged = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let model: String
        if let profile = store.selectedServer {
            model = profile.isApple ? "Apple sur l’iPhone"
                : (profile.isOnDevice ? "modèle local" : "serveur compatible OpenAI")
        } else {
            model = "aucun serveur"
        }
        DiagnosticLog.log(.session,
            "Eudes \(version) (\(build)) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) · \(model)")
    }

    private func openServerEditor(section: ServerEditorSection) {
        guard var profile = store.selectedServer else {
            showAddServer = true
            return
        }
        guard !profile.isOnDevice else {
            settingsAtServer = true
            showSettings = true
            return
        }
        profile.model = store.currentModel
        editorRoute = ServerEditorRoute(profile: profile, section: section)
    }

    // Edge and alignment are mapped to keep the user's physical left/right choice in RTL too.
    private var sideEdge: Edge {
        let isLeading = (store.conversationMenuMode == .left) == (layoutDirection == .leftToRight)
        return isLeading ? .leading : .trailing
    }

    private func closeHistory() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showHistory = false }
    }

    private var sideHistory: some View {
        GeometryReader { geometry in
            ZStack(alignment: sideEdge == .leading ? .leading : .trailing) {
                // Dim the conversation while keeping the outside area tappable to close.
                Button(action: closeHistory) {
                    Color.black.opacity(0.30)
                        .contentShape(Rectangle())
                        .ignoresSafeArea(edges: .bottom)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fermer les conversations")
                .accessibilityIdentifier("conversation.dismissHistoryBackground")
                HistoryView(onClose: closeHistory, transparentTop: true)
                    // Extend only the panel surface to the screen edge; keep the search
                    // field above the home indicator's safe area.
                    .padding(.bottom, geometry.safeAreaInsets.bottom)
                    .background(Palette.historyBackground)
                    .frame(width: min(390, geometry.size.width * (dynamicTypeSize.isAccessibilitySize ? 0.92 : 0.88)))
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: sideEdge == .leading ? 0 : 22,
                        bottomLeadingRadius: sideEdge == .leading ? 0 : 22,
                        bottomTrailingRadius: sideEdge == .trailing ? 0 : 22,
                        topTrailingRadius: sideEdge == .trailing ? 0 : 22,
                        style: .continuous))
                    .padding(.bottom, -geometry.safeAreaInsets.bottom)
                    // The shadow fades away from the free edge and the top of the panel.
                    .shadow(color: Color.black.opacity(0.18), radius: 14, y: 0)
                    .transition(reduceMotion ? .identity : .move(edge: sideEdge))
                    .accessibilityAction(.escape, closeHistory)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if store.conversationMenuMode != .right { historyButton }
            ConversationModelButton(model: store.currentModelDisplayName) {
                settingsAtServer = true
                showSettings = true
            }
            .disabled(store.isGenerating || store.isPreparingSend)
            .frame(maxWidth: .infinity)
            Menu {
                Button("Nouvelle conversation", systemImage: "square.and.pencil") { store.newConversation() }
                Button("Supprimer la conversation", systemImage: "trash", role: .destructive) {
                    guard let conversation = store.current else { return }
                    if store.requestConversationDeletion(conversation) { pendingDeletion = conversation }
                }
                .disabled(store.current == nil)
                Button("Réglages", systemImage: "gearshape") { settingsAtServer = false; showSettings = true }
                    .disabled(store.isGenerating)
            } label: {
                RoundControlLabel(symbol: "ellipsis", floating: true)
            }
            .menuOrder(.fixed)
            .buttonStyle(.plain)
            .tint(Palette.ink)
            .accessibilityLabel("Actions de la conversation")
            .accessibilityIdentifier("conversation.actions")
            if store.conversationMenuMode == .right { historyButton }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private var historyButton: some View {
        RoundButton(symbol: "line.3.horizontal", label: showHistory ? "Fermer les conversations" : "Ouvrir les conversations", floating: true) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showHistory.toggle() }
        }
        .accessibilityIdentifier("conversation.historyToggle")
    }
}

private struct ConversationModelButton: View {
    @EnvironmentObject private var store: AppStore
    let model: String
    var openAllModels: () -> Void

    /// Seuls les modèles dont les fichiers sont sur l'iPhone : le menu du chat sert
    /// à changer vite, pas à explorer le catalogue.
    private var installedModels: [LocalModelCatalog.Model] {
        LocalModelCatalog.models.filter { LocalModelDownloads.isInstalled($0) }
    }

    var body: some View {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let compactName = name.split(separator: "/").last.map(String.init) ?? name

        Menu {
            if store.connectionChoices.contains(where: { $0.isApple }) {
                Button {
                    store.selectServer(ServerProfile.appleID)
                } label: {
                    Label("Apple Intelligence",
                          systemImage: store.selectedServer?.isApple == true ? "checkmark" : "apple.logo")
                }
                .disabled(store.isPreparingSend)
            }
            ForEach(installedModels) { model in
                let selected = store.selectedServer?.isLocalLFM == true
                    && store.selectedServer?.model == model.id
                Button {
                    store.selectLocalModel(model.id)
                } label: {
                    Label("\(model.title) · \(model.sizeLabel)",
                          systemImage: selected ? "checkmark" : "iphone")
                }
                .disabled(store.isPreparingSend)
            }
            Divider()
            Button {
                openAllModels()
            } label: {
                Label("Tous les modèles", systemImage: "square.grid.2x2")
            }
        } label: {
            HStack(spacing: 8) {
                if name.isEmpty {
                    Text("Choisir un modèle")
                } else {
                    Text(compactName)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .controlSurface(in: Capsule(), interactive: true)
            .overlay(Capsule().stroke(Palette.border.opacity(0.65), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choisir le modèle")
        .accessibilityValue(name.isEmpty ? Text("Aucun modèle sélectionné") : Text(name))
        .accessibilityHint("Ouvre le menu des modèles installés ; « Tous les modèles » pour le catalogue complet.")
        .accessibilityIdentifier("conversation.modelPicker")
    }
}

/// A visualisation of the existing Siri session; this view does not start or own a microphone.
@MainActor
private struct BackgroundVoiceVisual: View {
    let session: BackgroundVoiceSession
    let sessionID: UUID
    let hide: () -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentedAction: VoiceAction?
    @State private var clarificationContext = ""


    var body: some View {
        ZStack {
            ThemeBackground()
            ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text("Assistant vocal").font(.headline)
                    Spacer()
                    Button(action: hide) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(Palette.surface, in: Circle())
                    }
                    .accessibilityLabel("Masquer l’assistant vocal")
                    .accessibilityHint("La conversation vocale reste active.")
                    .accessibilityIdentifier("voice.background.hide")
                }
                .padding(.horizontal, 24).padding(.top, 12)

                Spacer(minLength: 12)
                BackgroundVoiceParticles(session: session, active: scenePhase == .active)
                Text(status)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("voice.background.status")
                    .padding(.top, 16)
                if session.isSearchingWeb {
                    ProgressView()
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 6) {
                    Label("Web", systemImage: "globe")
                    Text(store.voiceWebSearchMode.title)
                }
                .font(.caption).foregroundStyle(Palette.muted)
                .padding(.top, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("voice.background.webSearchMode")
                if session.webResearchTrace != nil {
                    WebResearchActivityView(trace: session.webResearchTrace)
                        .padding(.top, 12)
                        .padding(.horizontal, 28)
                        .accessibilityIdentifier("voice.background.webResearchActivity")
                }
                if !session.transcript.isEmpty {
                    Text(session.transcript).font(.body).padding(.horizontal, 28)
                        .accessibilityIdentifier("voice.background.transcript")
                }
                if !session.response.isEmpty {
                    Text(session.response).font(.callout).foregroundStyle(Palette.muted)
                        .padding(.horizontal, 28).accessibilityIdentifier("voice.background.response")
                }
                if session.isWaitingForAction, session.actionNeedsConfirmation,
                   !session.actionExecutionClaimed, let action = session.pendingAction {
                    Button("Vérifier l’action") { presentedAction = action }
                        .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 28)
                        .accessibilityIdentifier("voice.background.reviewAction")
                }
                Spacer(minLength: 20)
                Button("Arrêter l’assistant vocal", role: .destructive) {
                    Task { await session.stop(sessionID: sessionID) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("voice.background.stop")
                .padding(.horizontal, 28).padding(.bottom, 30)
            }
            }
        }
        .foregroundStyle(Palette.ink)
        .interactiveDismissDisabled()
        .onAppear { updateVisibility(scenePhase == .active) }
        .onDisappear { updateVisibility(false) }
        .onChange(of: scenePhase) { _, phase in updateVisibility(phase == .active) }
        .sheet(item: $presentedAction, onDismiss: {
            if session.pendingAction != nil {
                session.completeAction(for: sessionID, result: "Action annulée.")
            }
        }) { action in
            VoiceActionView(action: action) { result in
                session.completeAction(for: sessionID, result: result)
            }
        }
        .task(id: actionTaskKey) {
            guard scenePhase == .active, session.isWaitingForAction else { return }
            await session.resolvePendingAction(for: sessionID)
            guard scenePhase == .active, UIApplication.shared.isProtectedDataAvailable,
                  let action = session.claimAutomaticAction(for: sessionID) else { return }
            do {
                let result = try await VoiceActionOpening.open(action)
                session.completeAction(for: sessionID, result: result)
            } catch is CancellationError { session.releaseAutomaticAction(for: sessionID) }
            catch { session.completeAction(for: sessionID, result: error.localizedDescription) }
        }
    }

    private var actionTaskKey: String {
        "\(scenePhase)-\(session.isWaitingForAction)-\(session.pendingAction?.id ?? "")-\(session.pendingQuestion ?? "")"
    }

    private func updateVisibility(_ visible: Bool) {
        session.setVisualFeedbackVisible(visible, for: sessionID)
        session.setActionHandler(for: sessionID, visible ? routeAction : nil)
    }

    private func routeAction(_ question: String) async throws -> String? {
        guard scenePhase == .active, UIApplication.shared.isProtectedDataAvailable else { return nil }
        guard VoiceAction.shouldInterpretAction(question, hasClarification: !clarificationContext.isEmpty,
                                                voiceWebMode: store.voiceWebSearchMode) else { return nil }
        let direct = VoiceAction.direct(question)
        let request = clarificationContext.isEmpty ? question : clarificationContext + "\nPrécision : " + question
        let action: VoiceAction
        if let direct { action = try direct.validated() }
        else { action = try await store.planVoiceAction(request) }
        try Task.checkCancellation()
        guard scenePhase == .active, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable else { throw VoiceActionError.foreground }
        if action.kind == .none { clarificationContext = ""; return nil }
        if action.kind == .clarification {
            clarificationContext = request + "\nQuestion : " + action.value
            return action.value
        }
        clarificationContext = ""
        try session.propose(action, confirmation: direct == nil || action.url == nil, for: sessionID)
        return direct != nil && action.url != nil ? "Je vais ouvrir \(action.value)." : "L’action est prête à vérifier sur l’écran."
    }

    private var status: LocalizedStringResource {
        if session.isWaitingForAction { return "Action en attente" }
        return switch session.phase {
        case .preparing: "Préparation de l’assistant…"
        case .listening: "Je t’écoute…"
        case .thinking: session.isSearchingWeb
            ? WebResearchActivityPresentation.progressLabel(trace: session.webResearchTrace) : "Eudes réfléchit…"
        case .speaking: "Eudes te répond…"
        case .waiting: "Action en attente"
        }
    }
}

/// Isolate frequent sound-level updates from the rest of the screen.
@MainActor
private struct BackgroundVoiceParticles: View {
    let session: BackgroundVoiceSession
    let active: Bool
    var body: some View {
        VoiceLevelBars(level: CGFloat(session.audioLevel),
                           isActive: active && session.phase == .listening)
            .frame(maxWidth: 360, maxHeight: 360)
            .accessibilityHidden(true)
            .accessibilityIdentifier("voice.background.particles")
    }
}

struct ServerModelControls: View {
    @EnvironmentObject private var store: AppStore
    let addServer: () -> Void
    private var connectionColor: Color {
        switch store.connectionState {
        case .valid: return .green
        case .failed: return .red
        default: return Palette.muted
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    ForEach(store.connectionChoices) { server in
                        Button { store.selectServer(server.id) } label: {
                            Label(server.name, systemImage: server.id == store.selectedServer?.id ? "checkmark.circle.fill" : (server.isOnDevice ? "iphone" : "server.rack"))
                        }
                    }
                    Button("Ajouter un serveur", systemImage: "plus", action: addServer)
                } label: {
                    HStack {
                        Text("Serveur")
                        Spacer(minLength: 12)
                        Text(store.selectedServer?.name ?? "Choisir un serveur").multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.down").font(.caption)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .disabled(store.isGenerating || store.isPreparingSend)
                .accessibilityIdentifier("conversation.server")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(connectionColor).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(store.connectionLabel).font(.caption).fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(Palette.muted).accessibilityElement(children: .combine)
            }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
            if store.selectedServer != nil || store.current != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if store.modelChoices.count > 1 {
                        HStack {
                            Text("Modèle")
                            Spacer(minLength: 12)
                            Picker("Modèle", selection: Binding(get: { store.currentModel }, set: { store.selectDraftModel($0) })) {
                            ForEach(store.modelChoices, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .disabled(store.isGenerating || store.isPreparingSend)
                            .labelsHidden()
                            .accessibilityIdentifier("conversation.model")
                        }.frame(minHeight: 44)
                    } else {
                        HStack { Text("Modèle"); Spacer(); Text(store.currentModel).multilineTextAlignment(.trailing) }.frame(minHeight: 44)
                    }
                    if store.selectedServer?.isApple == false, let note = store.modelListNote {
                        Text(note).font(.caption).foregroundStyle(Palette.muted)
                    }
                }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
            }
        }
        .foregroundStyle(Palette.ink)
    }
}

#Preview { RootView().environmentObject(AppStore()) }

struct MenuIntroductionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: ConversationMenuMode = .bottom
    @State private var previewOpen = false
    let finish: (ConversationMenuMode?) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Tes conversations, à ta façon")
                        .font(.system(.largeTitle, design: .serif).weight(.medium))
                    Text("Choisis comment le menu s’ouvre. Tu pourras changer ce choix dans Réglages.")
                        .foregroundStyle(Palette.muted)
                    ForEach(ConversationMenuMode.allCases) { mode in
                        Button { selected = mode } label: {
                            HStack(spacing: 16) {
                                menuPreview(mode)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(mode.title).font(.headline)
                                    Text(mode.explanation).font(.subheadline).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: selected == mode ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(Palette.accent)
                            }
                            .padding(14)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
                            .overlay(RoundedRectangle(cornerRadius: Palette.cornerRadius)
                                .stroke(selected == mode ? Palette.accent : Palette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(mode.title + ". " + mode.explanation)
                        .accessibilityAddTraits(selected == mode ? .isSelected : [])
                        .accessibilityIdentifier("menuIntroduction." + mode.rawValue)
                    }
                    Button("Utiliser ce mode") { finish(selected) }.buttonStyle(PrimaryButtonStyle())
                    Button("Plus tard") { finish(nil) }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Text("Plus tard conserve ton mode actuel. Cet accueil ne sera plus affiché.")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                .padding(24).frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.surface)
            .foregroundStyle(Palette.ink)
            .navigationTitle("Menu des conversations")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        .task(id: reduceMotion) {
            previewOpen = true
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
                withAnimation(.easeInOut(duration: 0.55)) { previewOpen.toggle() }
            }
        }
    }

    private func menuPreview(_ mode: ConversationMenuMode) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Palette.background)
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: "line.3.horizontal").font(.caption)
                ForEach(0..<3) { _ in Capsule().fill(Palette.border).frame(height: 3) }
                Spacer()
            }.padding(9)
            RoundedRectangle(cornerRadius: 5)
                .fill(Palette.accent.opacity(0.8))
                .frame(width: mode == .bottom ? 68 : 42, height: mode == .bottom ? 45 : 82)
                .offset(x: mode == .bottom ? 0 : (mode == .left ? -1 : 1) * (previewOpen ? 17 : 68),
                        y: mode == .bottom ? (previewOpen ? 22 : 90) : 0)
            Image(systemName: mode.symbol).foregroundStyle(Palette.ink).font(.caption.bold())
        }
        .frame(width: 80, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
        .accessibilityHidden(true)
    }
}
