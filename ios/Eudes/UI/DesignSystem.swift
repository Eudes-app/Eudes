import SwiftUI

/// Semantic monochrome tokens shared by every screen and presentation.
enum Palette {
    static let accent = Color(light: 0x171717, dark: 0xFFFFFF)
    static let background = Color(light: 0xFFFFFF, dark: 0x171717)
    static let backgroundTop = Color(light: 0xFFFFFF, dark: 0x303030)
    static let backgroundMiddle = Color(light: 0xFFFFFF, dark: 0x242424)
    static let surface = Color(light: 0xF7F7F7, dark: 0x242424)
    static let historyBackground = Color(light: 0xFFFFFF, dark: 0x171717)
    static let userBubble = Color(light: 0xF0F0F0, dark: 0x343434)
    static let assistantBubble = Color(light: 0xFAFAFA, dark: 0x252525)
    static let ink = Color(light: 0x171717, dark: 0xFFFFFF)
    static let warningText = Color(light: 0xB42318, dark: 0xFF6961)
    static let muted = Color(light: 0x777777, dark: 0xA3A3A3)
    static let border = Color(light: 0xE8E8E8, dark: 0x383838)
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x000000)
    static let scrim = Color.black.opacity(0.25)
    static let shadow = Color.black.opacity(0.08)
    static let cornerRadius: CGFloat = 14
    static let separatorWidth: CGFloat = 0.5
}

struct ThemeBackground: View {
    var body: some View {
        LinearGradient(colors: [Palette.backgroundTop, Palette.backgroundMiddle, Palette.background],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

extension View {
    func themedPanel(background: Color = Palette.surface) -> some View {
        self.foregroundStyle(Palette.ink)
            .tint(Palette.accent)
            .background(background)
            .toolbarBackground(background, for: .navigationBar)
    }
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

struct BrandMark: View {
    var size: CGFloat = 48
    var body: some View {
        Image(UIApplication.shared.alternateIconName == "AppIconWhite" ? "RibbonWhite" : "RibbonDark")
            .resizable().scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct LocalBadge: View {
    var body: some View {
        Label("RÉSEAU LOCAL", systemImage: "lock.shield")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.3)
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Palette.accent.opacity(0.1), in: Capsule())
    }
}

struct RoundButton: View {
    let symbol: String
    let label: String
    var floating = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            RoundControlLabel(symbol: symbol, floating: floating)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Shared label, so native menus keep the same surface without nesting a Button.
struct RoundControlLabel: View {
    let symbol: String
    var floating = false
    var body: some View {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .modifier(FloatingControlSurface(floating: floating))
                .overlay(Circle().stroke(Palette.border.opacity(0.65), lineWidth: 0.5))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
            .foregroundStyle(Palette.onAccent)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Apply the choice to this app window so every presentation inherits it.
/// Unspecified truly releases the override and follows subsequent iOS changes.
struct WindowAppearance: UIViewRepresentable {
    let appearance: AppAppearance

    func makeUIView(context: Context) -> AppearanceView {
        let view = AppearanceView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: AppearanceView, context: Context) {
        switch appearance {
        case .automatic: view.style = .unspecified
        case .light: view.style = .light
        case .dark: view.style = .dark
        }
        view.apply()
    }

    final class AppearanceView: UIView {
        var style: UIUserInterfaceStyle = .unspecified
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }
        func apply() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }
}

/// A single opt-in surface policy for custom controls. Native navigation remains system styled.
private struct EudesControlSurface<S: Shape>: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: S
    let fallback: Color
    let interactive: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), store.liquidGlassEnabled,
           !reduceTransparency, contrast != .increased {
            content.glassEffect(.regular.interactive(interactive && !reduceMotion), in: shape)
        } else {
            content.background(fallback, in: shape)
        }
    }
}

extension View {
    func controlSurface<S: Shape>(in shape: S, fallback: Color = Palette.surface,
                                  interactive: Bool = false) -> some View {
        modifier(EudesControlSurface(shape: shape, fallback: fallback, interactive: interactive))
    }
}

struct EudesTextFieldStyle: TextFieldStyle {
    @EnvironmentObject private var store: AppStore
    func _body(configuration: TextField<Self._Label>) -> some View {
        if store.liquidGlassEnabled {
            configuration.padding(10).controlSurface(in: RoundedRectangle(cornerRadius: Palette.cornerRadius))
        } else { configuration }
    }
}

/// Poids d'un modèle en cinq paliers absolus, indépendants de l'appareil.
/// Le palier se déduit du poids total téléchargé (fichiers du modèle et, pour la
/// vision, le projecteur d'images) : aucune valeur n'est écrite par modèle.
enum ModelWeightLevel: Int, CaseIterable, Sendable {
    case veryLight = 1
    case light = 2
    case medium = 3
    case heavy = 4
    case veryHeavy = 5

    static func forBytes(_ bytes: Int64) -> ModelWeightLevel {
        switch bytes {
        case ..<1_200_000_000: .veryLight
        case ..<1_700_000_000: .light
        case ..<2_600_000_000: .medium
        case ..<4_200_000_000: .heavy
        default: .veryHeavy
        }
    }

    var label: String {
        switch self {
        case .veryLight: "Très léger"
        case .light: "Léger"
        case .medium: "Moyen"
        case .heavy: "Lourd"
        case .veryHeavy: "Très lourd"
        }
    }

    /// Couleur du segment à cette position, du vert au rouge.
    static func segmentColor(_ index: Int) -> Color {
        switch index {
        case 1: Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)
        case 2: Color(red: 132 / 255, green: 204 / 255, blue: 22 / 255)
        case 3: Color(red: 234 / 255, green: 179 / 255, blue: 8 / 255)
        case 4: Color(red: 249 / 255, green: 115 / 255, blue: 22 / 255)
        default: Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)
        }
    }

    static let emptyColor = Color(red: 56 / 255, green: 56 / 255, blue: 56 / 255)
}

/// Cinq segments arrondis : les `level` premiers prennent leur couleur, les autres
/// restent gris. La version compacte, sans étiquette, tient sur une ligne de liste.
struct ModelWeightGauge: View {
    let level: ModelWeightLevel
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 2 : 3) {
            ForEach(1...5, id: \.self) { index in
                Capsule()
                    .fill(index <= level.rawValue
                          ? ModelWeightLevel.segmentColor(index)
                          : ModelWeightLevel.emptyColor)
                    .frame(width: compact ? 5 : 12, height: compact ? 4 : 5)
            }
            if !compact {
                Text(level.label)
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Poids : \(level.label)")
        .accessibilityValue("\(level.rawValue) sur 5")
    }
}

/// Bande de démonstration : les cinq couleurs de la jauge, dans l'ordre.
struct ModelWeightLegend: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { index in
                Capsule()
                    .fill(ModelWeightLevel.segmentColor(index))
                    .frame(height: 6)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Only the four conversation controls use a frosted fallback when Liquid Glass is off.
/// Accessibility always wins: the local button surface becomes fully opaque.
private struct FloatingControlSurface: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let floating: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if floating && !store.liquidGlassEnabled && !reduceTransparency && contrast != .increased {
            content.background(.regularMaterial, in: Circle())
        } else {
            content.controlSurface(in: Circle(), interactive: true)
        }
    }
}
