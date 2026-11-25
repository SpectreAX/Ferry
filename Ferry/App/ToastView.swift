import SwiftUI

/// Small, non-interactive capsule shown at the bottom of the window.
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .allowsHitTesting(false)
    }
}
