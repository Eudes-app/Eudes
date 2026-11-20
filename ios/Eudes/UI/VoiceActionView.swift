import SwiftUI
import EventKit
import MessageUI
import UIKit

/// A proposal is held only by the foreground voice screen, never persisted/replayed.
struct VoiceActionView: View {
    let action: VoiceAction
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var isSaving = false
    @State private var hasExecuted = false
    @State private var showMessage = false
    @State private var error: String?
    @State private var eventStore = EKEventStore()

    init(action: VoiceAction, onResult: @escaping (String) -> Void) {
        self.action = action
        self.onResult = onResult
        _title = State(initialValue: action.value)
        let date = action.date.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        _start = State(initialValue: date)
        _end = State(initialValue: action.endDate.flatMap { ISO8601DateFormatter().date(from: $0) } ?? date.addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Action proposée") {
                    switch action.kind {
                    case .reminder, .event:
                        TextField("Titre", text: $title)
                        DatePicker("Date et heure", selection: $start)
                        if action.kind == .event { DatePicker("Fin", selection: $end, in: start...) }
                    case .sms:
                        Text("Destinataire demandé : \(action.value)")
                        Text(action.body ?? "")
                        Text("Vérifie le destinataire dans Messages avant d’envoyer. Aucun message n’est envoyé automatiquement.")
                            .font(.footnote)
                    default:
                        Text(action.value)
                        if let url = action.url { Text(url.absoluteString).font(.footnote).textSelection(.enabled) }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button(action.kind == .sms ? "Préparer dans Messages" : action.kind == .reminder || action.kind == .event ? "Créer" : "Ouvrir") {
                        Task { await execute() }
                    }
                    .disabled(isSaving || hasExecuted || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("voice.action.confirm")
                }
            }
            .navigationTitle(action.kind == .reminder ? "Créer un rappel" : action.kind == .event ? "Créer un événement" : "Vérifier l’action")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { onResult("Action annulée."); dismiss() }.disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .sheet(isPresented: $showMessage) {
                VoiceMessageComposer(action: action) { result in
                    showMessage = false
                    onResult(result)
                    dismiss()
                }
            }
        }
    }

    @MainActor private func execute() async {
        guard !isSaving, !hasExecuted else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            guard UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable else { throw VoiceActionError.foreground }
            if action.kind == .sms {
                guard MFMessageComposeViewController.canSendText() else { throw VoiceActionError.unavailable }
                showMessage = true
                return
            }
            if action.kind == .reminder {
                guard try await eventStore.requestFullAccessToReminders() else { throw VoiceActionError.unavailable }
                try Task.checkCancellation()
                guard UIApplication.shared.applicationState == .active else { throw VoiceActionError.foreground }
                guard let calendar = eventStore.defaultCalendarForNewReminders() else { throw VoiceActionError.unavailable }
                let reminder = EKReminder(eventStore: eventStore)
                reminder.calendar = calendar
                reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .timeZone], from: start)
                reminder.addAlarm(EKAlarm(absoluteDate: start))
                try eventStore.save(reminder, commit: true)
                onResult("Rappel créé : \(title).")
            } else if action.kind == .event {
                guard end > start else { throw VoiceActionError.missingDate }
                guard try await eventStore.requestWriteOnlyAccessToEvents() else { throw VoiceActionError.unavailable }
                try Task.checkCancellation()
                guard UIApplication.shared.applicationState == .active else { throw VoiceActionError.foreground }
                guard let calendar = eventStore.defaultCalendarForNewEvents else { throw VoiceActionError.unavailable }
                let event = EKEvent(eventStore: eventStore)
                event.calendar = calendar
                event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                event.startDate = start
                event.endDate = end
                try eventStore.save(event, span: .thisEvent, commit: true)
                onResult("Événement créé : \(title).")
            } else {
                let result = try await VoiceActionOpening.open(action)
                onResult(result)
            }
            hasExecuted = true
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
enum VoiceActionOpening {
    static func open(_ action: VoiceAction) async throws -> String {
        _ = try action.validated()
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable else { throw VoiceActionError.foreground }
        guard let url = action.url else { throw VoiceActionError.invalid }
        let opened = await UIApplication.shared.open(url)
        return opened ? "Ouverture effectuée : \(action.value)." : "Impossible d’ouvrir \(action.value). Vérifie que l’application est installée."
    }
}

private struct VoiceMessageComposer: UIViewControllerRepresentable {
    let action: VoiceAction
    let completion: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.body = action.body
        // Names are not phone numbers: leave native contact selection to the person.
        if action.value.range(of: "^\\+?[0-9 ()-]{6,25}$", options: .regularExpression) != nil {
            controller.recipients = [action.value]
        }
        return controller
    }
    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) { }
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let completion: (String) -> Void
        init(completion: @escaping (String) -> Void) { self.completion = completion }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            switch result {
            case .sent: completion("Message envoyé.")
            case .cancelled: completion("Message annulé.")
            case .failed: completion("Le message n’a pas pu être envoyé.")
            @unknown default: completion("Envoi du message non confirmé.")
            }
        }
    }
}
