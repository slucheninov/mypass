import SwiftUI

struct FavoriteToggleToolbarItem: ToolbarContent {
    @Binding var isFavorite: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
            }
            .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }
}

struct DetailActionsToolbarContent: ToolbarContent {
    let onEdit: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Edit", systemImage: "square.and.pencil", action: onEdit)
        }
    }
}

struct EditActionsToolbarContent: ToolbarContent {
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: onSave)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }
}
