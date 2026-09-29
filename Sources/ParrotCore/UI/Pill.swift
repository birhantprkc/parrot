import AppKit
import SwiftUI

// The controls the onboarding and Settings windows share, styled after the
// Ollama app: capsules with a light fill and no border.

/// A capsule with a light fill, with a chevron when it opens a menu.
struct PillLabel: View {
    let title: String
    var chevron = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .contentShape(Capsule())
    }
}

/// A button drawn as a pill: `.buttonStyle(.pill)` with the light fill of a
/// `PillLabel`, or `.buttonStyle(.primaryPill)` filled in the text color, for
/// the one thing to do next.
struct PillButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    /// `.large` for the window's main button, such as Get Started.
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .padding(.horizontal, controlSize == .large ? 22 : 14)
            .padding(.vertical, controlSize == .large ? 9 : 6)
            .background(Capsule().fill(fill(pressed: configuration.isPressed)))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.35)
    }

    private func fill(pressed: Bool) -> Color {
        primary
            ? Color.primary.opacity(pressed ? 0.8 : 1)
            : Color.primary.opacity(pressed ? 0.14 : 0.08)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var primaryPill: PillButtonStyle { PillButtonStyle(primary: true) }
}

/// A menu whose closed state is a `PillLabel` with a chevron.
struct PillMenu<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu(content: content) {
            PillLabel(title: title, chevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A settings row with its control centered beside the label. Not
/// `LabeledContent`, which lines the pill's text up with the label's
/// baseline and so drops the pill below center.
struct PillRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control

    init(_ label: String, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(label)
            Spacer()
            control()
        }
    }
}

/// The Parrot bird in the text color: white in dark mode, black in light.
struct BirdBadge: View {
    var size: CGFloat = 64

    private static let bird: NSImage? = {
        guard let image = NSImage(data: Data(MenuBarController.birdSVG.utf8)) else { return nil }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        if let bird = Self.bird {
            Image(nsImage: bird)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
        }
    }
}

/// Checkboxes for the languages the user speaks, in a popover so ticks stay
/// open between clicks, which a menu can't do: the Mac's languages, the
/// common ones, then More Languages (`Onboarding.languageMenu`).
struct LanguageChecklist<Footer: View>: View {
    let ticked: [String]
    let toggle: (String) -> Void
    @ViewBuilder var footer: () -> Footer
    @State private var showsMore = false

    private let menu = Onboarding.languageMenu(preferred: SpokenLanguage.preferredCodes())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                rows(menu.mac)
                if !menu.mac.isEmpty { Divider().padding(.vertical, 2) }
                rows(menu.common)
                Divider().padding(.vertical, 2)
                DisclosureGroup("More Languages", isExpanded: $showsMore) {
                    VStack(alignment: .leading, spacing: 6) {
                        rows(menu.more)
                    }
                    .padding(.top, 6)
                }
                footer()
            }
            .padding(14)
        }
        .frame(width: 240, height: 340)
    }

    private func rows(_ codes: [String]) -> some View {
        ForEach(codes, id: \.self) { code in
            Toggle(SpokenLanguage.displayName(code), isOn: Binding(
                get: { ticked.contains(code) },
                set: { _ in toggle(code) }
            ))
            .toggleStyle(.checkbox)
        }
    }
}

extension LanguageChecklist where Footer == EmptyView {
    init(ticked: [String], toggle: @escaping (String) -> Void) {
        self.init(ticked: ticked, toggle: toggle, footer: { EmptyView() })
    }
}
