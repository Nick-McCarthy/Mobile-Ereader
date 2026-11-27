import SwiftUI

extension ShapeStyle where Self == Color {
    /// Secondary text that still meets the 4.5:1 contrast ratio at small sizes, in light and dark mode.
    /// The system `.secondary` falls just short, and the accessibility audit flags it (audit A1.9).
    static var secondaryText: Color { Color.primary.opacity(0.75) }
}
