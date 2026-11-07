import SwiftUI

/// Offer shown above the notes card when an unsaved draft newer than the saved note exists.
struct NoteDraftBanner: View {
    let draft: NoteDraftVersion
    let onRestore: () -> Void
    let onShowAll: () -> Void
    let onDelete: () -> Void

    /// Shared with the versions sheet so both show timestamps the same way.
    static func formatted(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    static func message(for date: Date, locale: Locale = .current) -> String {
        let when = formatted(date, locale: locale)
        return String(format: String(localized: "Unsaved draft found from %@", locale: locale), locale: locale, when)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text(verbatim: Self.message(for: draft.savedAt))
                .font(.callout)
            Spacer(minLength: 8)
            Button("Restore", action: onRestore)
                .accessibilityIdentifier("noteDraft.restore")
            Button("All versions", action: onShowAll)
                .accessibilityIdentifier("noteDraft.allVersions")
            Button("Delete", role: .destructive, action: onDelete)
                .accessibilityIdentifier("noteDraft.delete")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Banner plus versions sheet bound to one editor's draft model; empty when no draft is pending.
struct NoteDraftRecoverySection: View {
    @ObservedObject var model: NoteDraftEditorModel

    var body: some View {
        Group {
            if let draft = model.pendingDraft {
                NoteDraftBanner(
                    draft: draft,
                    onRestore: { model.restore(draft) },
                    onShowAll: { model.showsVersions = true },
                    onDelete: { model.deleteDrafts() }
                )
            }
        }
        .sheet(isPresented: $model.showsVersions) {
            NoteDraftVersionsSheet(
                versions: model.versions,
                onRestore: { model.restore($0) },
                onClose: { model.showsVersions = false }
            )
        }
    }
}
