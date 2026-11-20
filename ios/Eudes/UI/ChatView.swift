import SwiftUI
import CryptoKit
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showAddServer: Bool
    @Binding var showConnection: Bool
    var topControlsHeight: CGFloat = 0
    var covered = false
    var openHistory: () -> Void = {}
    @State private var pendingEntryFocus = true
    @State private var showKeyboardIntroduction = false
    @State private var draft = ""
    @State private var isImprovingPrompt = false
    @State private var improvementOriginal: String?
    @State private var improvementResult: String?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var attachmentExplanation: String?
    @State private var showContextSummary = false
    @State private var editingSummary = ""
    @State private var summaryConversationID: UUID?
    @State private var showContextDetails = false
    @State private var contextCount: Int?
    @State private var countedKey: String?
    @State private var allocatedLocalContext: Int?

    @State private var showPasteHelp = false
    @State private var importingImages = false
    @StateObject private var clipboardPreview = ClipboardImagePreview()
    @State private var followsLatest = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorContrast
    @State private var composerFocused = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        GeometryReader { geometry in
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    conversationContent
                        .simultaneousGesture(conversationEdgeGesture(width: geometry.size.width))
                        .frame(maxHeight: .infinity)
                    ScrollView {
                        composer.fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: geometry.size.height * 0.65)
                    .accessibilityIdentifier("composer.accessibleScroll")
                }
            } else {
                conversationContent
                    .simultaneousGesture(conversationEdgeGesture(width: geometry.size.width))
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }
        .task(id: store.connectionIdentity + String(composerFocused) + String(describing: scenePhase)) {
            guard scenePhase == .active, !store.connectionIdentity.isEmpty else { return }
            repeat {
                if !store.isGenerating && !store.isPreparingSend { _ = await store.checkConnection() }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            } while composerFocused && !Task.isCancelled
        }
        .task(id: contextKey + "|voice:" + String(store.voiceAssistantRequested)) {
            guard !store.voiceAssistantRequested else { return }
            let key = contextKey
            contextCount = nil; countedKey = nil
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            let count = await store.countContext(text: draft)
            guard !Task.isCancelled, contextKey == key else { return }
            contextCount = count; countedKey = key
        }
        .alert("Conversation trop longue", isPresented: Binding(get: { store.contextOverflowConversationID != nil }, set: { if !$0 { store.contextOverflowConversationID = nil } })) {
            Button("Annuler", role: .cancel) { store.contextOverflowConversationID = nil }
            Button("Compacter et continuer") {
                if let id = store.contextOverflowConversationID { Task { await store.compactContextAndRetry(conversationID: id) } }
            }
        } message: {
            Text("Eudes va envoyer les anciens échanges au même modèle pour les résumer, puis réessayer. La conversation complète restera visible.")
        }
        .sheet(isPresented: $showContextSummary) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Ce résumé est envoyé avec les échanges récents. Tu peux le modifier.").foregroundStyle(.secondary)
                    TextEditor(text: $editingSummary).frame(minHeight: 220)
                    Text("Les anciens échanges restent dans la conversation.").font(.footnote).foregroundStyle(.secondary)
                }.padding().navigationTitle("Résumé du contexte").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Annuler") { showContextSummary = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") {
                            if let id = summaryConversationID { store.saveContextSummary(editingSummary, conversationID: id) }
                            showContextSummary = false
                        }.disabled(editingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    }
            }
        }
        .sheet(isPresented: $showContextDetails) {
            NavigationStack {
                if let assessment = store.budgetAssessment(text: draft) {
                    Form {
                        Section("Contexte de cette conversation") {
                            if let count = currentContextCount { LabeledContent("Prochain envoi", value: "\(count.formatted()) tokens") }
                            else if store.selectedServer?.isLocalLFM == true {
                                Text("Le prochain envoi peut être compté lorsque le modèle est chargé et que le contexte ne contient pas d’image.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            if store.webSearchEnabled {
                                Text("Comptage hors extraits Web à rechercher. Ils s’ajouteront au contexte avant la réponse.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            LabeledContent(store.selectedServer?.isLocalLFM == true ? "Contexte configuré" : "Limite contexte", value: assessment.budget.map { "\($0.formatted()) tokens" } ?? "Non renseignée")
                            if store.selectedServer?.isLocalLFM == true {
                                LabeledContent("Contexte chargé", value: allocatedLocalContext.map { "\($0.formatted()) tokens" } ?? "Modèle non chargé")
                            }
                            LabeledContent("Source", value: contextSource(assessment))
                        }
                        if store.selectedServer?.isLocalLFM == true {
                            Section("Dernière requête · modèle local") {
                                if let usage = localLastUsage {
                                    LabeledContent("Entrée envoyée", value: "\(usage.input.formatted()) tokens")
                                    LabeledContent("Sortie générée", value: "\(usage.output.formatted()) tokens")
                                    Text("L’entrée inclut les éventuelles sources Web et les positions occupées par les images envoyées au modèle.").font(.footnote).foregroundStyle(.secondary)
                                } else {
                                    Text("Comptage exact non disponible pour cette requête. Une nouvelle réponse locale permettra de le mesurer.").foregroundStyle(.secondary)
                                }
                            }
                        } else if let usage = store.current?.messages.last(where: { $0.role == .assistant && $0.state == .complete })?.usage {
                            Section("Dernière requête · données de l’API") {
                                LabeledContent("Entrée envoyée", value: "\(usage.input.formatted()) tokens")
                                LabeledContent("Sortie générée", value: "\(usage.output.formatted()) tokens")
                                Text("Ces nombres concernent la dernière requête terminée, pas le prochain envoi.").font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            Section("Dernière requête · données de l’API") { Text("Non communiquées par l’API.").foregroundStyle(.secondary) }
                        }
                    }.task {
                        if store.selectedServer?.isLocalLFM == true {
                            allocatedLocalContext = await LocalModelRuntime.shared.loadedContext(for: store.currentModel)
                        }
                    }.navigationTitle("Contexte").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { showContextDetails = false } } }
                }
            }
        }
        .alert("Éviter les demandes de collage répétées ?", isPresented: $showPasteHelp) {
            Button("Ouvrir les réglages") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Plus tard", role: .cancel) { }
        } message: {
            Text("Dans les réglages iOS d'Eudes, tu peux choisir « Coller depuis d’autres apps → Autoriser ». Cela permet de lire le presse-papiers sans nouvelle demande de collage. Eudes ne peut pas modifier cette permission. Le bouton ouvre la page d'Eudes, pas directement ce sous-menu.")
        }
        .task(id: pasteHelpCanPresent) {
            guard pasteHelpCanPresent else { return }
            // Finish the native paste/import transaction before presenting help.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard pasteHelpCanPresent, store.claimPasteHelp() else { return }
            showPasteHelp = true
        }
        .onAppear { applyEntryFocus(); refreshClipboardPresence() }
        .onChange(of: scenePhase) { _, _ in refreshClipboardPresence() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refreshClipboardPresence() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.removedNotification)) { _ in refreshClipboardPresence() }
        .onChange(of: store.composerEntryID) { _, _ in
            pendingEntryFocus = true
            applyEntryFocus()
        }
        .onChange(of: covered) { _, covered in
            if covered { composerFocused = false }
            else { applyEntryFocus() }
            refreshClipboardPresence()
        }
        .sheet(isPresented: $showKeyboardIntroduction, onDismiss: {
            // Restore the deliberate first focus without triggering the demo again.
            Task { @MainActor in
                await Task.yield()
                if !covered { composerFocused = true }
            }
        }) { KeyboardIntroductionView() }

         .onChange(of: store.data.selectedConversationID) { _, _ in
            if !store.voiceAssistantRequested && store.draftImages.isEmpty { draft = "" }
            followsLatest = true
        }
        .onChange(of: composerFocused) { _, focused in
            if focused && !covered && store.claimKeyboardIntroduction() {
                composerFocused = false
                showKeyboardIntroduction = true
            } else { refreshClipboardPresence() }
        }
        .onChange(of: store.draftImages) { _, images in
            // An image-only draft must also refresh an expired connection check.
            if !images.isEmpty && !store.connectionReady {
                Task { _ = await store.checkConnection() }
            }
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            importingImages = true
            Task {
                for item in items {
                    do {
                        guard let bytes = try await item.loadTransferable(type: Data.self) else { throw ImageAttachmentError.invalid }
                        store.addImage(try ImageAttachment.importData(bytes))
                    } catch { store.notice = error.localizedDescription }
                }
                selectedPhotos = []
                importingImages = false
            }
        }
    }

    @ViewBuilder private var conversationContent: some View {
        if let conversation = store.current, !conversation.messages.isEmpty {
            transcript(conversation)
        } else {
            VStack(spacing: 0) {
                EmptyConversationView(topControlsHeight: topControlsHeight,
                                      needsServer: store.selectedServer == nil) {
                    await store.refreshConnectionFromConversation()
                }
                .frame(maxHeight: .infinity)
            }
            .overlay(alignment: floatingControlsAlignment) {
                ConversationNavigationControls(newConversation: store.newConversation)
                    .padding(20)
            }
        }
    }

    private var floatingControlsAlignment: Alignment {
        layoutDirection == .leftToRight ? .bottomTrailing : .bottomLeading
    }

    // Restrict navigation gestures to the transcript, excluding the composer,
    // header and presentations. A simultaneous gesture preserves native scrolling.
    private func conversationEdgeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onEnded { value in
                guard scenePhase == .active, !covered, store.notice == nil,
                      !showKeyboardIntroduction, !showContextSummary, !showContextDetails,
                      !showPasteHelp, !showPhotoPicker, !importingImages,
                      attachmentExplanation == nil, store.contextOverflowConversationID == nil,
                      value.startLocation.y > topControlsHeight else { return }
                let action = ConversationEdgeSwipe.action(
                    startX: value.startLocation.x, width: width, translation: value.translation,
                    menuMode: store.conversationMenuMode,
                    newConversationEnabled: store.newConversationSwipeEnabled,
                    canStartNewConversation: !store.isGenerating && !store.isPreparingSend && !isImprovingPrompt)
                switch action {
                case .newConversation: store.newConversation()
                case .history: openHistory()
                case nil: break
                }
            }
    }

    private var pasteHelpCanPresent: Bool {
        store.pasteHelpPending && scenePhase == .active && !covered && !showKeyboardIntroduction
        && !showPhotoPicker && !importingImages && attachmentExplanation == nil
    }

    private func refreshClipboardPresence() {
        clipboardPreview.refresh(active: composerFocused && scenePhase == .active && !covered && !showKeyboardIntroduction)

    }

    private func applyEntryFocus() {
        guard pendingEntryFocus, !covered, !showKeyboardIntroduction else { return }
        pendingEntryFocus = false
        composerFocused = store.automaticKeyboard
    }

    private func transcript(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    Color.clear.frame(height: 1).id("top")
                    if let summary = conversation.contextSummary, !summary.isEmpty {
                        Button {
                            summaryConversationID = conversation.id
                            editingSummary = summary
                            showContextSummary = true
                        } label: {
                            HStack {
                                Label("Contexte compacté", systemImage: "text.alignleft")
                                Spacer()
                                Text("Voir le résumé").foregroundStyle(Palette.accent)
                            }.font(.subheadline).padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
                        }.buttonStyle(.plain)
                    }
                    ForEach(conversation.messages) { message in
                        MessageView(message: message, model: conversation.model,
                                    showsReasoning: store.showsReasoning(for: message, in: conversation),
                                    isSearchingWeb: store.isSearchingWeb && message.state == .streaming,
                                    onRetryPendingResponse: {
                                        store.retryPendingResponse(messageID: message.id)
                                    },
                                    onCancelPendingResponse: {
                                        store.cancelPendingResponse(messageID: message.id)
                                    },
                                    onAbandonPendingResponse: {
                                        store.abandonPendingResponse(messageID: message.id)
                                    })
                    }
                    ConversationActionsFooter(
                        showsRegenerate: !store.isGenerating && conversation.messages.last?.role == .assistant
                            && conversation.messages.last?.remoteResponse == nil
                            && conversation.messages.last?.remoteSubmissionPending != true,
                        regenerateDisabled: store.selectedServer == nil || store.isPreparingSend,
                        usesWebSearch: store.retryUsesWebSearch,
                        context: contextIndicatorData,
                        regenerate: { Task { await store.retryChecked() } },
                        showContext: { composerFocused = false; showContextDetails = true })
                    // Keep the footer above the floating controls even when scrollTo
                    // aligns the bottom anchor with the edge of the visible transcript.
                    Color.clear.frame(height: followsLatest ? 128 : 188).accessibilityHidden(true)
                    Color.clear.frame(height: 2).id("bottom")
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .contentMargins(.top, topControlsHeight, for: .scrollContent)
        .contentMargins(.top, topControlsHeight, for: .scrollIndicators)
        .refreshable { await store.refreshConnectionFromConversation() }
        .accessibilityAction(named: "Vérifier la connexion") { Task { await store.refreshConnectionFromConversation() } }
        .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture().onChanged { _ in followsLatest = false })
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conversation.messages.last?.text) { _, _ in
                if followsLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.isGenerating) { wasGenerating, isGenerating in
                guard wasGenerating, !isGenerating, followsLatest,
                      conversation.messages.last?.role == .assistant else { return }
                Task { @MainActor in
                    await Task.yield()
                    guard followsLatest, !store.isGenerating else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: conversation.messages.count) { _, _ in
                followsLatest = true
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: floatingControlsAlignment) {
                ConversationNavigationControls(
                    scrollToTop: {
                        followsLatest = false
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo("top", anchor: .top)
                        }
                    },
                    scrollToBottom: followsLatest ? nil : {
                        followsLatest = true
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    },
                    newConversation: store.newConversation
                ).padding(20)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if !store.draftImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(store.draftImages) { attachment in
                            VStack {
                                if let image = UIImage(data: attachment.data) {
                                    Image(uiImage: image).resizable().scaledToFit().frame(width: 72, height: 72)
                                        .accessibilityLabel("Image jointe")
                                }
                                Button { store.removeImage(attachment.id) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.title3)
                                        .frame(width: 44, height: 44).contentShape(Rectangle())
                                }
                                .accessibilityLabel("Retirer cette image du brouillon")
                                .accessibilityIdentifier("attachment.remove")
                                .disabled(store.isGenerating)
                            }
                        }
                    }.padding(.horizontal, 20)
                }
                if !store.canAttachImages {
                    Text(store.selectedServer?.isLocalLFM == true
                         ? "Images conservées. Ce modèle est textuel : choisis le modèle texte et images ou retire les images avant d’envoyer."
                         : (store.selectedServer?.isApple == true ? "Images conservées. Le moteur Apple d'Eudes est textuel : choisis une connexion compatible ou retire les images avant d’envoyer." : "Images conservées. Active la compatibilité vision de cette connexion et de ce modèle, ou retire les images avant d’envoyer."))
                        .font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 20)
                }
            }
            if store.current?.messages.isEmpty == false && store.selectedServer?.isApple == true && !store.canAttachImages && !store.isGenerating && store.draftImages.isEmpty {
                Text("Modèle Apple : texte uniquement dans Eudes.")
                    .font(.caption2).foregroundStyle(Palette.muted).padding(.horizontal, 20)
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--lue-isolated-qa"),
               ProcessInfo.processInfo.environment["EUDES_QA_CLIPBOARD"] == "1" {
                HStack {
                    Button("QA image") {
                        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
                            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                            UIColor.white.setFill(); context.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
                        }
                        UIPasteboard.general.setItems([[UTType.png.identifier: bytes]], options: [.localOnly: true])
                    }
                    Button("QA texte") {
                        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: "Texte fictif"]], options: [.localOnly: true])
                    }
                }.font(.caption)
            }
            #endif
            if importingImages { ProgressView("Préparation des images…") }
            if composerFocused && clipboardPreview.hasImage && !covered && scenePhase == .active {
                HStack(spacing: 12) {
                    if let attachment = clipboardPreview.image, let image = UIImage(data: attachment.data) {
                        Button { attachPreview(attachment) } label: {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: 64, height: 64)
                        }
                        .accessibilityLabel("Ajouter l’image prévisualisée")
                        .disabled(!store.canAttachImages || importingImages || store.draftImages.contains(where: { $0.data == attachment.data }))
                    } else {
                        Image(systemName: "photo.badge.plus").font(.title2)
                            .frame(width: 44, height: 44).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Image dans le presse-papiers").font(.caption.weight(.semibold))
                        if let reason = store.selectedServer?.imageUnavailableReason(store.currentModel) {
                            Text(reason)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Palette.warningText)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                        } else if store.selectedServer == nil {
                            Text("Choisis une connexion compatible avec les images.").font(.caption2)
                        } else {
                            Text(clipboardPreview.image != nil ? "Touche la miniature ou Coller pour joindre l’image, sans l’envoyer." : (clipboardPreview.message ?? "Chargement de l’aperçu…")).font(.caption2)
                        }
                    }
                    Button { clipboardPreview.dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("Masquer la proposition du presse-papiers")
                    .accessibilityIdentifier("clipboard.dismissProposal")
                    if store.canAttachImages {
                        PasteButton(supportedContentTypes: [.image]) { providers in importPastedImages(providers) }
                            .labelStyle(.titleOnly).accessibilityLabel("Coller une image")
                            .accessibilityHint("Ajoute l’image au brouillon sans l’envoyer")
                            .disabled(importingImages || store.draftImages.count >= ImageAttachment.maxCount)
                    }
                }
                .foregroundStyle(Palette.muted).padding(12)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
                .padding(.horizontal, 18)
                .accessibilityIdentifier("clipboard.imageProposal")
            }
            if store.current != nil && store.selectedServer == nil {
                Text("Le serveur de cette conversation a été supprimé. Son historique reste lisible.")
                    .font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 24)
            }
            VStack(spacing: 0) {
                if let original = improvementOriginal {
                    Button {
                        draft = original
                        improvementOriginal = nil
                        improvementResult = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Original : « \(original) »")
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 6)
                            Text("Rétablir")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.ink)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rétablir le message original")
                    Divider()
                }
                ImagePasteComposer(text: $draft, focused: $composerFocused,
                    spellCheckEnabled: store.spellCheckEnabled,
                    onImagePaste: pasteImageFromMenu, onProviders: importPastedImages,
                    onSuccessfulTextPaste: store.recordSuccessfulPaste)
                    .frame(minHeight: 44)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            ViewThatFits(in: .horizontal) {
                                Text("Écris ton message…").fixedSize(horizontal: true, vertical: false)
                                Text("Message…").lineLimit(1)
                            }
                            .foregroundStyle(Palette.muted)
                            .padding(.top, 11).padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 4)
                HStack(spacing: 8) {
                    Menu {
                        Button("Ajouter une image", systemImage: "paperclip") {
                            if !store.canAttachImages {
                                attachmentExplanation = store.selectedServer?.imageUnavailableReason(store.currentModel) ?? "Choisis une connexion et un modèle compatibles avec les images."
                            } else if importingImages {
                                attachmentExplanation = "Importation d’images en cours."
                            } else if store.draftImages.count >= ImageAttachment.maxCount {
                                attachmentExplanation = ImageAttachmentError.limit.localizedDescription
                            } else {
                                composerFocused = false
                                showPhotoPicker = true
                            }
                        }
                        .disabled(store.selectedServer?.isLocalLFM == true && !store.canAttachImages)
                        if store.selectedServer?.isLocalLFM == true && !store.canAttachImages && !store.isGenerating {
                            Text("Ce modèle accepte uniquement du texte.")
                        }
                        Button("Serveur", systemImage: "server.rack") {
                            composerFocused = false
                            showConnection = true
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("Ajouter une image ou ouvrir les réglages du serveur")
                    .accessibilityIdentifier("composer.actions")
                    .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos,
                                  maxSelectionCount: max(1, ImageAttachment.maxCount - store.draftImages.count),
                                  matching: .images, preferredItemEncoding: .current)
                    .alert("Pièces jointes", isPresented: Binding(get: { attachmentExplanation != nil }, set: { if !$0 { attachmentExplanation = nil } })) {
                        Button("OK", role: .cancel) { attachmentExplanation = nil }
                    } message: { Text(attachmentExplanation ?? "") }
                    WebSearchComposerButton(enabled: Binding(
                                                get: { store.webSearchEnabled },
                                                set: { store.webSearchEnabled = $0 }
                                            ), mode: store.chatWebSearchMode,
                                            canToggle: store.canToggleConversationWebSearch,
                                            disabled: store.isGenerating || store.isPreparingSend)
                    Spacer(minLength: 8)
                    Button {
                        let current = draft
                        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        isImprovingPrompt = true
                        Task {
                            let improved = await store.improvePrompt(current)
                            isImprovingPrompt = false
                            if let improved {
                                improvementOriginal = current
                                improvementResult = improved
                                draft = improved
                            } else {
                                store.notice = "L'amélioration du message a échoué avec ce modèle. Réessaie ou choisis un autre modèle."
                            }
                        }
                    } label: {
                        Group {
                            if isImprovingPrompt {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 18, weight: .medium))
                            }
                        }
                        .foregroundStyle(draft.isEmpty ? Palette.muted : Palette.ink)
                        .frame(width: 40, height: 40)
                        .background(Palette.ink.opacity(0.04), in: Circle())
                        .overlay(Circle().stroke(Palette.border.opacity(0.65), lineWidth: 0.5))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isImprovingPrompt || store.isGenerating || store.isPreparingSend || draft.isEmpty)
                    .accessibilityLabel("Améliorer le message")
                    .accessibilityHint("Reformule le message avec le modèle sélectionné")
                    .accessibilityIdentifier("composer.improvePrompt")
                    if store.isGenerating {
                        Button { store.stop(reason: .user) } label: {
                            ComposerActionLabel(symbol: "stop.fill", emphasized: true)
                        }
                        .buttonStyle(ComposerActionButtonStyle())
                        .accessibilityLabel("Arrêter la réponse")
                        .accessibilityIdentifier("composer.stop")
                    } else {
                        Button(action: { send() }) {
                            ComposerActionLabel(symbol: "arrow.up", emphasized: canSend)
                        }
                        .buttonStyle(ComposerActionButtonStyle())
                        .disabled(!canSend)
                        .accessibilityLabel("Envoyer")
                        .accessibilityIdentifier("composer.send")
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
            .onChange(of: draft) { _, newValue in
                // Une modification manuelle du texte masque le bandeau « Rétablir ».
                if let result = improvementResult, newValue != result {
                    improvementOriginal = nil
                    improvementResult = nil
                }
            }
            .controlSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Palette.border.opacity(0.7), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: 720).padding(.horizontal, 18)
        }
        .padding(.top, 10).frame(maxWidth: .infinity)
        .background(Palette.background.opacity(composerGlassAvailable ? 0.9 : 1))
    }

    private var composerGlassAvailable: Bool {
        if #available(iOS 26.0, *) {
            return store.liquidGlassEnabled && !reduceTransparency && colorContrast != .increased
        }
        return false
    }

    private var currentContextCount: Int? { countedKey == contextKey ? contextCount : nil }
    private var localLastUsage: TokenUsage? {
        guard let profile = store.selectedServer, profile.isLocalLFM else { return nil }
        return store.current?.messages.last(where: {
            $0.role == .assistant && $0.state == .complete && $0.reasoningServerID == profile.id && $0.reasoningModel == store.currentModel
        })?.usage
    }
    private var contextIndicatorData: ConversationContextData? {
        guard let assessment = store.budgetAssessment(text: draft) else { return nil }
        return ConversationContextData(
            nextInputCount: currentContextCount,
            lastInputCount: store.selectedServer?.isLocalLFM == true ? localLastUsage?.input : store.current?.messages.last(where: { $0.role == .assistant && $0.state == .complete })?.usage?.input,
            budget: assessment.budget,
            isLocalLFM: store.selectedServer?.isLocalLFM == true)
    }

    private var contextKey: String {
        let messages = (store.current?.modelMessages ?? []).filter { $0.state == .complete }
        let parts = messages.map { "\($0.role.rawValue):\($0.images?.count ?? 0):\($0.text)" }
        return ([store.connectionIdentity, store.currentModel, store.selectedServer?.effectiveInstruction ?? "", draft,
                 String(store.isGenerating), String(store.draftImages.count), String(store.webSearchEnabled), String(store.localContextTokens)] + parts).joined(separator: "\u{0}")
    }

    private func contextSource(_ assessment: ContextAssessment) -> String {
        guard assessment.budget != nil, let profile = store.selectedServer else { return "Non renseignée" }
        if profile.isLocalLFM { return "Réglage du modèle local" }
        let limits = profile.limits(for: store.currentModel)
        if let server = limits.server.map(\.tokens).filter({ $0 > 0 }).min(), server == assessment.budget { return "API du serveur" }
        return profile.hasManualContext(for: store.currentModel) ? "Saisie manuelle" : "API du serveur"
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.draftImages.isEmpty)
        && store.selectedServer != nil && !importingImages && store.connectionReady && !store.isPreparingSend
        && (store.draftImages.isEmpty || store.canAttachImages)
    }

    private func attachPreview(_ attachment: ImageAttachment) {
        guard store.canAttachImages, !importingImages else { return }
        guard clipboardPreview.isCurrent else { refreshClipboardPresence(); return }
        store.addPastedImage(attachment)
        if store.draftImages.contains(where: { $0.data == attachment.data }) { store.recordSuccessfulPaste() }
    }

    private func pasteImageFromMenu() {
        guard store.canAttachImages else {
            store.notice = store.selectedServer?.imageUnavailableReason(store.currentModel)
                ?? "Choisis une connexion compatible avec les images."
            return
        }
        importPastedImages(UIPasteboard.general.itemProviders)
    }

    private func importPastedImages(_ providers: [NSItemProvider]) {
        // Explicit paste action; preview reads are separate and never attach automatically.
        guard store.canAttachImages else {
            store.notice = store.selectedServer?.imageUnavailableReason(store.currentModel)
                ?? "Choisis une connexion compatible avec les images."
            return
        }
        guard !importingImages, store.draftImages.count < ImageAttachment.maxCount else { return }
        importingImages = true
        Task {
            for provider in providers.prefix(ImageAttachment.maxCount) {
                do {
                    let image = try await PastedImageLoader.load(provider)
                    store.addPastedImage(image)
                    if store.draftImages.contains(where: { $0.data == image.data }) { store.recordSuccessfulPaste() }
                } catch { store.notice = error.localizedDescription }
            }
            importingImages = false
            refreshClipboardPresence()
        }
    }

    private func send(confirmedBudget: Bool = false) {
        let content = draft
        Task {
            if await store.sendChecked(content, confirmedBudget: confirmedBudget) {
                if draft == content { draft = "" }
                followsLatest = true; composerFocused = false
            }
        }
    }
}

/// The new-conversation control anchors a column at the physical right edge.
/// Navigation arrows sit above it, with 16 points between their 44-point targets.
struct ConversationNavigationControls: View {
    var scrollToTop: (() -> Void)?
    var scrollToBottom: (() -> Void)?
    let newConversation: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let scrollToTop {
                RoundButton(symbol: "arrow.up", label: "Début de la conversation", floating: true,
                            action: scrollToTop)
                    .accessibilityIdentifier("conversation.scrollToTop")
            }
            if let scrollToBottom {
                RoundButton(symbol: "arrow.down", label: "Dernier message", floating: true,
                            action: scrollToBottom)
                    .accessibilityIdentifier("conversation.scrollToBottom")
            }
            Button(action: newConversation) {
                RoundControlLabel(symbol: "square.and.pencil", floating: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Nouvelle conversation")
            .accessibilityHint("Ouvre une conversation vide et conserve cet échange dans l’historique")
            .accessibilityIdentifier("composer.newConversation")
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct ConversationContextData {
    let nextInputCount: Int?
    let lastInputCount: Int?
    let budget: Int?
    let isLocalLFM: Bool
}

private struct ConversationActionsFooter: View {
    let showsRegenerate: Bool
    let regenerateDisabled: Bool
    let usesWebSearch: Bool
    let context: ConversationContextData?
    let regenerate: () -> Void
    let showContext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsRegenerate {
                Button(action: regenerate) {
                    if usesWebSearch {
                        Label("Régénérer avec recherche Web", systemImage: "arrow.clockwise")
                    } else {
                        Label("Régénérer la réponse", systemImage: "arrow.clockwise")
                    }
                }
                .font(.caption).foregroundStyle(Palette.muted)
                .disabled(regenerateDisabled)
                .accessibilityIdentifier("conversation.regenerate")
            }
            if let context {
                ConversationContextIndicator(data: context, action: showContext)
                    // Keep the context control clear of the floating scroll buttons.
                    .padding(.trailing, 56)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("conversation.actionsFooter")
    }
}

private struct ConversationContextIndicator: View {
    let data: ConversationContextData
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let count = data.nextInputCount {
                        Text("Prochain envoi : \(count.formatted()) tokens")
                    } else if let count = data.lastInputCount {
                        Text("Dernière entrée : \(count.formatted()) tokens")
                    } else if data.isLocalLFM, let budget = data.budget {
                        Text("Contexte : \(budget.formatted()) tokens max")
                    } else {
                        Text("Contexte")
                    }
                    Image(systemName: "info.circle")
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
                if let count = data.nextInputCount, let budget = data.budget, budget > 0 {
                    ProgressView(value: min(1, Double(count) / Double(budget)))
                        .tint(Palette.accent).accessibilityHidden(true)
                }
            }
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Afficher les détails du contexte")
        .accessibilityIdentifier("context.indicator")
    }
}

private struct EmptyConversationView: View {
    let topControlsHeight: CGFloat
    let needsServer: Bool
    let refreshConnection: @MainActor () async -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    ZStack {
                        BrandMark(size: 100)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Eudes, conversation vide")
                    .accessibilityIdentifier("conversation.emptyLogo")
                    if needsServer {
                        Text("Ajoute un serveur pour commencer une conversation.")
                            .font(.callout)
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity,
                       minHeight: max(0, geometry.size.height - topControlsHeight))
            }
            .contentMargins(.top, topControlsHeight, for: .scrollContent)
            .contentMargins(.top, topControlsHeight, for: .scrollIndicators)
            .refreshable { await refreshConnection() }
            .accessibilityAction(named: "Vérifier la connexion") { Task { await refreshConnection() } }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct WebSearchComposerButton: View {
    @Binding var enabled: Bool
    let mode: ChatWebSearchMode
    let canToggle: Bool
    let disabled: Bool
    @State private var showModeExplanation = false

    var body: some View {
        Button {
            if canToggle {
                enabled.toggle()
            } else {
                showModeExplanation = true
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(enabled ? Palette.onAccent : Palette.ink)
                .frame(width: 40, height: 40)
                .background(Palette.ink.opacity(enabled ? 1 : 0.04), in: Circle())
                .overlay(Circle().stroke(Palette.border.opacity(enabled ? 0 : 0.65), lineWidth: 0.5))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("Recherche Web")
        .accessibilityValue(canToggle ? (enabled ? Text("Activée pour cette conversation") : Text("Désactivée pour cette conversation")) : Text(mode.title))
        .accessibilityAddTraits(enabled ? .isSelected : [])
        .accessibilityHint(canToggle ? Text("Change la recherche Web pour cette conversation") : Text("Explique le mode choisi dans Réglages, Recherche Web"))
        .accessibilityIdentifier("composer.webSearch")
        .alert("Mode de recherche Web", isPresented: $showModeExplanation) {
            Button("OK", role: .cancel) { }
        } message: {
            if mode == .allConversations {
                Text("La recherche Web est activée pour toutes les conversations. Pour la gérer avec ce bouton, choisis « Par conversation » dans Réglages → Recherche Web → Chat.")
            } else {
                Text("La recherche Web est désactivée pour le chat. Pour l’activer avec ce bouton, choisis « Par conversation » dans Réglages → Recherche Web → Chat.")
            }
        }
    }
}

private struct ComposerActionLabel: View {
    let symbol: String
    let emphasized: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: symbol == "stop.fill" ? 15 : 20, weight: .semibold))
            .foregroundStyle(emphasized ? Palette.onAccent : Palette.muted)
            .frame(width: 40, height: 40)
            .background(Palette.ink.opacity(emphasized ? 0.62 : 0.1), in: Circle())
            .overlay(Circle().stroke(Palette.ink.opacity(emphasized ? 0.16 : 0.08), lineWidth: 0.5))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}

private struct ComposerActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}


private struct KeyboardIntroductionView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animateKeyboard = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Ton clavier, à ton rythme").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("Choisis ce qui se passe quand tu ouvres une conversation. Un appui dans le champ permet toujours d’écrire.")
                    .foregroundStyle(Palette.muted)
                HStack(alignment: .top, spacing: 12) {
                    preview(title: "Sur demande", automatic: false)
                    preview(title: "Automatiquement", automatic: true)
                }
                Toggle("Ouvrir le clavier automatiquement", isOn: Binding(
                    get: { store.automaticKeyboard }, set: { store.setAutomaticKeyboard($0) }
                ))
                Text("Tu peux changer ce choix dans Réglages. Cette présentation ne sera affichée qu’une fois.")
                    .font(.caption).foregroundStyle(Palette.muted)
                Button("Continuer à écrire") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }.padding(24)
        }
        .background(Palette.surface)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.large])
        .task(id: reduceMotion) {
            guard !reduceMotion else { animateKeyboard = true; return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.65)) { animateKeyboard.toggle() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func preview(title: String, automatic: Bool) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.caption.weight(.semibold))
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6).fill(Palette.border).frame(height: 25)
                Spacer(minLength: 8)
                Text("Message…").font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Palette.background, in: RoundedRectangle(cornerRadius: 6))
                if automatic && (reduceMotion || animateKeyboard) {
                    Image(systemName: "keyboard").font(.system(size: 34)).frame(maxWidth: .infinity).frame(height: 52)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(10).frame(height: 160).background(Palette.background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(automatic ? "Automatiquement : le clavier apparaît à l’ouverture de la conversation" : "Sur demande : la conversation s’ouvre sans clavier")
    }
}

/// Persist only rejection metadata and an image digest, never clipboard contents.
@MainActor
final class ClipboardImageDismissal {
    static let shared = ClipboardImageDismissal()
    private static let key = "clipboardImageDismissedChangeCount"
    private static let digestKey = "clipboardImageDismissedDigest"
    private static let revisionKey = "clipboardImageDismissedRevision"
    private let defaults: UserDefaults
    var checkedChange: Int?
    private(set) var revision: String {
        get { defaults.string(forKey: Self.revisionKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.revisionKey) }
    }
    var hasRejection: Bool { changeCount != nil || digest != nil }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var digest: Data? {
        get { defaults.data(forKey: Self.digestKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.digestKey) }
            else { defaults.removeObject(forKey: Self.digestKey) }
        }
    }

    // Without a digest, a counter collision after restart may hide a later copy.
    var changeCount: Int? {
        get { defaults.object(forKey: Self.key) as? Int }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.key) }
            else { defaults.removeObject(forKey: Self.key) }
        }
    }

    func reject(changeCount: Int, digest: Data?) {
        revision = UUID().uuidString
        self.changeCount = changeCount
        checkedChange = changeCount
        self.digest = digest
    }

    func rememberDigest(_ digest: Data, for revision: String) {
        // A late preview must never replace a more recent dismissal.
        guard self.revision == revision, hasRejection else { return }
        self.digest = digest
    }

    func clear() {
        guard hasRejection else { return }
        revision = UUID().uuidString
        changeCount = nil
        checkedChange = nil
        digest = nil
    }
}

@MainActor
private final class ClipboardPreviewRequest {
    var rejectionRevision: String?
}

/// Reads only after an explicit composer focus, with normal iOS paste permission handling.
@MainActor
final class ClipboardImagePreview: ObservableObject {
    @Published private(set) var hasImage = false
    @Published private(set) var image: ImageAttachment?
    @Published private(set) var message: String?
    private var attemptedChange: Int?
    private var task: Task<Void, Never>?
    private var request: ClipboardPreviewRequest?
    private let changeCount: () -> Int
    private let containsImage: () -> Bool
    private let providers: () -> [NSItemProvider]
    private let dismissal: ClipboardImageDismissal
    var isCurrent: Bool { attemptedChange == changeCount() && image != nil }

    init(changeCount: @escaping () -> Int = { UIPasteboard.general.changeCount },
         containsImage: @escaping () -> Bool = { UIPasteboard.general.hasImages },
         providers: @escaping () -> [NSItemProvider] = { UIPasteboard.general.itemProviders },
         dismissal: ClipboardImageDismissal? = nil) {
        self.changeCount = changeCount; self.containsImage = containsImage; self.providers = providers
        self.dismissal = dismissal ?? .shared
    }
    func dismiss() {
        let count = attemptedChange ?? changeCount()
        dismissal.reject(changeCount: count, digest: image.map { Data(SHA256.hash(data: $0.data)) })
        // An already requested read may finish solely to fingerprint the rejected
        // image. It cannot show a preview or attach anything after this dismissal.
        request?.rejectionRevision = dismissal.revision
        hideProposal()
    }
    func refresh(active: Bool) {
        guard active else { return }
        let count = changeCount()
        guard containsImage() else {
            retireRequest()
            attemptedChange = count
            dismissal.clear()
            hideProposal()
            return
        }
        if dismissal.hasRejection && (dismissal.digest == nil ||
            (dismissal.changeCount == count && dismissal.checkedChange == count)) {
            // A counter change alone cannot identify a different image. In
            // particular, do not reopen an unavailable preview on every focus.
            hideProposal()
            return
        }
        guard attemptedChange != count else { return }
        retireRequest()
        attemptedChange = count; image = nil; message = nil
        // While comparing a rejected image, avoid flashing its proposal again.
        hasImage = !dismissal.hasRejection
        let items = providers()
        guard let provider = items.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else {
            guard !dismissal.hasRejection else { hideProposal(); return }
            hasImage = true
            message = "Aperçu indisponible ou accès non accordé. Tu peux choisir Coller explicitement."
            return
        }
        let request = ClipboardPreviewRequest()
        self.request = request
        let dismissal = dismissal
        task = Task { [weak self, request, dismissal] in
            do {
                let attachment = try await PastedImageLoader.load(provider)
                let digest = Data(SHA256.hash(data: attachment.data))
                if let revision = request.rejectionRevision {
                    dismissal.rememberDigest(digest, for: revision)
                }
                guard let self, !Task.isCancelled, self.request === request,
                      self.changeCount() == count else { return }
                self.task = nil; self.request = nil
                // Consult the current shared refusal, not the snapshot from the
                // start of this read: another view may have rejected it meanwhile.
                if dismissal.hasRejection && (dismissal.digest == nil || dismissal.digest == digest ||
                    (dismissal.changeCount == count && dismissal.checkedChange == count)) {
                    dismissal.changeCount = count
                    dismissal.checkedChange = count
                    if dismissal.digest == nil { dismissal.digest = digest }
                    self.hideProposal()
                    return
                }
                dismissal.clear()
                self.image = attachment
                self.hasImage = true
            } catch {
                guard let self, !Task.isCancelled, self.request === request,
                      self.changeCount() == count else { return }
                self.task = nil; self.request = nil
                guard !dismissal.hasRejection else { self.hideProposal(); return }
                self.hasImage = true
                self.message = "Aperçu indisponible : accès non accordé ou image non prise en charge. Tu peux choisir Coller explicitement."
            }
        }
    }

    private func hideProposal() {
        hasImage = false; image = nil; message = nil
    }

    private func retireRequest() {
        // Keep only an in-flight read explicitly rejected by the user alive, so
        // it can finish its fingerprint even if the conversation view disappears.
        if request?.rejectionRevision == nil { task?.cancel() }
        task = nil; request = nil
    }
}

/// Native editing menu retains text paste; image paste routes into the attachment list.
final class ImagePasteTextView: UITextView {
    func setCorrectionEnabled(_ enabled: Bool) {
        let correction: UITextAutocorrectionType = enabled ? .yes : .no
        let spelling: UITextSpellCheckingType = enabled ? .yes : .no
        guard autocorrectionType != correction || spellCheckingType != spelling else { return }
        autocorrectionType = correction
        spellCheckingType = spelling
        if isFirstResponder { reloadInputViews() }
    }
    var imagePresence: () -> Bool = { UIPasteboard.general.hasImages }
    var onImagePaste: () -> Void = {}
    var onSuccessfulTextPaste: () -> Void = {}
    var onProviders: ([NSItemProvider]) -> Void = { _ in }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), imagePresence() { return true }
        return super.canPerformAction(action, withSender: sender)
    }
    override func paste(_ sender: Any?) {
        if imagePresence() { onImagePaste() }
        else {
            let before = text
            super.paste(sender)
            if text != before { onSuccessfulTextPaste() }
        }
    }
    override func paste(itemProviders: [NSItemProvider]) {
        let images = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        if !images.isEmpty { onProviders(images) }
        else {
            // Providers originate from the explicit native paste operation.
            for provider in itemProviders where provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { [weak self] value, error in
                    guard error == nil, let value = value as? String, !value.isEmpty else { return }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.insertText(value)
                        self.onSuccessfulTextPaste()
                    }
                }
            }
        }
    }
}

private struct ImagePasteComposer: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var spellCheckEnabled: Bool
    var onImagePaste: () -> Void
    var onProviders: ([NSItemProvider]) -> Void
    var onSuccessfulTextPaste: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ImagePasteTextView {
        let view = ImagePasteTextView()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
        view.textContainer.lineFragmentPadding = 5
        view.setCorrectionEnabled(spellCheckEnabled)
        view.autocapitalizationType = .sentences
        view.allowsEditingTextAttributes = false
        view.accessibilityLabel = "Message"
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: ImagePasteTextView, context: Context) {
        context.coordinator.parent = self
        view.onImagePaste = onImagePaste; view.onProviders = onProviders
        view.onSuccessfulTextPaste = onSuccessfulTextPaste
        view.textColor = UIColor(Palette.ink)
        view.setCorrectionEnabled(spellCheckEnabled)
        if view.text != text { view.text = text }
        if focused != view.isFirstResponder {
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard let view, let coordinator else { return }
                if coordinator.parent.focused { view.becomeFirstResponder() }
                else { view.resignFirstResponder() }
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ImagePasteTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(180, max(44, height)))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ImagePasteComposer
        init(_ parent: ImagePasteComposer) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
    }
}
