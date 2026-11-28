import SwiftUI
import UIKit

extension ShapeStyle where Self == Color {
    /// Secondary text that still meets the 4.5:1 contrast ratio at small sizes, in light and dark mode.
    /// The system `.secondary` falls just short, and the accessibility audit flags it (audit A1.9).
    static var secondaryText: Color { Color.primary.opacity(0.75) }

    /// The app's tint: a blue that meets 4.5:1 as text on grouped backgrounds in light and dark mode.
    /// The system blue falls just short in light mode, and the accessibility audit flags button text.
    static var accessibleAccent: Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.40, green: 0.66, blue: 1.00, alpha: 1)
                    : UIColor(red: 0.00, green: 0.36, blue: 0.80, alpha: 1)
            }
        )
    }
}
