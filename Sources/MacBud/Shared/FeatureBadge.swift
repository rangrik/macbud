import SwiftUI

/// A small coordinated palette keeps each tool recognizable against the black notch.
enum FeatureArt {
    case clipboard, snippets, screenshots, dictation, keepAwake, apps

    var colors: [Color] {
        switch self {
        case .clipboard: [Color(red: 0.26, green: 0.79, blue: 1), Color(red: 0.18, green: 0.39, blue: 0.94)]
        case .snippets: [Color(red: 1, green: 0.68, blue: 0.35), Color(red: 0.98, green: 0.34, blue: 0.48)]
        case .screenshots: [Color(red: 0.36, green: 0.94, blue: 0.72), Color(red: 0.06, green: 0.64, blue: 0.60)]
        case .dictation: [Color(red: 0.82, green: 0.57, blue: 1), Color(red: 0.48, green: 0.32, blue: 0.94)]
        case .keepAwake: [Color(red: 1, green: 0.85, blue: 0.34), Color(red: 1, green: 0.49, blue: 0.19)]
        case .apps: [Color(red: 1, green: 0.44, blue: 0.46), Color(red: 0.83, green: 0.12, blue: 0.32)]
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard.fill"
        case .snippets: "text.quote"
        case .screenshots: "photo.fill"
        case .dictation: "waveform"
        case .keepAwake: "sun.max.fill"
        case .apps: "square.grid.2x2.fill"
        }
    }
}

extension Section {
    var artwork: FeatureArt {
        switch self {
        case .clipboard: .clipboard
        case .snippets: .snippets
        case .screenshots: .screenshots
        case .dictationHistory: .dictation
        case .apps: .apps
        }
    }
}

struct FeatureBadge: View {
    let kind: FeatureArt
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: kind.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.29).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// The user's sunrise artwork, shared by the notch and welcome screen.
struct MacBudMark: View {
    var size: CGFloat = 24

    var body: some View {
        Image("MacBudMark")
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
