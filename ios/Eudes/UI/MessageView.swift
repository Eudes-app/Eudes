import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let model: String
    var showsReasoning = true
    var isSearchingWeb = false
    var onRetryPendingResponse: (() -> Void)? = nil
    var onCancelPendingResponse: (() -> Void)? = nil
    var onAbandonPendingResponse: (() -> Void)? = nil
    @State private var copied = false
    @State private var showFailureDetail = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 34)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(message.images ?? []) { attachment in
                        if let image = UIImage(data: attachment.data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 280, maxHeight: 260)
                                .accessibilityLabel("Image jointe au message")
                        }
                    }
                    if !message.text.isEmpty { Text(message.text).font(.body).lineSpacing(4).textSelection(.enabled) }
                }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .background(Palette.userBubble, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
            }
        } else {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    BrandMark(size: 25)
                    Text("EUDES").font(.system(size: 10, weight: .bold)).tracking(1.5)
                    Spacer()
                    if message.state != .streaming && !message.text.isEmpty {
                        Button {
                            // Local-only clipboard avoids Universal Clipboard; short expiry.
                            UIPasteboard.general.setItems([["public.utf8-plain-text": message.text]],
                                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                            copied = true
                        } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44) }
                        .foregroundStyle(Palette.muted).accessibilityLabel(copied ? "Copié" : "Copier la réponse")
                    }
                }.foregroundStyle(Palette.muted)
                if showsReasoning, let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningPanel(reasoning: reasoning)
                    if !message.text.isEmpty { Divider().overlay(Palette.border) }
                }
                if message.text.isEmpty && message.state == .streaming {
                    HStack(spacing: 10) {
                        ProgressView()
                        if isSearchingWeb {
                            Text(WebResearchActivityPresentation.progressLabel(trace: message.webResearchTrace))
                        }
                        else { Text("Le modèle réfléchit…") }
                    }
                        .font(.subheadline).foregroundStyle(Palette.muted)
                        .padding(.vertical, 9)
                } else if !message.text.isEmpty {
                    SafeMessageText(text: message.presentationText)
                }
                if message.webResearchTrace != nil || message.webContext != nil {
                    WebResearchActivityView(trace: message.webResearchTrace,
                                            legacySources: message.webContext != nil)
                }
                if let context = message.webContext, !context.sources.isEmpty {
                    WebSourcesView(context: context)
                }
                if (message.state == .interrupted || message.state == .failed),
                   message.remoteSubmissionPending == true, message.remoteResponse == nil {
                    Label("Statut de la réponse inconnu", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(Palette.muted)
                    if let detail = message.failureDetail {
                        Text(detail)
                            .font(.footnote).foregroundStyle(Palette.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let onAbandonPendingResponse {
                        AbandonPendingResponseButton(action: onAbandonPendingResponse)
                    }
                } else if message.state == .interrupted && message.remoteResponse != nil {
                    if message.remoteResponse?.cancelRequested == true {
                        Label("Arrêt non confirmé", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(Palette.muted)
                    } else {
                        Label("Réponse en attente de récupération", systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                    if let detail = message.failureDetail {
                        Text(detail)
                            .font(.footnote).foregroundStyle(Palette.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if message.remoteResponse?.cancelRequested != true, let onRetryPendingResponse {
                        Button(action: onRetryPendingResponse) {
                            Label("Réessayer la récupération", systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .accessibilityIdentifier("message.retryPendingResponse")
                    }
                    if let onCancelPendingResponse {
                        Button(action: onCancelPendingResponse) {
                            if message.remoteResponse?.cancelRequested == true {
                                Label("Réessayer l’arrêt", systemImage: "arrow.clockwise")
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            } else {
                                Label("Arrêter la réponse", systemImage: "stop.circle")
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .accessibilityIdentifier("message.cancelPendingResponse")
                    }
                    if message.remoteResponse?.cancelRequested == true, let onAbandonPendingResponse {
                        AbandonPendingResponseButton(action: onAbandonPendingResponse)
                    }
                } else if message.state == .interrupted || message.state == .failed {
                    Label(message.state == .interrupted ? "Réponse interrompue" : "Réponse incomplète — réessaie ci-dessous",
                          systemImage: "pause.circle")
                        .font(.caption).foregroundStyle(Palette.muted)
                    DisclosureGroup(message.state == .interrupted ? "Détails de l’interruption" : "Détails de l’erreur", isExpanded: $showFailureDetail) {
                        Text(message.failureDetail ?? "Aucun détail n’a été enregistré pour cette réponse.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("message.errorDetails")
                }
            }
            .padding(14)
            .background(Palette.assistantBubble, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Palette.cornerRadius).stroke(Palette.border, lineWidth: Palette.separatorWidth))
        }
    }
}

/// Presentation is based on app-observed calls, independently of source excerpts.
enum WebResearchActivityPresentation {
    static func progressLabel(trace: WebResearchTrace?) -> LocalizedStringResource {
        guard let call = trace?.calls.last(where: { $0.state == .running }) else {
            return "Préparation de la recherche…"
        }
        switch call.tool {
        case .webSearch: return "Recherche Web…"
        case .webFetch:
            if let host = call.url?.host { return "Lecture de \(host)…" }
            return "Lecture d’une page…"
        case .unknown: return "Exécution d’un outil…"
        }
    }

    static func title(trace: WebResearchTrace?) -> LocalizedStringResource {
        guard let trace else { return "Détail des outils indisponible" }
        let executed = trace.calls.filter { $0.startedAt != nil }
        switch trace.state {
        case .failed:
            return executed.isEmpty ? "Préparation échouée" : "Recherche échouée"
        case .cancelled:
            return executed.isEmpty ? "Préparation annulée" : "Recherche annulée"
        case .interrupted: return "Suivi interrompu"
        case .preparing, .completed: break
        }
        if executed.isEmpty {
            if trace.state == .preparing { return "Préparation de la recherche" }
            if !trace.calls.isEmpty { return "Appels non exécutés" }
            return trace.toolsOffered ? "Aucun outil appelé" : "Aucune recherche exécutée"
        }
        let model = executed.contains { $0.origin == .model }
        let eudes = executed.contains { $0.origin == .eudes }
        if model && eudes { return "Activité Web" }
        return model ? "Recherche par le modèle" : "Recherche automatique d'Eudes"
    }

    static func fallbackExplanation(_ reason: WebResearchTrace.FallbackReason) -> LocalizedStringResource {
        switch reason {
        case .appleLocal: return "Le modèle Apple utilise la recherche automatique d'Eudes."
        case .modelUnsupported: return "Le modèle est déclaré sans prise en charge des outils."
        case .apiRejected: return "L’API a refusé les outils proposés. Eudes a pris en charge la recherche."
        case .localInvalidToolCall: return "Le modèle local n’a pas produit un appel valide. Eudes a pris en charge la recherche."
        case .cachedUnsupported: return "Cette configuration a déjà refusé les outils pendant cette session."
        case .noToolClient: return "Les outils du modèle ne sont pas disponibles dans ce parcours."
        case .explicitRequest: return "Une recherche a été demandée explicitement. Le modèle n’a appelé aucun outil, alors Eudes a lancé la recherche."
        }
    }

    static func stateLabel(_ state: WebToolActivity.State) -> LocalizedStringResource {
        switch state {
        case .requested: return "Demandé"
        case .running: return "En cours"
        case .succeeded: return "Réussi"
        case .failed: return "Échoué"
        case .rejected: return "Non exécuté"
        case .cancelled: return "Annulé"
        case .interrupted: return "Résultat inconnu"
        }
    }

    static func stateSymbol(_ state: WebToolActivity.State) -> String {
        switch state {
        case .requested: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .rejected: return "minus.circle"
        case .cancelled: return "stop.circle"
        case .interrupted: return "questionmark.circle"
        }
    }
}

/// Shared by chat messages and the voice assistant; the sheet never speaks its contents.
struct WebResearchActivityView: View {
    let trace: WebResearchTrace?
    var legacySources = false
    @State private var showingDetails = false

    var body: some View {
        if trace != nil || legacySources {
            Button { showingDetails = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.body)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(WebResearchActivityPresentation.title(trace: trace))
                            .font(.footnote.weight(.medium))
                        if let trace {
                            WebResearchActivityCounts(calls: trace.calls)
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.forward")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink)
            .accessibilityIdentifier("web.activity.open")
            .accessibilityHint("Affiche les appels d’outils enregistrés pour cette réponse.")
            .sheet(isPresented: $showingDetails) {
                WebResearchActivitySheet(trace: trace)
            }
        }
    }
}

private struct WebResearchActivityCounts: View {
    let calls: [WebToolActivity]

    var body: some View {
        let executed = calls.filter { $0.startedAt != nil }.count
        let succeeded = calls.filter { $0.state == .succeeded }.count
        if executed == 0 {
            if calls.isEmpty { Text("Aucun appel exécuté") }
            else if calls.count == 1 { Text("1 appel demandé · aucun exécuté") }
            else { Text("\(calls.count) appels demandés · aucun exécuté") }
        } else if executed == 1 {
            if succeeded == 1 { Text("1 appel exécuté · réussi") }
            else { Text("1 appel exécuté · aucun réussi") }
        } else {
            if succeeded == 1 { Text("\(executed) appels exécutés · 1 réussi") }
            else { Text("\(executed) appels exécutés · \(succeeded) réussis") }
        }
    }
}

private struct WebResearchActivitySheet: View {
    let trace: WebResearchTrace?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    WebResearchActivityHeader(trace: trace)
                    if let trace {
                        WebResearchActivityConfiguration(toolsOffered: trace.toolsOffered,
                                                         fallbackReason: trace.fallbackReason)
                        if let maximumToolCalls = trace.maximumToolCalls {
                            WebResearchBudgetSummary(maximumToolCalls: maximumToolCalls,
                                requestedCalls: trace.calls.filter { $0.origin == .model }.count,
                                budgetExhausted: trace.budgetExhausted == true,
                                contextLimitReached: trace.contextLimitReached == true,
                                toolLoopInterrupted: trace.toolLoopInterrupted == true)
                        }
                        WebResearchActivityCalls(calls: trace.calls, state: trace.state)
                        Text("Cette activité correspond aux demandes d’outils reçues et à leur exécution par Eudes pour cette réponse. Le texte des pages peut être extrait et limité.")
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Cette réponse ne contient pas de journal d’outils. Ses sources ne permettent pas de savoir si la recherche a été décidée par le modèle ou lancée automatiquement par Eudes.")
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .foregroundStyle(Palette.ink)
            .navigationTitle("Activité Web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Terminé") { dismiss() }
                        .accessibilityIdentifier("web.activity.close")
                }
            }
        }
        .tint(Palette.accent)
        .accessibilityIdentifier("web.activity.details")
    }
}

private struct WebResearchActivityHeader: View {
    let trace: WebResearchTrace?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(WebResearchActivityPresentation.title(trace: trace))
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            if let trace {
                WebResearchActivityCounts(calls: trace.calls)
                    .foregroundStyle(Palette.muted)
                if trace.state == .preparing {
                    Text(WebResearchActivityPresentation.progressLabel(trace: trace))
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                } else if trace.state == .interrupted {
                    Text("Le suivi a été interrompu. Le résultat des appels non terminés n’a pas été confirmé.")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WebResearchActivityConfiguration: View {
    let toolsOffered: Bool
    let fallbackReason: WebResearchTrace.FallbackReason?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Outils proposés au modèle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                if toolsOffered { Text("Oui") }
                else { Text("Non") }
            }
            if let fallbackReason {
                Text(WebResearchActivityPresentation.fallbackExplanation(fallbackReason))
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("web.activity.configuration")
    }
}

private struct WebResearchBudgetSummary: View {
    let maximumToolCalls: Int
    let requestedCalls: Int
    let budgetExhausted: Bool
    let contextLimitReached: Bool
    let toolLoopInterrupted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Budget de cette réponse")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.muted)
            Text("\(requestedCalls) appels demandés sur un maximum de \(maximumToolCalls)")
                .font(.subheadline)
                .monospacedDigit()
            if budgetExhausted {
                Label("Limite d’appels atteinte", systemImage: "pause.circle")
                    .font(.footnote)
                Text("La recherche s’est arrêtée au plafond configuré.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            if contextLimitReached {
                Text("Recherche arrêtée pour préserver le contexte du modèle.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            if toolLoopInterrupted {
                Text("La préparation des recherches s’est interrompue ; les sources déjà collectées ont servi à la réponse.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("web.activity.budget")
    }
}

private struct WebResearchActivityCalls: View {
    let calls: [WebToolActivity]
    let state: WebResearchTrace.State

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appels")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.muted)
                .accessibilityAddTraits(.isHeader)
            if calls.isEmpty {
                if state == .preparing { Text("Aucun appel enregistré pour le moment.") }
                else { Text("Aucune demande d’outil enregistrée pour cette réponse.") }
            }
            ForEach(calls) { call in
                WebResearchActivityCallRow(call: call)
            }
        }
    }
}

private struct WebResearchActivityCallRow: View {
    let call: WebToolActivity

    private var title: LocalizedStringResource {
        switch call.tool {
        case .webSearch: return "Recherche Web"
        case .webFetch: return "Lecture de page"
        case .unknown: return "Outil inconnu"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(call.tool.rawValue)
                .font(.caption.monospaced())
                .foregroundStyle(Palette.muted)
            Text(title).font(.headline)
            Label {
                Text(WebResearchActivityPresentation.stateLabel(call.state))
            } icon: {
                Image(systemName: WebResearchActivityPresentation.stateSymbol(call.state))
            }
            .font(.subheadline)
            if call.origin == .model {
                Text("Demandé par le modèle")
                    .font(.caption).foregroundStyle(Palette.muted)
            } else if call.startedAt != nil {
                Text("Lancé automatiquement par Eudes")
                    .font(.caption).foregroundStyle(Palette.muted)
            } else {
                Text("Demandé automatiquement par Eudes")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if let query = call.query, !query.isEmpty {
                Text(query).font(.subheadline).textSelection(.enabled)
            }
            if let url = call.url {
                Text(url.absoluteString)
                    .font(.subheadline).textSelection(.enabled)
            }
            if let detail = call.detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            if let startedAt = call.startedAt, let finishedAt = call.finishedAt,
               call.state != .interrupted {
                Text("\(max(0, finishedAt.timeIntervalSince(startedAt)), format: .number.precision(.fractionLength(1))) s")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("web.activity.call.\(call.id.uuidString)")
    }
}

private struct WebSourcesView: View {
    let context: WebSearchContext
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().overlay(Palette.border)
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(context.sources) { source in
                        WebSourceLink(source: source)
                    }
                    Text("Recherche du \(context.fetchedAt, format: .dateTime.day().month().year().hour().minute())")
                        .font(.caption2).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                Label("Sources · \(context.sources.count)", systemImage: "link")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .tint(Palette.muted)
            .accessibilityIdentifier("message.webSources.disclosure")
        }
        .accessibilityIdentifier("message.webSources")
        .environment(\.openURL, OpenURLAction { url in
            url.scheme?.lowercased() == "https" && MessageMarkdownBlock.isAllowedLink(url) ? .systemAction : .discarded
        })
    }
}

private struct WebSourceLink: View {
    let source: WebSource

    var body: some View {
        Link(destination: source.url) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title).font(.footnote)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(source.url.host ?? source.url.absoluteString)
                        .font(.caption2).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if source.kind == .searchSnippet {
                        Text("Extrait du moteur de recherche")
                            .font(.caption2).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption2)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .foregroundStyle(Palette.ink)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre la source dans le navigateur")
    }
}

private struct AbandonPendingResponseButton: View {
    let action: () -> Void
    @State private var showConfirmation = false

    var body: some View {
        Button("Abandonner le suivi", role: .destructive) { showConfirmation = true }
            .frame(minHeight: 44)
            .font(.footnote)
            .accessibilityIdentifier("message.abandonPendingResponse")
            .confirmationDialog("Abandonner le suivi ?", isPresented: $showConfirmation,
                                titleVisibility: .visible) {
                Button("Abandonner le suivi", role: .destructive, action: action)
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Le serveur pourrait continuer la génération et la facturer. Eudes ne pourra plus la récupérer.")
            }
    }
}

/// Reasoning remains separate from the final response and is collapsed by default.
struct ReasoningPanel: View {
    let reasoning: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                    Text("Raisonnement").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Déplié" : "Replié")
            .accessibilityIdentifier("message.reasoning")
            if isExpanded {
                Text(reasoning)
                    .font(.callout).italic().foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 2)
        .background(Palette.userBubble, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
    }
}

/// Text only: no WebView, remote image renderer, link previews or network
/// Markdown loader. Only explicit taps on HTTP(S)/mailto links can open a destination.
struct SafeMessageText: View {
    let text: String
    private var sections: [MessageCopyBlock] { MessageCopyBlock.parse(text) }
    private var notes: FootnoteDocument { FootnoteDocument(sections: sections) }
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if section.language == nil {
                    ForEach(Array(MessageMarkdownBlock.parse(notes.clean(section.content)).enumerated()), id: \.offset) { _, block in
                        renderedBlock(block)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(section.language?.isEmpty == false ? section.language! : "texte")
                                .font(.caption2.monospaced()).foregroundStyle(Palette.muted)
                            Spacer()
                            BlockCopyButton(content: section.content, kind: "bloc")
                        }.padding(.horizontal, 14)
                        Divider().overlay(Palette.border)
                        if section.language?.lowercased() == "mermaid", let graph = NativeMermaid.parse(section.content) {
                            NativeMermaidView(graph: graph).padding(8)
                        } else {
                            ScrollView(.horizontal) {
                                Text(section.content).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                                    .padding(14)
                            }
                        }
                    }
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: Palette.cornerRadius).stroke(Palette.border, lineWidth: 0.5))
                }
            }
            if !notes.notes.isEmpty {
                Divider()
                ForEach(Array(notes.notes.enumerated()), id: \.offset) { index, note in
                    HStack(alignment: .top) {
                        Text("[\(index + 1)]").font(.caption)
                        RichInline.rendered(note.text, notes: notes).font(.footnote).textSelection(.enabled)
                    }.accessibilityLabel("Note \(index + 1) : " + note.text)
                }
            }
        }
        .font(.callout)
        .environment(\.openURL, OpenURLAction { url in
            MessageMarkdownBlock.isAllowedLink(url) ? .systemAction : .discarded
        })
    }

    @ViewBuilder private func renderedBlock(_ block: MessageMarkdownBlock) -> some View {
        switch block {
        case .text(let source):
            ForEach(Array(MarkdownHeadingBlock.parse(source).enumerated()), id: \.offset) { _, heading in
                RichInline.rendered(heading.text, notes: notes).font(heading.font).lineSpacing(4)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(heading.level == nil ? [] : .isHeader)
            }
        case .task(let checked, let source):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: checked ? "checkmark.square" : "square").accessibilityHidden(true)
                RichInline.rendered(source, notes: notes).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityValue(checked ? "Tâche cochée" : "Tâche non cochée")
        case .quote(let source):
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(Palette.muted).frame(width: 3)
                RichInline.rendered(source, notes: notes).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4).accessibilityLabel("Citation : " + source)
        case .math(let source):
            ScrollView(.horizontal) {
                if let atoms = NativeMath.parse(source) {
                    NativeMath.rendered(atoms).textSelection(.enabled).padding(.vertical, 10)
                } else { Text("$$\n" + source + "\n$$").font(.body.monospaced()).textSelection(.enabled) }
            }
        case .html(let source):
            if let html = NativeHTML.parse(source) {
                Text(MessageMarkdownBlock.inline(html.markdown)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(html.padding)
                    .foregroundStyle(htmlInk(html.background))
                    .background(htmlColor(html.background), in: RoundedRectangle(cornerRadius: html.radius))
            } else { Text(source).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        case .separator:
            Divider().overlay(Palette.border).padding(.vertical, 6)
        case .alert(let kind, let source):
            VStack(alignment: .leading, spacing: 8) {
                Label(kind.title, systemImage: kind.symbol).font(.headline)
                if !source.isEmpty { RichInline.rendered(source, notes: notes).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: Palette.cornerRadius).stroke(Palette.border))
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    tableRow(header, bold: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in tableRow(cells, bold: false) }
                }
            }.accessibilityLabel("Tableau, défilement horizontal")
        }
    }

    private func htmlInk(_ value: UInt32?) -> Color {
        guard let value, colorScheme == .light else { return Palette.ink }
        let brightness = 0.2126 * Double((value >> 16) & 255) + 0.7152 * Double((value >> 8) & 255) + 0.0722 * Double(value & 255)
        return brightness < 140 ? .white : .black
    }

    private func htmlColor(_ value: UInt32?) -> Color {
        guard let value else { return Palette.surface }
        let color = Color(red: Double((value >> 16) & 255) / 255,
                          green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
        return colorScheme == .dark ? color.opacity(0.18) : color
    }

    private func tableRow(_ cells: [String], bold: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                RichInline.rendered(cell, notes: notes)
                    .fontWeight(bold ? .semibold : .regular).textSelection(.enabled)
                    .frame(minWidth: 100, maxWidth: 280, alignment: .leading).padding(10)
                    .background(bold ? Palette.surface : Palette.assistantBubble)
                    .overlay(Rectangle().stroke(Palette.border, lineWidth: 0.5))
            }
        }
    }

}

/// Called only outside fenced code. Source text remains untouched for copying.
struct MarkdownHeadingBlock: Equatable {
    var text: String
    var level: Int?
    var font: Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        case 4: return .headline
        case 5: return .subheadline.bold()
        case 6: return .footnote.bold()
        default: return .callout
        }
    }
    static func parse(_ text: String) -> [Self] {
        var result: [Self] = []
        var ordinary: [String] = []
        func flush() {
            if !ordinary.isEmpty { result.append(Self(text: ordinary.joined(separator: "\n"), level: nil)); ordinary = [] }
        }
        for line in text.components(separatedBy: "\n") {
            let spaces = line.prefix { $0 == " " }.count
            let candidate = line.dropFirst(spaces)
            let count = candidate.prefix { $0 == "#" }.count
            let remainder = candidate.dropFirst(count)
            if spaces <= 3, (1...6).contains(count), remainder.isEmpty || remainder.first == " " || remainder.first == "\t" {
                flush()
                result.append(Self(text: String(remainder.drop { $0 == " " || $0 == "\t" }), level: count))
            } else { ordinary.append(line) }
        }
        flush()
        return result
    }
}

/// Copy uses the source block, never rendered/normalized text. Fences are recognized
/// only at the start of a line, so inline backticks and code hashes remain intact.
struct MessageCopyBlock: Equatable {
    var content: String
    var language: String?

    static func parse(_ source: String) -> [Self] {
        var result: [Self] = []
        var buffer = ""
        var fenceCount = 0
        var language: String?
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, part) in lines.enumerated() {
            let line = String(part)
            let suffix = index < lines.count - 1 ? "\n" : ""
            let spaces = line.prefix { $0 == " " }.count
            let candidate = line.dropFirst(spaces)
            let ticks = candidate.prefix { $0 == "`" }.count
            let remainder = candidate.dropFirst(ticks)
            if fenceCount == 0, spaces <= 3, ticks >= 3, !remainder.contains("`") {
                if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(Self(content: buffer, language: nil))
                }
                buffer = ""; fenceCount = ticks
                language = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if fenceCount > 0, spaces <= 3, ticks >= fenceCount,
                      remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(Self(content: buffer, language: language))
                buffer = ""; fenceCount = 0; language = nil
            } else { buffer += line + suffix }
        }
        if fenceCount > 0 || !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(Self(content: buffer, language: language))
        }
        return result
    }
}

private struct BlockCopyButton: View {
    let content: String
    let kind: String
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.setItems([["public.utf8-plain-text": content]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain).foregroundStyle(Palette.muted)
        .accessibilityLabel(copied ? "Bloc copié" : "Copier le bloc de " + kind)
        .disabled(content.isEmpty)
        .onChange(of: content) { _, _ in copied = false }
    }
}

/// Block grammar is applied only to the non-fenced sections. Copy retains original source.
enum MessageMarkdownBlock: Equatable {
    case text(String), task(Bool, String), quote(String), table([String], [[String]])
    case separator, alert(MarkdownAlertKind, String), math(String), html(String)

    static func isAllowedLink(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }
    static func inline(_ source: String) -> AttributedString {
        guard var value = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return AttributedString(source) }
        let blocked = value.runs.filter { $0.link.map { !isAllowedLink($0) } ?? false }.map(\.range)
        for range in blocked { value[range].link = nil }
        return value
    }
    static func cells(_ line: String) -> [String] {
        var result: [String] = [], cell = "", escaped = false, ticks = 0
        let chars = Array(line.trimmingCharacters(in: .whitespaces))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if escaped { cell.append(c); escaped = false; i += 1; continue }
            if c == "\\" { cell.append(c); escaped = true; i += 1; continue }
            if c == "`" {
                var n = 1
                while i+n < chars.count && chars[i+n] == "`" { n += 1 }
                if ticks == 0 { ticks = n } else if ticks == n { ticks = 0 }
                cell += String(repeating: "`", count: n); i += n; continue
            }
            if c == "|" && ticks == 0 { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(c) }
            i += 1
        }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        if chars.first == "|" { result.removeFirst() }
        if chars.last == "|", result.last == "" { result.removeLast() }
        return result
    }
    static func parse(_ source: String) -> [Self] {
        let lines = source.components(separatedBy: "\n")
        var result: [Self] = [], paragraph: [String] = [], i = 0
        func flush() {
            if !paragraph.isEmpty {
                let text = paragraph.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(text)) }
                paragraph = []
            }
        }
        func eligible(_ line: String) -> String? {
            let indent = line.prefix { $0 == " " }.count
            guard indent <= 3, !line.hasPrefix("\t") else { return nil }
            return String(line.dropFirst(indent))
        }
        while i < lines.count {
            let line = lines[i]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("$$") {
                if trimmedLine.count > 4 && trimmedLine.hasSuffix("$$") {
                    flush(); result.append(.math(String(trimmedLine.dropFirst(2).dropLast(2)))); i += 1; continue
                } else if trimmedLine == "$$", let end = lines[(i+1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "$$" }) {
                    flush(); result.append(.math(lines[(i+1)..<end].joined(separator: "\n"))); i = end+1; continue
                }
            }
            if trimmedLine.hasPrefix("<div"), let end = lines[i...].firstIndex(where: { $0.contains("</div>") }) {
                flush(); result.append(.html(lines[i...end].joined(separator: "\n"))); i = end+1; continue
            }
            if trimmedLine.hasPrefix("<") && trimmedLine.contains(">") {
                flush(); result.append(.html(line)); i += 1; continue
            }
            if i + 1 < lines.count, eligible(line) != nil, line.contains("|") {
                let head = cells(line), separators = cells(lines[i+1])
                if head.count == separators.count, !head.isEmpty,
                   separators.allSatisfy({ $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }) {
                    flush(); i += 2
                    var rows: [[String]] = []
                    while i < lines.count, lines[i].contains("|"), !lines[i].isEmpty {
                        let row = cells(lines[i])
                        guard row.count == head.count else { break } // Preserve incomplete streaming rows as text.
                        rows.append(row); i += 1
                    }
                    result.append(.table(head, rows)); continue
                }
            }
            if let trimmed = eligible(line) {
                let rule = trimmed.filter { $0 != " " && $0 != "\t" }
                if rule.count >= 3, let first = rule.first, "-*_".contains(first), rule.allSatisfy({ $0 == first }) {
                    flush(); result.append(.separator); i += 1; continue
                }
                let prefixes = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] ", "+ [ ] ", "+ [x] ", "+ [X] "]
                if let prefix = prefixes.first(where: { trimmed.hasPrefix($0) }) {
                    flush(); result.append(.task(!prefix.contains("[ ]"), String(trimmed.dropFirst(prefix.count)))); i += 1; continue
                }
                if trimmed == ">" || trimmed.hasPrefix("> ") {
                    flush(); var quote: [String] = []
                    while i < lines.count, let next = eligible(lines[i]), next == ">" || next.hasPrefix("> ") {
                        quote.append(next == ">" ? "" : String(next.dropFirst(2))); i += 1
                    }
                    if let first = quote.first, let kind = MarkdownAlertKind.allCases.first(where: { first == "[!" + $0.rawValue + "]" }) {
                        result.append(.alert(kind, quote.dropFirst().joined(separator: "\n")))
                    } else { result.append(.quote(quote.joined(separator: "\n"))) }
                    continue
                }
            }
            paragraph.append(line); i += 1
        }
        flush(); return result
    }
}

enum MarkdownAlertKind: String, CaseIterable {
    case note = "NOTE", tip = "TIP", important = "IMPORTANT", warning = "WARNING", caution = "CAUTION"
    var title: String {
        switch self {
        case .note: "Note"
        case .tip: "Conseil"
        case .important: "Important"
        case .warning: "Avertissement"
        case .caution: "Attention"
        }
    }
    var symbol: String {
        switch self {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.bubble"
        case .warning, .caution: "exclamationmark.triangle"
        }
    }
}

// Native-only rich content: no WebView, JavaScript, file loader or native bridge.
struct FootnoteDocument {
    struct Note: Equatable { var id: String; var text: String }
    var notes: [Note] = []
    init(sections: [MessageCopyBlock]) {
        for section in sections where section.language == nil {
            for line in section.content.components(separatedBy: "\n") {
                if let note = Self.definition(line), !notes.contains(where: { $0.id == note.id }) { notes.append(note) }
            }
        }
    }
    static func definition(_ line: String) -> Note? {
        guard let match = line.range(of: #"^\[\^[A-Za-z0-9_-]{1,40}\]:[ \t]*"#, options: .regularExpression),
              let end = line.firstIndex(of: "]") else { return nil }
        return Note(id: String(line[line.index(line.startIndex, offsetBy: 2)..<end]), text: String(line[match.upperBound...]))
    }
    func clean(_ source: String) -> String {
        source.components(separatedBy: "\n").filter { Self.definition($0) == nil }.joined(separator: "\n")
    }
    func number(_ id: String) -> Int? { notes.firstIndex(where: { $0.id == id }).map { $0 + 1 } }
}

struct NativeMath {
    struct Atom: Equatable { var value: String; var script: Int = 0 }
    static func parse(_ source: String) -> [Atom]? {
        guard source.count <= 4096 else { return nil }
        let chars = Array(source); var index = 0; var result: [Atom] = []
        let symbols = ["int":"∫", "sum":"∑", "prod":"∏", "infty":"∞", "alpha":"α", "beta":"β", "gamma":"γ", "delta":"δ", "theta":"θ", "lambda":"λ", "mu":"μ", "pi":"π", "sigma":"σ", "omega":"ω", "Delta":"Δ", "times":"×", "cdot":"·", "pm":"±", "leq":"≤", "geq":"≥", "neq":"≠", "approx":"≈", "rightarrow":"→"]
        func readAtom() -> String? {
            guard index < chars.count else { return nil }
            if chars[index] == "\\" {
                index += 1; guard index < chars.count else { return nil }
                if [",", ";", " ", "!"].contains(chars[index]) { index += 1; return " " }
                let start = index
                while index < chars.count && chars[index].isLetter { index += 1 }
                return symbols[String(chars[start..<index])]
            }
            let value = chars[index]; index += 1
            guard value != "{" && value != "}" && value != "^" && value != "_" else { return nil }
            return String(value)
        }
        while index < chars.count {
            if chars[index] == "^" || chars[index] == "_" {
                guard !result.isEmpty else { return nil }
                let script = chars[index] == "^" ? 1 : -1; index += 1
                var content = ""
                if index < chars.count && chars[index] == "{" {
                    index += 1
                    while index < chars.count && chars[index] != "}" {
                        guard let atom = readAtom() else { return nil }; content += atom
                    }
                    guard index < chars.count, !content.isEmpty else { return nil }; index += 1
                } else { guard let atom = readAtom() else { return nil }; content = atom }
                result.append(Atom(value: content, script: script))
            } else {
                guard let atom = readAtom() else { return nil }; result.append(Atom(value: atom))
            }
        }
        return result
    }
    static func rendered(_ atoms: [Atom]) -> Text {
        atoms.reduce(Text("")) { text, atom in
            text + Text(atom.value).font(.system(size: atom.script == 0 ? 19 : 13, design: .serif))
                .baselineOffset(atom.script == 1 ? 7 : (atom.script == -1 ? -4 : 0))
        }
    }
}

struct RichInline {
    enum Part: Equatable { case text(String), math(String), note(String) }
    static func parts(_ source: String) -> [Part] {
        let chars = Array(source); var i = 0; var buffer = ""; var result: [Part] = []
        func flush() { if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" } }
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count { buffer += String(chars[i...i+1]); i += 2; continue }
            if chars[i] == "`" {
                var count = 1
                while i+count < chars.count && chars[i+count] == "`" { count += 1 }
                let marker = String(repeating: "`", count: count)
                let rest = String(chars.dropFirst(i+count))
                if let end = rest.range(of: marker) {
                    let length = rest.distance(from: rest.startIndex, to: end.upperBound)
                    buffer += String(chars[i..<i+count+length]); i += count+length; continue
                }
            }
            if chars[i] == "$", i+1 < chars.count, chars[i+1] != "$", !chars[i+1].isWhitespace {
                var j = i+1
                while j < chars.count && chars[j] != "\n" && chars[j] != "`" {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == "$" { break }; j += 1
                }
                if j < chars.count && chars[j] == "$", j > i+1, !chars[j-1].isWhitespace {
                    flush(); result.append(.math(String(chars[i+1..<j]))); i = j+1; continue
                }
            }
            if chars[i] == "[", i+2 < chars.count, chars[i+1] == "^",
               let end = chars[(i+2)...].firstIndex(of: "]") {
                let id = String(chars[i+2..<end])
                if !id.isEmpty && id.count <= 40 && id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                    flush(); result.append(.note(id)); i = end+1; continue
                }
            }
            buffer.append(chars[i]); i += 1
        }
        flush(); return result
    }
    static func rendered(_ source: String, notes: FootnoteDocument) -> Text {
        parts(source).reduce(Text("")) { text, part in
            switch part {
            case .text(let value): return text + Text(MessageMarkdownBlock.inline(value))
            case .math(let value):
                return text + (NativeMath.parse(value).map(NativeMath.rendered) ?? Text("$" + value + "$"))
            case .note(let id):
                if let number = notes.number(id) { return text + Text("[\(number)]").font(.caption2).baselineOffset(7) }
                return text + Text("[^" + id + "]")
            }
        }
    }
}

struct NativeHTML: Equatable {
    var markdown: String
    var background: UInt32?
    var padding: Double = 0
    var radius: Double = 0
    static func parse(_ source: String) -> Self? {
        guard source.utf8.count <= 20_000, !source.contains("<!"), !source.contains("<?") else { return nil }
        let delegate = LimitedHTMLParser()
        guard let data = ("<root>" + source + "</root>").data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.rejected, delegate.sawElement else { return nil }
        return delegate.result
    }
}

private final class LimitedHTMLParser: NSObject, XMLParserDelegate {
    var result = NativeHTML(markdown: "")
    var rejected = false, sawElement = false
    var depth = 0
    let allowed = Set(["root", "div", "span", "p", "strong", "b", "em", "i", "code", "br"])
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        guard depth <= 12, allowed.contains(name), attributes.keys.allSatisfy({ $0 == "style" && name == "div" && depth == 2 }) else {
            rejected = true; parser.abortParsing(); return
        }
        if name != "root" { sawElement = true }
        if let style = attributes["style"] {
            for declaration in style.split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard pair.count == 2 else { rejected = true; parser.abortParsing(); return }
                switch pair[0] {
                case "background", "background-color":
                    guard pair[1].range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
                          let color = UInt32(pair[1].dropFirst(), radix: 16) else { rejected = true; parser.abortParsing(); return }
                    result.background = color
                case "padding", "border-radius":
                    guard pair[1].hasSuffix("px"), let value = Double(pair[1].dropLast(2)), value.isFinite,
                          (0...24).contains(value) else { rejected = true; parser.abortParsing(); return }
                    if pair[0] == "padding" { result.padding = value } else { result.radius = value }
                default: rejected = true; parser.abortParsing(); return
                }
            }
        }
        if name == "strong" || name == "b" { result.markdown += "**" }
        if name == "em" || name == "i" { result.markdown += "*" }
        if name == "code" { result.markdown += "`" }
        if name == "br" { result.markdown += "\n" }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "strong" || name == "b" { result.markdown += "**" }
        if name == "em" || name == "i" { result.markdown += "*" }
        if name == "code" { result.markdown += "`" }
        if name == "p" { result.markdown += "\n" }
        depth -= 1
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // HTML text cannot introduce new Markdown links, image resources or emphasis.
        for char in string {
            if "\\`*_[]<>".contains(char) { result.markdown.append("\\") }
            result.markdown.append(char)
        }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        rejected = true; parser.abortParsing(); return nil
    }
}

struct NativeMermaid: Equatable {
    struct Node: Equatable { var id: String; var label: String; var decision = false }
    struct Edge: Equatable { var from: String; var to: String; var label: String }
    var nodes: [Node]; var edges: [Edge]; var horizontal: Bool
    static func parse(_ source: String) -> Self? {
        guard source.count <= 20_000, !source.contains("%%{"), !source.contains("<"), !source.contains("http") else { return nil }
        var lines = source.components(separatedBy: .newlines).flatMap { $0.components(separatedBy: ";") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let first = lines.first, ["graph TD", "graph TB", "graph LR", "flowchart TD", "flowchart TB", "flowchart LR"].contains(first) else { return nil }
        lines.removeFirst()
        var nodes: [Node] = [], edges: [Edge] = []
        func node(_ input: String) -> String? {
            let value = input.trimmingCharacters(in: .whitespaces)
            guard let idRange = value.range(of: "^[A-Za-z][A-Za-z0-9_]{0,39}", options: .regularExpression) else { return nil }
            let id = String(value[idRange]); let rest = String(value[idRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            var label = id, decision = false
            if !rest.isEmpty {
                guard let start = rest.first, let end = rest.last,
                      (start == "[" && end == "]") || (start == "{" && end == "}") || (start == "(" && end == ")") else { return nil }
                label = String(rest.dropFirst().dropLast()); decision = start == "{"
                guard !label.contains(">"), !label.contains("["), !label.contains("{"), label.count <= 160 else { return nil }
                if label.hasPrefix("\"") && label.hasSuffix("\"") { label = String(label.dropFirst().dropLast()) }
            }
            if let index = nodes.firstIndex(where: { $0.id == id }) {
                if !rest.isEmpty { nodes[index] = Node(id: id, label: label, decision: decision) }
            } else { nodes.append(Node(id: id, label: label, decision: decision)) }
            return id
        }
        for line in lines {
            let parts = line.components(separatedBy: "-->")
            if parts.count == 1 { guard node(line) != nil else { return nil }; continue }
            guard parts.count == 2, let from = node(parts[0]) else { return nil }
            var target = parts[1].trimmingCharacters(in: .whitespaces); var label = ""
            if target.hasPrefix("|") {
                guard let end = target.dropFirst().firstIndex(of: "|") else { return nil }
                label = String(target[target.index(after: target.startIndex)..<end])
                guard label.count <= 80 else { return nil }
                target = String(target[target.index(after: end)...])
            }
            guard let to = node(target) else { return nil }
            edges.append(Edge(from: from, to: to, label: label))
            guard nodes.count <= 24, edges.count <= 40 else { return nil }
        }
        guard !nodes.isEmpty, nodes.count <= 24 else { return nil }
        let graph = Self(nodes: nodes, edges: edges, horizontal: first.hasSuffix("LR"))
        guard graph.levels != nil else { return nil } // Cycles use readable source rather than a misleading graph.
        return graph
    }
    var levels: [[Node]]? {
        var remaining = nodes; var done = Set<String>(); var levels: [[Node]] = []
        while !remaining.isEmpty {
            let level = remaining.filter { node in edges.filter { $0.to == node.id }.allSatisfy { done.contains($0.from) } }
            guard !level.isEmpty else { return nil }
            levels.append(level); done.formUnion(level.map(\.id)); remaining.removeAll { done.contains($0.id) }
        }
        return levels
    }
}

struct NativeMermaidView: View {
    let graph: NativeMermaid
    @ScaledMetric private var unit: CGFloat = 1
    private var levels: [[NativeMermaid.Node]] { graph.levels ?? [] }
    private var width: CGFloat { CGFloat(graph.horizontal ? levels.count : (levels.map(\.count).max() ?? 1)) * 200 * unit }
    private var height: CGFloat { CGFloat(graph.horizontal ? (levels.map(\.count).max() ?? 1) : levels.count) * 150 * unit }
    private func point(_ id: String) -> CGPoint {
        for (row, nodes) in levels.enumerated() {
            if let column = nodes.firstIndex(where: { $0.id == id }) {
                let breadth = CGFloat(column) - CGFloat(nodes.count - 1) / 2
                return graph.horizontal
                    ? CGPoint(x: (CGFloat(row) * 200 + 100) * unit, y: height / 2 + breadth * 150 * unit)
                    : CGPoint(x: width / 2 + breadth * 200 * unit, y: (CGFloat(row) * 150 + 75) * unit)
            }
        }
        return .zero
    }
    var body: some View {
        ScrollView([.horizontal, .vertical]) { diagram }
            .frame(height: min(height, 520 * unit))
            .accessibilityElement(children: .combine)
            .accessibilityValue(graph.edges.map { edge in
                let from = graph.nodes.first { $0.id == edge.from }?.label ?? edge.from
                let to = graph.nodes.first { $0.id == edge.to }?.label ?? edge.to
                return from + " → " + to + (edge.label.isEmpty ? "" : " : " + edge.label)
            }.joined(separator: "; "))
    }
    var diagram: some View {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in graph.edges {
                        var start = point(edge.from), end = point(edge.to)
                        if graph.horizontal { start.x += 75 * unit; end.x -= 75 * unit }
                        else { start.y += 28 * unit; end.y -= 28 * unit }
                        var path = Path(); path.move(to: start); path.addLine(to: end)
                        context.stroke(path, with: .color(Palette.muted), lineWidth: 1.5)
                        let angle = atan2(end.y-start.y, end.x-start.x)
                        var arrow = Path(); arrow.move(to: end)
                        arrow.addLine(to: CGPoint(x: end.x-9*cos(angle-0.5), y: end.y-9*sin(angle-0.5)))
                        arrow.move(to: end); arrow.addLine(to: CGPoint(x: end.x-9*cos(angle+0.5), y: end.y-9*sin(angle+0.5)))
                        context.stroke(arrow, with: .color(Palette.muted), lineWidth: 1.5)
                        if !edge.label.isEmpty {
                            context.draw(Text(edge.label).font(.caption).foregroundStyle(Palette.ink),
                                         at: CGPoint(x: (start.x+end.x)/2 + 12, y: (start.y+end.y)/2))
                        }
                    }
                }.frame(width: width, height: height).accessibilityHidden(true)
                ForEach(graph.nodes, id: \.id) { node in
                    Text(node.label).font(.callout).multilineTextAlignment(.center)
                        .frame(width: 138 * unit, height: 48 * unit).padding(6)
                        .background(Palette.surface, in: MermaidNodeShape(decision: node.decision))
                        .overlay(MermaidNodeShape(decision: node.decision).stroke(Palette.border))
                        .position(point(node.id))
                        .accessibilityLabel((node.decision ? "Décision : " : "") + node.label)
                }
            }.frame(width: width, height: height)
    }
}

private struct MermaidNodeShape: Shape {
    let decision: Bool
    func path(in rect: CGRect) -> Path {
        if !decision { return RoundedRectangle(cornerRadius: 10).path(in: rect) }
        return Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}
