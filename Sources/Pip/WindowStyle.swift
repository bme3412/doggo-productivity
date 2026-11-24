import SwiftUI

struct DoggoWindowHeader<Title: View>: View {
    @ViewBuilder var title: () -> Title

    var body: some View {
        HStack(spacing: 12) {
            title()
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white)
            Spacer(minLength: 0)
            Image(systemName: "pawprint.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.reportHighlight)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(Theme.reportGradient)
    }
}

extension View {
    func doggoWindowCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return background(Color(nsColor: .textBackgroundColor), in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(LibraryColors.line.opacity(0.8)).allowsHitTesting(false) }
    }
}
