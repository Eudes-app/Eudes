import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct EudesVoiceWidgetBundle: WidgetBundle {
    var body: some Widget {
        EudesVoiceActivityWidget()
    }
}

struct EudesVoiceActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            VoiceActivityCard(phase: context.state.phase, sessionID: context.attributes.sessionID)
                .padding(16)
                .widgetURL(VoiceActivityAttributes.url(for: context.attributes.sessionID))
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Eudes", systemImage: "waveform")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        Label {
                            Text(context.state.phase.title)
                        } icon: {
                            Image(systemName: context.state.phase.systemImage)
                        }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VoiceStopButton(sessionID: context.attributes.sessionID)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .accessibilityLabel("Assistant vocal Eudes")
            } compactTrailing: {
                Image(systemName: context.state.phase.systemImage)
                    .accessibilityLabel(Text(context.state.phase.title))
            } minimal: {
                Image(systemName: context.state.phase.systemImage)
                    .accessibilityLabel(Text(context.state.phase.title))
            }
            .keylineTint(.gray)
            .widgetURL(VoiceActivityAttributes.url(for: context.attributes.sessionID))
        }
    }
}

private struct VoiceActivityCard: View {
    let phase: VoiceActivityPhase
    let sessionID: UUID

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: phase.systemImage)
                .font(.title2)
                .frame(width: 42, height: 42)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Eudes")
                    .font(.headline)
                Text(phase.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VoiceStopButton(sessionID: sessionID)
        }
        .foregroundStyle(.primary)
    }
}

private struct VoiceStopButton: View {
    let sessionID: UUID

    var body: some View {
        Button(intent: StopEudesVoiceIntent(sessionID: sessionID)) {
            Label("Arrêter", systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color.primary.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Arrêter l’assistant vocal Eudes")
    }
}
