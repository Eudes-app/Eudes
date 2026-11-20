import ActivityKit
import Foundation

/// Only an opaque session identifier and its state are exposed on the Lock Screen.
/// Questions, answers, server addresses and credentials never enter ActivityKit.
struct VoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: VoiceActivityPhase
    }

    let sessionID: UUID

    static func url(for id: UUID) -> URL { URL(string: "eudes://voice/" + id.uuidString)! }
    static func sessionID(from url: URL) -> UUID? {
        guard url.scheme == "eudes", url.host == "voice", url.query == nil,
              url.fragment == nil, url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

enum VoiceActivityPhase: String, Codable, Hashable, Sendable {
    case preparing, listening, thinking, speaking, waiting

    var title: LocalizedStringResource {
        switch self {
        case .preparing: "Préparation"
        case .listening: "À ton écoute"
        case .thinking: "Réflexion en cours"
        case .speaking: "Réponse en cours"
        case .waiting: "Ouvrir Eudes pour continuer"
        }
    }

    var systemImage: String {
        switch self {
        case .preparing: "waveform"
        case .listening: "mic.fill"
        case .thinking: "ellipsis.bubble"
        case .speaking: "speaker.wave.2.fill"
        case .waiting: "hand.tap"
        }
    }
}
