import SwiftUI

struct RepeatingView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Coming Soon",
                systemImage: "repeat",
                description: Text("Repeating tasks will appear here in a future update.")
            )
            .navigationTitle("Repeating")
        }
    }
}

#Preview {
    RepeatingView()
}
