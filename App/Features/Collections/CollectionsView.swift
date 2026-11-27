import SwiftUI

/// Collections tab: collapsible collections and series (action plan P4.1).
struct CollectionsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Collections",
                systemImage: "rectangle.stack",
                description: Text("Collections you create will appear here.")
            )
            .navigationTitle("Collections")
        }
    }
}
