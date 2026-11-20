import SwiftUI

/// Prepared once per history/search/expansion change, never once per rendered row.
struct HistoryMenuSnapshot {
    enum Entry: Identifiable {
        enum ID: Hashable { case folder(UUID), conversation(UUID) }
        case folder(ConversationFolder, count: Int, expanded: Bool)
        case conversation(Conversation)

        var id: ID {
            switch self {
            case .folder(let folder, _, _): .folder(folder.id)
            case .conversation(let conversation): .conversation(conversation.id)
            }
        }
        var conversationID: UUID? {
            if case .conversation(let conversation) = self { return conversation.id }
            return nil
        }
    }

    var folderEntries: [Entry] = []
    var recentConversations: [Conversation] = []
    var visibleConversationIDs: Set<UUID> = []
    var matchingCount = 0
    var isSearching = false
    var recentsExpanded = true

    init(folders: [ConversationFolder] = [], conversations: [Conversation] = [],
         search: String = "", expandedFolderIDs: Set<UUID> = [], recentsExpanded: Bool = true) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = !query.isEmpty
        self.recentsExpanded = recentsExpanded || isSearching
        let folderIDs = Set(folders.map(\.id))
        let matches = conversations.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        matchingCount = matches.count
        let grouped = Dictionary(grouping: matches.filter { $0.folderID.map(folderIDs.contains) == true }) { $0.folderID! }
        for folder in folders.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let children = grouped[folder.id] ?? []
            // A search displays only matching groups, regardless of their saved disclosure state.
            guard !isSearching || !children.isEmpty else { continue }
            let expanded = expandedFolderIDs.contains(folder.id) || isSearching
            folderEntries.append(.folder(folder, count: children.count, expanded: expanded))
            if expanded {
                folderEntries.append(contentsOf: children.map(Entry.conversation))
                visibleConversationIDs.formUnion(children.map(\.id))
            }
        }
        // Older histories may reference a deleted/missing folder. Keep those chats reachable.
        recentConversations = matches.filter { $0.folderID.map(folderIDs.contains) != true }
        if self.recentsExpanded { visibleConversationIDs.formUnion(recentConversations.map(\.id)) }
    }
}

private enum HistoryMenuAction {
    case open(Conversation), select(Conversation), move(Conversation), removeFromFolder(Conversation), delete(Conversation)
    case toggleFolder(UUID), renameFolder(ConversationFolder), deleteFolder(ConversationFolder)
}

struct HistoryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onClose: (() -> Void)? = nil
    var transparentTop: Bool = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var pendingDeletion: Conversation?
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var bulkDeletion: BulkConversationDeletion?
    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var folderEditor: HistoryFolderEditor?
    @State private var folderToDelete: ConversationFolder?
    @State private var movingSelection: HistoryMoveSelection?
    @State private var menu = HistoryMenuSnapshot()

    var body: some View {
        VStack(spacing: 0) {
            if !transparentTop {
                Button(action: close) {
                    Color.clear.frame(height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fermer les conversations")
                .accessibilityHint("Zone au-dessus de l’en-tête")
                .accessibilityIdentifier("history.topDismiss")
            }
            NavigationStack {
                List {
                    if selecting && !menu.visibleConversationIDs.isEmpty {
                        SelectAllConversationsRow(
                            filtered: menu.isSearching,
                            total: menu.visibleConversationIDs.count,
                            selected: selectedIDs.intersection(menu.visibleConversationIDs).count,
                            action: toggleAllVisibleConversations
                        )
                        .listRowBackground(Palette.surface)
                        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                    }
                    Section {
                        ForEach(menu.folderEntries) { entry in
                            HistoryMenuEntryRow(entry: entry, selecting: selecting, selectedIDs: selectedIDs,
                                                searching: menu.isSearching, action: handle)
                                .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                                .listRowBackground(entry.conversationID == store.data.selectedConversationID
                                                   && entry.conversationID != nil ? Palette.userBubble : Palette.surface)
                        }
                        if menu.folderEntries.isEmpty && !menu.isSearching {
                            Button { folderEditor = HistoryFolderEditor(folder: nil) } label: {
                                Label("Créer un dossier", systemImage: "folder.badge.plus")
                                    .font(.body).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Palette.surface)
                            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                        }
                    } header: {
                        HistoryFoldersHeader { folderEditor = HistoryFolderEditor(folder: nil) }
                    }
                    Section {
                        HistoryRecentsHeader(count: menu.recentConversations.count,
                                             expanded: menu.recentsExpanded, searching: menu.isSearching) {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                store.setRecentConversationsExpanded(!store.recentConversationsExpanded)
                                refreshMenu()
                            }
                        }
                        .listRowBackground(Palette.surface)
                        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                        if menu.recentsExpanded {
                            ForEach(menu.recentConversations) { conversation in
                                HistoryConversationRow(conversation: conversation, inFolder: false,
                                                       selecting: selecting, isSelected: selectedIDs.contains(conversation.id),
                                                       action: handle)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                                    .listRowBackground(conversation.id == store.data.selectedConversationID
                                                       ? Palette.userBubble : Palette.surface)
                            }
                            if menu.recentConversations.isEmpty && !menu.isSearching {
                                Text("Tes conversations sans dossier apparaîtront ici.")
                                    .font(.subheadline).foregroundStyle(Palette.muted)
                                    .padding(.vertical, 12)
                                    .listRowBackground(Palette.surface)
                            }
                        }
                    }
                    if menu.isSearching && menu.matchingCount == 0 {
                        Text("Aucun résultat.").foregroundStyle(Palette.muted)
                            .listRowBackground(Palette.historyBackground)
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(20)
                .environment(\.defaultMinListRowHeight, 44)
                .listRowSeparatorTint(Palette.border)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .contentMargins(.top, 0, for: .scrollContent)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .themedPanel(background: Palette.historyBackground)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HistorySearchBar(search: $search, focused: $searchFocused)
                }
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HistoryMenuHeader(selecting: selecting, newConversation: {
                        store.newConversation(); close()
                    }, cancelSelection: {
                        selecting = false; selectedIDs.removeAll()
                    }, close: close)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        if selecting {
                            Button { moveSelection(selectedIDs) } label: {
                                Label("Déplacer", systemImage: "folder")
                                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedIDs.isEmpty)
                            .accessibilityIdentifier("history.bulkMove")
                            Spacer()
                            Button {
                                let ids = selectedIDs.intersection(menu.visibleConversationIDs)
                                if !ids.isEmpty { bulkDeletion = BulkConversationDeletion(ids: ids) }
                            } label: { Label("Supprimer (\(selectedIDs.count))", systemImage: "trash") }
                            .disabled(selectedIDs.isEmpty).frame(minHeight: 44)
                            .accessibilityIdentifier("history.bulkDelete")
                        }
                    }
                }
                .onReceive(store.$data) { data in refreshMenu(data: data) }
                .onChange(of: search) { _, _ in
                    selectedIDs.removeAll()
                    refreshMenu()
                }
                .onChange(of: store.recentConversationsExpanded) { _, _ in refreshMenu() }
            }
        }
        .background(Palette.historyBackground)
        .sheet(item: $pendingDeletion) { conversation in
            ConversationDeletionSheet(conversation: conversation)
        }
        .sheet(item: $bulkDeletion) { selection in
            BulkConversationDeletionSheet(selection: selection) {
                selectedIDs.removeAll(); selecting = false
            }
        }
        .sheet(item: $folderEditor) { editor in
            HistoryFolderEditorSheet(folder: editor.folder) { name in
                if let folder = editor.folder { return store.renameFolder(folder.id, name: name) }
                return store.createFolder(name: name) != nil
            }
        }
        .sheet(item: $movingSelection) { selection in
            HistoryMoveToFolderSheet(ids: selection.ids) {
                selectedIDs.removeAll(); selecting = false
            }
        }
        .alert("Supprimer ce dossier ?", isPresented: Binding(
            get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }
        ), presenting: folderToDelete) { folder in
            Button("Annuler", role: .cancel) { folderToDelete = nil }
            Button("Supprimer le dossier", role: .destructive) {
                _ = store.deleteFolder(folder.id)
                expandedFolderIDs.remove(folder.id)
                refreshMenu()
                folderToDelete = nil
            }
        } message: { folder in
            Text("Le dossier « \(folder.name) » sera supprimé. Ses conversations seront conservées.")
        }
    }

    private func refreshMenu(data: AppData? = nil) {
        let data = data ?? store.data
        menu = HistoryMenuSnapshot(folders: data.folders ?? [], conversations: data.conversations,
                                   search: search, expandedFolderIDs: expandedFolderIDs,
                                   recentsExpanded: store.recentConversationsExpanded)
        // Collapsing a group must never leave hidden chats selected for a bulk action.
        selectedIDs.formIntersection(menu.visibleConversationIDs)
    }

    private func handle(_ action: HistoryMenuAction) {
        switch action {
        case .open(let conversation):
            if selecting {
                if selectedIDs.contains(conversation.id) { selectedIDs.remove(conversation.id) }
                else { selectedIDs.insert(conversation.id) }
            } else { store.selectConversation(conversation); close() }
        case .select(let conversation):
            guard !selecting else { return }
            searchFocused = false; selecting = true; selectedIDs = [conversation.id]
        case .move(let conversation): moveSelection([conversation.id])
        case .removeFromFolder(let conversation): _ = store.moveConversations(ids: [conversation.id], to: nil)
        case .delete(let conversation):
            if store.requestConversationDeletion(conversation) { pendingDeletion = conversation }
        case .toggleFolder(let id):
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                if expandedFolderIDs.contains(id) { expandedFolderIDs.remove(id) }
                else { expandedFolderIDs.insert(id) }
                refreshMenu()
            }
        case .renameFolder(let folder): folderEditor = HistoryFolderEditor(folder: folder)
        case .deleteFolder(let folder): folderToDelete = folder
        }
    }

    private func toggleAllVisibleConversations() {
        let ids = menu.visibleConversationIDs
        if ids.isSubset(of: selectedIDs) { selectedIDs.subtract(ids) }
        else { selectedIDs.formUnion(ids) }
    }
    private func moveSelection(_ ids: Set<UUID>) {
        let existing = ids.intersection(menu.visibleConversationIDs)
        guard !existing.isEmpty else { return }
        searchFocused = false
        movingSelection = HistoryMoveSelection(ids: existing)
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
}

private struct HistoryMenuHeader: View {
    let selecting: Bool
    let newConversation: () -> Void
    let cancelSelection: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Eudes").font(.title3.weight(.medium))
                Spacer(minLength: 0)
                if selecting {
                    RoundButton(symbol: "arrow.uturn.backward", label: "Annuler la sélection", action: cancelSelection)
                        .accessibilityIdentifier("history.cancelSelection")
                } else {
                    RoundButton(symbol: "square.and.pencil", label: "Nouvelle conversation", action: newConversation)
                        .accessibilityIdentifier("history.newConversation")
                }
                RoundButton(symbol: "xmark", label: "Fermer les conversations", action: close)
                    .accessibilityIdentifier("history.close")
            }
            Text("Conversations").font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
        .background(Palette.historyBackground)
    }
}

private struct HistorySearchBar: View {
    @Binding var search: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted).accessibilityHidden(true)
            TextField("Rechercher", text: $search)
                .focused(focused).autocorrectionDisabled().submitLabel(.search)
                .onSubmit { focused.wrappedValue = false }
                .accessibilityLabel("Rechercher sur cet iPhone")
                .accessibilityIdentifier("history.search")
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Effacer la recherche")
                .accessibilityIdentifier("history.clearSearch")
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("history.searchSurface")
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Palette.historyBackground)
    }
}

private struct HistoryFoldersHeader: View {
    let add: () -> Void
    var body: some View {
        HStack {
            Text("DOSSIERS").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: add) {
                Image(systemName: "folder.badge.plus").font(.system(size: 20))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Créer un dossier")
            .accessibilityIdentifier("history.addFolder")
        }
        .textCase(nil)
    }
}

private struct HistoryRecentsHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let count: Int
    let expanded: Bool
    let searching: Bool
    let toggle: () -> Void
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        Button(action: toggle) {
            layout {
                Text("Récentes").font(.body.weight(.semibold))
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                HStack {
                    Text(count, format: .number)
                        .font(dynamicTypeSize.isAccessibilitySize ? .caption : .body)
                        .foregroundStyle(Palette.muted).monospacedDigit()
                    if dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(searching)
        .accessibilityLabel(count == 1 ? "Récentes, 1 conversation" : "Récentes, \(count) conversations")
        .accessibilityValue(expanded ? "Dépliées" : "Repliées")
        .accessibilityHint(searching ? "Les résultats restent visibles pendant la recherche." : "Afficher ou masquer les conversations récentes.")
        .accessibilityIdentifier("history.toggleRecents")
    }
}

private struct HistoryMenuEntryRow: View {
    let entry: HistoryMenuSnapshot.Entry
    let selecting: Bool
    let selectedIDs: Set<UUID>
    let searching: Bool
    let action: (HistoryMenuAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch entry {
            case .folder(let folder, let count, let expanded):
                HistoryFolderRow(folder: folder, count: count, expanded: expanded, searching: searching,
                                 toggle: { action(.toggleFolder(folder.id)) },
                                 rename: { action(.renameFolder(folder)) },
                                 delete: { action(.deleteFolder(folder)) })
            case .conversation(let conversation):
                HistoryConversationRow(conversation: conversation, inFolder: true, selecting: selecting,
                                       isSelected: selectedIDs.contains(conversation.id), action: action)
            }
        }
    }
}

private struct HistoryFolderRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let folder: ConversationFolder
    let count: Int
    let expanded: Bool
    let searching: Bool
    let toggle: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    var body: some View {
        let detailsLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: "folder").font(.system(size: 17))
                    .frame(width: 32, height: 32)
                    .background(Palette.userBubble, in: RoundedRectangle(cornerRadius: 10))
                detailsLayout {
                    Text(folder.name).font(.body).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    Text(count, format: .number)
                        .font(dynamicTypeSize.isAccessibilitySize ? .caption : .body)
                        .foregroundStyle(Palette.muted).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .foregroundStyle(Palette.ink)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(searching)
        .contextMenu {
            Button("Renommer", systemImage: "pencil", action: rename)
            Button("Supprimer le dossier", systemImage: "trash", role: .destructive, action: delete)
        }
        .accessibilityLabel(count == 1 ? "Dossier \(folder.name), 1 conversation" : "Dossier \(folder.name), \(count) conversations")
        .accessibilityValue(expanded ? "Ouvert" : "Fermé")
        .accessibilityAction(named: Text("Renommer"), rename)
        .accessibilityAction(named: Text("Supprimer le dossier"), delete)
        .accessibilityIdentifier("history.folder.\(folder.id.uuidString)")
    }
}

private struct HistoryConversationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let conversation: Conversation
    let inFolder: Bool
    let selecting: Bool
    let isSelected: Bool
    let action: (HistoryMenuAction) -> Void

    var body: some View {
        Button { action(.open(conversation)) } label: {
            HStack(spacing: 10) {
                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(Palette.accent)
                }
                Text(conversation.title).font(.body).foregroundStyle(Palette.ink)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, inFolder ? 12 : 0)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !selecting {
                Button("Déplacer vers un dossier", systemImage: "folder") { action(.move(conversation)) }
                if inFolder {
                    Button("Retirer du dossier", systemImage: "folder.badge.minus") { action(.removeFromFolder(conversation)) }
                }
                Button("Sélectionner", systemImage: "checkmark.circle") { action(.select(conversation)) }
                Button("Supprimer", systemImage: "trash", role: .destructive) { action(.delete(conversation)) }
            }
        }
        .accessibilityAction(named: Text("Activer la sélection multiple")) { action(.select(conversation)) }
        .accessibilityAction(named: Text("Déplacer vers un dossier")) { action(.move(conversation)) }
        .accessibilityAction(named: Text("Supprimer")) { action(.delete(conversation)) }
        .accessibilityValue(selecting ? (isSelected ? "Sélectionnée" : "Non sélectionnée") : "")
        .accessibilityIdentifier("history.conversation.\(conversation.id.uuidString)")
        .swipeActions(allowsFullSwipe: false) {
            if !selecting {
                Button("Supprimer", systemImage: "trash") { action(.delete(conversation)) }.tint(Palette.accent)
                Button("Déplacer", systemImage: "folder") { action(.move(conversation)) }.tint(.gray)
            }
        }
    }
}


private struct HistoryFolderEditor: Identifiable {
    let id = UUID()
    let folder: ConversationFolder?
}

private struct HistoryFolderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let folder: ConversationFolder?
    let save: (String) -> Bool
    @State private var name: String
    @State private var saveFailed = false
    init(folder: ConversationFolder?, save: @escaping (String) -> Bool) {
        self.folder = folder; self.save = save; _name = State(initialValue: folder?.name ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom du dossier", text: $name).submitLabel(.done)
                    .accessibilityIdentifier("history.folderName")
                if saveFailed {
                    Text("Impossible d’enregistrer le dossier. Réessaie.")
                        .foregroundStyle(.red).accessibilityIdentifier("history.folderSaveError")
                }
            }
            .navigationTitle(folder == nil ? "Nouveau dossier" : "Renommer le dossier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        if save(name) { dismiss() } else { saveFailed = true }
                    }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("history.saveFolder")
                }
            }
        }.presentationDetents([.medium, .large])
    }
}

private struct HistoryMoveSelection: Identifiable {
    let id = UUID()
    let ids: Set<UUID>
}

private struct HistoryMoveToFolderSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let ids: Set<UUID>
    let completed: () -> Void
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var moveFailed = false
    private var folders: [ConversationFolder] { (store.data.folders ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var body: some View {
        NavigationStack {
            List {
                if moveFailed {
                    Text("Impossible d’enregistrer le déplacement. Réessaie.")
                        .foregroundStyle(.red).accessibilityIdentifier("history.moveError")
                }
                ForEach(folders) { folder in
                    Button { move(to: folder.id) } label: {
                        Label(folder.name, systemImage: "folder")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("history.moveTo.\(folder.id.uuidString)")
                }
                Button { creatingFolder = true } label: {
                    Label("Nouveau dossier", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("history.moveNewFolder")
                Button { move(to: nil) } label: {
                    Label("Sans dossier", systemImage: "tray")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("history.moveUnfiled")
            }
            .navigationTitle(ids.count == 1 ? "Déplacer la conversation" : "Déplacer les conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } } }
            .alert("Nouveau dossier", isPresented: $creatingFolder) {
                TextField("Nom du dossier", text: $newFolderName)
                Button("Annuler", role: .cancel) { newFolderName = "" }
                Button("Créer et déplacer") {
                    if let id = store.createFolder(name: newFolderName) { move(to: id) }
                    else { moveFailed = true }
                    newFolderName = ""
                }.disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.presentationDetents([.medium, .large])
    }
    private func move(to folderID: UUID?) {
        if store.moveConversations(ids: ids, to: folderID) { completed(); dismiss() }
        else { moveFailed = true }
    }
}

private struct SelectAllConversationsRow: View {
    let filtered: Bool
    let total: Int
    let selected: Int
    let action: () -> Void

    private var allSelected: Bool { total > 0 && selected == total }
    private var symbol: String {
        allSelected ? "checkmark.circle.fill" : (selected > 0 ? "minus.circle.fill" : "circle")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(Palette.accent)
                if allSelected {
                    Text(filtered ? "Désélectionner tous les résultats" : "Désélectionner toutes les conversations")
                } else {
                    Text(filtered ? "Sélectionner tous les résultats" : "Sélectionner toutes les conversations")
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(allSelected ? "Tout sélectionné" : (selected > 0 ? "Sélection partielle" : "Aucune sélection"))
        .accessibilityIdentifier("history.selectAll")
    }
}

struct ConversationDeletionSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    @State private var doNotAskAgain = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Supprimer cette conversation ?").font(.title2.bold())
                Text(conversation.title).font(.headline).lineLimit(3)
                Text("Cette conversation sera supprimée de cet appareil. Les autres conversations seront conservées.")
                    .foregroundStyle(Palette.muted)
                Toggle(isOn: $doNotAskAgain) {
                    Label("Ne plus demander", systemImage: doNotAskAgain ? "checkmark.square.fill" : "square")
                }
                .toggleStyle(.button)
                .accessibilityIdentifier("deletion.doNotAskAgain")
                Text("Pour les prochaines suppressions individuelles de conversations.")
                    .font(.caption).foregroundStyle(Palette.muted)
                HStack {
                    Button("Annuler", role: .cancel) { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Supprimer") {
                        store.confirmConversationDeletion(conversation, doNotAskAgain: doNotAskAgain)
                        dismiss()
                    }.buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.onAccent)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.surface)
        }
        .presentationDetents([.medium, .large])
    }
}

private struct BulkConversationDeletion: Identifiable {
    let id = UUID()
    let ids: Set<UUID>
}

private struct BulkConversationDeletionSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let selection: BulkConversationDeletion
    let completed: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if selection.ids.count == 1 {
                        Text("Supprimer 1 conversation ?").font(.title2.bold())
                    } else {
                        Text("Supprimer \(selection.ids.count) conversations ?").font(.title2.bold())
                    }
                    Text("Seules les conversations sélectionnées seront supprimées de cet appareil. Cette action est irréversible.")
                    Button("Annuler", role: .cancel) { dismiss() }.buttonStyle(.bordered)
                    Button(role: .destructive) {
                        if store.confirmConversationDeletions(ids: selection.ids) { completed(); dismiss() }
                    } label: {
                        if selection.ids.count == 1 {
                            Text("Supprimer 1 conversation")
                        } else {
                            Text("Supprimer \(selection.ids.count) conversations")
                        }
                    }.buttonStyle(PrimaryButtonStyle())
                }.padding(24)
            }.background(Palette.surface)
        }.presentationDetents([.medium, .large])
    }
}
