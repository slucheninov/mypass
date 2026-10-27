import SwiftUI
import AppKit
import MyPassKit

struct NSPasteboardClearing: PasteboardClearing {
    func currentString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func clearIfStillContains(_ value: String) {
        if currentString() == value {
            NSPasteboard.general.clearContents()
        }
    }
}

final class RealAutoLockClock: AutoLockClock {
    func scheduleTick(after seconds: TimeInterval, _ action: @escaping () -> Void) -> AutoLockCancelable {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in action() }
        return TimerCancelable(timer: timer)
    }
}

final class TimerCancelable: AutoLockCancelable {
    private let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
}

struct EntryDetailView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState
    @State private var isPasswordRevealed = false
    @State private var revealedExtraFields: Set<String> = []
    @State private var copiedField: CopiedField?
    @State private var copyFlashTask: Task<Void, Never>?
    @State private var now = Date()
    @State private var showHistory = false
    @State private var lastTouchedEntryID: UUID?
    @State private var largeTypeField: LargeTypeField?
    @State private var showWebsitesSheet = false
    @State private var showDeletePermanentlyAlert = false
    @State private var showPasskeyDetails = false

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private enum CopiedField: Equatable {
        case username
        case password
        case totp
        case extra(String)
    }

    private enum LargeTypeField: Equatable {
        case username
        case password
        case totp
    }

    private var currentEntry: KdbxEntry? {
        guard let database = vaultSession.currentDatabase, let id = navigationState.selectedEntryID else { return nil }
        return EntrySearch.allEntries(in: database.rootGroup).first { $0.uuid == id }
    }

    /// True when the current entry currently lives in the Recycle Bin group, i.e. it
    /// was soft-deleted and is awaiting restore or permanent purge.
    private func isInRecycleBin(_ entry: KdbxEntry) -> Bool {
        guard let database = vaultSession.currentDatabase,
              let binUUID = database.recycleBinGroupUUID,
              let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID }) else { return false }
        return bin.entries.contains(where: { $0.uuid == entry.uuid })
    }

    private func groupName(for entry: KdbxEntry) -> String? {
        guard let database = vaultSession.currentDatabase,
              let location = GroupTreeOperations.entryLocation(entryID: entry.uuid, in: database.rootGroup) else {
            return nil
        }
        return GroupTreeOperations.displayName(for: location.group, recycleBinGroupUUID: database.recycleBinGroupUUID)
    }

    var body: some View {
        if let entry = currentEntry {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        LetterAvatarView(
                            title: entry.displayTitle,
                            size: UIShellMetrics.detailHeroIconSize,
                            cornerRadius: UIShellMetrics.detailHeroIconCornerRadius,
                            letterScale: UIShellMetrics.detailHeroLetterScale
                        )
                        Text(verbatim: entry.displayTitle)
                            .font(.system(size: 22, weight: .bold))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    DetailFieldsCard {
                        copyableFieldRow(
                            label: "Username",
                            field: .username,
                            displayValue: entry.login,
                            copyValue: entry.login
                        )
                        .contextMenu {
                            Button("Copy Username") {
                                copy(entry.login)
                                flashCopied(.username)
                            }
                            Button("Show Large Type") {
                                largeTypeField = .username
                            }
                        }
                        .popover(isPresented: largeTypeBinding(.username)) {
                            LargeTypePopover(text: entry.login, isMonospaced: false)
                        }

                        DetailFieldDivider()

                        passwordRow(for: entry)
                            .contextMenu {
                                Button("Copy Password") {
                                    copy(entry.password)
                                    flashCopied(.password)
                                }
                                Button("Show Large Type") {
                                    largeTypeField = .password
                                }
                            }
                            .popover(isPresented: largeTypeBinding(.password)) {
                                LargeTypePopover(text: entry.password)
                            }

                        if let secret = entry.totpSecretBase32 {
                            DetailFieldDivider()
                            totpRow(secret: secret)
                                .contextMenu {
                                    Button("Copy Code") {
                                        copy(currentTOTPCode(secret: secret))
                                        flashCopied(.totp)
                                    }
                                    Button("Show Large Type") {
                                        largeTypeField = .totp
                                    }
                                }
                                .popover(isPresented: largeTypeBinding(.totp)) {
                                    LargeTypePopover(text: currentTOTPCode(secret: secret))
                                }
                        }

                        if entry.hasPasskey {
                            DetailFieldDivider()
                            passkeyRow(for: entry)
                        }

                        if !entry.urls.isEmpty {
                            DetailFieldDivider()
                            websiteRow(for: entry)
                                .contextMenu {
                                    Button("Open Website") { openWebsite(entry.url) }
                                    Button("Copy Website") { copy(entry.url) }
                                    Button("Change Website") { showWebsitesSheet = true }
                                }
                        }

                        if let groupName = groupName(for: entry) {
                            DetailFieldDivider()
                            DetailFieldRow(label: "Group", value: groupName)
                                .contextMenu {
                                    if let database = vaultSession.currentDatabase {
                                        let groups = GroupTreeOperations.selectableGroups(in: database.rootGroup, excludingRecycleBin: database.recycleBinGroupUUID)
                                        let currentGroupID = GroupTreeOperations.entryLocation(entryID: entry.uuid, in: database.rootGroup)?.group.uuid
                                        ForEach(groups, id: \.uuid) { group in
                                            Button {
                                                moveToGroup(group.uuid, entryID: entry.uuid)
                                            } label: {
                                                HStack {
                                                    Text(verbatim: GroupTreeOperations.displayName(for: group, recycleBinGroupUUID: database.recycleBinGroupUUID))
                                                    if group.uuid == currentGroupID {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                        }

                        DetailFieldDivider()

                        DetailFieldRow(
                            label: "Modified",
                            value: entry.lastModificationTime.formatted(date: .abbreviated, time: .shortened)
                        )

                        if !entry.notes.isEmpty {
                            DetailFieldDivider()
                            DetailFieldRow(label: "Notes", value: entry.notes)
                        }

                        ForEach(entry.additionalFields, id: \.key) { field in
                            DetailFieldDivider()
                            extraFieldRow(field)
                        }
                    }

                    Button("View History") { showHistory = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)

                    if isInRecycleBin(entry) {
                        HStack {
                            Button("Restore") {
                                vaultSession.mutate { database in
                                    // The entry's original source group isn't tracked once soft-deleted,
                                    // so root is the safe, predictable restore destination.
                                    GroupTreeOperations.restoreEntry(withID: entry.uuid, to: database.rootGroup.uuid, in: database.rootGroup)
                                }
                                navigationState.selectedEntryID = nil
                            }
                            Button("Delete Permanently…", role: .destructive) {
                                showDeletePermanentlyAlert = true
                            }
                            .foregroundStyle(.red)
                        }
                        .padding(.bottom, 24)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            }
            .background(UIShellMetrics.detailColumnBackground)
            .onReceive(timer) { now = $0 }
            .sheet(isPresented: $showHistory) {
                HistoryView(
                    entry: entry,
                    onRestore: { updated in
                        vaultSession.mutate { database in
                            EntryPersistence.replaceEntry(updated, in: database.rootGroup)
                        }
                        showHistory = false
                    },
                    onClearHistory: { updated in
                        vaultSession.mutate { database in
                            EntryPersistence.replaceEntry(updated, in: database.rootGroup)
                        }
                        showHistory = false
                    }
                )
            }
            .sheet(isPresented: $showWebsitesSheet) {
                WebsitesSheet(
                    entryID: entry.uuid,
                    entryTitle: entry.title,
                    initialURLs: entry.urls,
                    onDone: { _ in showWebsitesSheet = false },
                    onCancel: { showWebsitesSheet = false }
                )
            }
            .alert("Delete Permanently?", isPresented: $showDeletePermanentlyAlert) {
                Button("Delete Permanently", role: .destructive) {
                    vaultSession.mutate { database in
                        GroupTreeOperations.permanentlyDeleteEntry(withID: entry.uuid, in: database.rootGroup, deletedObjects: &database.deletedObjects)
                    }
                    navigationState.selectedEntryID = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This entry will be permanently deleted. This cannot be undone.")
            }
            .onChange(of: navigationState.selectedEntryID) { _, newID in
                isPasswordRevealed = false
                revealedExtraFields = []
                copiedField = nil
                copyFlashTask?.cancel()
                if let newID, newID != lastTouchedEntryID {
                    lastTouchedEntryID = newID
                    vaultSession.touchAccess(entryID: newID)
                }
            }
        } else {
            DetailEmptyStateView()
        }
    }

    private func copyableFieldRow(
        label: LocalizedStringKey,
        field: CopiedField,
        displayValue: String,
        copyValue: String
    ) -> some View {
        let shownValue = copiedField == field ? String(localized: "Copied", comment: "Brief confirmation shown in place of a copied field value") : displayValue

        return HStack(alignment: .center, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Button {
                copy(copyValue)
                flashCopied(field)
            } label: {
                Text(verbatim: shownValue)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Click to copy")
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func passwordRow(for entry: KdbxEntry) -> some View {
        let displayText: String = {
            if copiedField == .password { return String(localized: "Copied", comment: "Brief confirmation shown in place of a copied field value") }
            if isPasswordRevealed { return entry.password }
            return String(repeating: "•", count: max(entry.password.count, 8))
        }()

        return HStack(alignment: .center, spacing: 12) {
            Text("Password")
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Button {
                copy(entry.password)
                flashCopied(.password)
            } label: {
                Text(verbatim: displayText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Click to copy")
            Button {
                isPasswordRevealed.toggle()
            } label: {
                Image(systemName: isPasswordRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPasswordRevealed ? "Hide password" : "Show password")
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func websiteRow(for entry: KdbxEntry) -> some View {
        let domain = EntryURLDisplay.domain(from: entry.url) ?? entry.url

        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Website")
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(verbatim: domain)
                .foregroundStyle(Color.accentColor)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func extraFieldRow(_ field: KdbxField) -> some View {
        let fieldCase = CopiedField.extra(field.key)
        let isRevealed = revealedExtraFields.contains(field.key)
        let displayText: String = {
            if copiedField == fieldCase { return String(localized: "Copied", comment: "Brief confirmation shown in place of a copied field value") }
            if field.isProtected && !isRevealed {
                return String(repeating: "•", count: max(field.value.count, 8))
            }
            return field.value
        }()

        return HStack(alignment: .center, spacing: 12) {
            // Custom field names are vault data: shown exactly as stored.
            Text(verbatim: field.key)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Button {
                copy(field.value)
                flashCopied(fieldCase)
            } label: {
                Text(verbatim: displayText)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Click to copy")
            if field.isProtected {
                Button {
                    if isRevealed {
                        revealedExtraFields.remove(field.key)
                    } else {
                        revealedExtraFields.insert(field.key)
                    }
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isRevealed ? "Hide \(field.key)" : "Show \(field.key)")
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func totpRow(secret: String) -> some View {
        let code = currentTOTPCode(secret: secret)
        let displayValue = copiedField == .totp ? String(localized: "Copied", comment: "Brief confirmation shown in place of a copied field value") : code

        return HStack(alignment: .center, spacing: 12) {
            Text("Verification Code")
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Button {
                copy(code)
                flashCopied(.totp)
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: displayValue)
                        .font(.system(.body, design: .monospaced))
                    if copiedField != .totp {
                        TOTPCountdownRingView(period: 30, now: now)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Click to copy")
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func currentTOTPCode(secret: String) -> String {
        TOTPCode.currentCode(secretBase32: secret, digits: 6, period: 30, algorithm: .sha1, now: now) ?? "------"
    }

    private func flashCopied(_ field: CopiedField) {
        copyFlashTask?.cancel()
        copiedField = field
        copyFlashTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if copiedField == field {
                    copiedField = nil
                }
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ClipboardAutoClear.schedule(value: value, after: ClipboardClearInterval.seconds(), pasteboard: pasteboard, clock: clock)
        if let id = navigationState.selectedEntryID {
            vaultSession.touchAccess(entryID: id)
        }
    }

    private func largeTypeBinding(_ field: LargeTypeField) -> Binding<Bool> {
        Binding(
            get: { largeTypeField == field },
            set: { isPresented in largeTypeField = isPresented ? field : nil }
        )
    }

    private func openWebsite(_ urlString: String) {
        let normalized = urlString.contains("://") ? urlString : "https://\(urlString)"
        guard let url = URL(string: normalized) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Deliberately terse: the card answers "is there a passkey, and since when". The
    /// relying-party ID and credential ID are diagnostics, not everyday reading, so they
    /// live behind Show. Removal lives in the editor, next to every other destructive edit.
    private func passkeyRow(for entry: KdbxEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Passkey")
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(verbatim: passkeyCreatedDescription(entry.passkeyCreatedAt))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button("Show") { showPasskeyDetails = true }
                .buttonStyle(.link)
                .accessibilityLabel("Show passkey details")
                .popover(isPresented: $showPasskeyDetails, arrowEdge: .bottom) {
                    PasskeyDetailsPopover(entry: entry, footnote: "Remove this passkey by editing the entry.")
                }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// A passkey imported from KeePassXC carries no creation date — say so plainly
    /// rather than showing a date invented from the entry's own timestamps.
    private func passkeyCreatedDescription(_ created: Date?) -> String {
        guard let created else { return String(localized: "Added", comment: "Passkey row: shown when the passkey has no creation date") }
        return String(localized: "Added \(created.formatted(date: .abbreviated, time: .omitted))", comment: "Passkey row; the argument is the date the passkey was added")
    }

    private func moveToGroup(_ groupID: UUID, entryID: UUID) {
        vaultSession.mutate { database in
            GroupTreeOperations.moveEntry(withID: entryID, to: groupID, in: database.rootGroup)
        }
    }

}

private struct DetailEmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("BrandKey")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    width: UIShellMetrics.emptyStateIconSize,
                    height: UIShellMetrics.emptyStateIconSize
                )
                .saturation(0)
                .opacity(0.45)
                .accessibilityHidden(true)
            Text("Nothing Selected")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Select an entry from the list")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UIShellMetrics.detailColumnBackground)
    }
}

struct DetailFieldDivider: View {
    var body: some View {
        Divider().overlay(Color.primary.opacity(0.08))
    }
}

struct DetailFieldRow: View {
    /// Held as a `Text` so the two initialisers decide the localization path: interface labels
    /// ("Group", "Cardholder") come in as a `LocalizedStringKey` and reach the string catalog;
    /// vault-originated labels (custom field names) use `init(verbatimLabel:)` and are shown
    /// exactly as stored.
    private let label: Text
    let value: String

    init(label: LocalizedStringKey, value: String) {
        self.label = Text(label)
        self.value = value
    }

    init(verbatimLabel: String, value: String) {
        self.label = Text(verbatim: verbatimLabel)
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            label
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct DetailFieldsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .frame(maxWidth: UIShellMetrics.cardMaxWidth)
    }
}

