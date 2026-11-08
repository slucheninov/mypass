import SwiftUI
import MyPassKit

/// Read-only view of a Files item: the attachments are the main content, with an
/// optional plain-text description underneath.
struct FilesDetailView: View {
    let entry: KdbxEntry
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(SmartCategory.files.accentColor)
                        .frame(width: UIShellMetrics.detailHeroIconSize, height: UIShellMetrics.detailHeroIconSize)
                        .background(
                            RoundedRectangle(cornerRadius: UIShellMetrics.detailHeroIconCornerRadius, style: .continuous)
                                .fill(Color.secondary.opacity(0.15))
                        )
                    Text(verbatim: entry.displayTitle)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                if entry.attachments.isEmpty {
                    Text("No files attached.")
                        .foregroundStyle(.secondary)
                }
                AttachmentsDetailSection(attachments: entry.attachments)

                if !entry.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DetailFieldsCard {
                        Text(verbatim: entry.notes)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle("Files")
        .onChange(of: navigationState.selectedEntryID) { _, newID in
            if let newID {
                vaultSession.touchAccess(entryID: newID)
            }
        }
    }
}
