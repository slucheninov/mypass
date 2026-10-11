import SwiftUI
import AppKit
import MyPassKit

struct MenuBarEntryDetailPanelView: View {
    @EnvironmentObject private var vaultSession: VaultSession
    @EnvironmentObject private var navigationState: NavigationState
    @Environment(\.openWindow) private var openWindow

    let entry: KdbxEntry
    let onBack: () -> Void

    @State private var copiedField: CopiedField?
    @State private var isPasswordHovered = false
    @State private var copyFlashTask: Task<Void, Never>?
    @State private var now = Date()
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()

    private enum CopiedField {
        case username
        case password
        case totp
    }

    private var menuBarPanelMaxHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 400
        return min(440, screenHeight * 0.55)
    }

    private var displayTitle: String {
        entry.title.isEmpty ? "(untitled)" : entry.title
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 12) {
                    heroSection
                    if entry.entryType == .address {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.addressSummary)
                            Text([entry.address.addressLine1, entry.address.addressLine2, entry.address.postalCode, entry.address.countryName].filter { !$0.isEmpty }.joined(separator: "\n"))
                                .foregroundStyle(.secondary)
                            Button("Edit Address in MyPass", action: openEntryForEdit)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        fieldsCard
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 320)
        .frame(maxHeight: menuBarPanelMaxHeight)
        .onReceive(timer) { now = $0 }
    }

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Back")

            Spacer()

            Button(action: openEntryForEdit) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func openEntryForEdit() {
        navigationState.selectedEntryID = entry.uuid
        navigationState.presentEdit(entryID: entry.uuid)
        MenuBarPanelDismisser.dismiss()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    private var heroSection: some View {
        HStack(alignment: .center, spacing: 12) {
            if entry.entryType == .address {
                Image(systemName: "house.fill").font(.title).foregroundStyle(.teal).frame(width: 44, height: 44)
            } else {
                LetterAvatarView(title: displayTitle, size: 44, cornerRadius: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text("Last modified: \(entry.lastModificationTime.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fieldsCard: some View {
        VStack(spacing: 0) {
            copyableFieldRow(
                label: "Username",
                field: .username,
                displayValue: entry.login,
                copyValue: entry.login
            )

            fieldDivider()

            passwordRow

            if let secret = entry.totpSecretBase32 {
                fieldDivider()
                totpRow(secret: secret)
            }

            if !entry.url.isEmpty {
                fieldDivider()
                websiteRow
            }
        }
        .background(
            RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var passwordRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Password")
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Button {
                copy(entry.password)
                flashCopied(.password)
            } label: {
                Text(passwordDisplayText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityHint("Click to copy")
            .onHover { isPasswordHovered = $0 }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var passwordDisplayText: String {
        if copiedField == .password {
            return "Copied"
        }
        if isPasswordHovered {
            return entry.password
        }
        return String(repeating: "•", count: max(entry.password.count, 8))
    }

    private func totpRow(secret: String) -> some View {
        let code = TOTPCode.currentCode(secretBase32: secret, digits: 6, period: 30, algorithm: .sha1, now: now) ?? "------"
        let displayValue = copiedField == .totp ? "Copied" : code

        return HStack(alignment: .center, spacing: 6) {
            Text("Code")
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Button {
                copy(code)
                flashCopied(.totp)
            } label: {
                HStack(spacing: 6) {
                    Text(displayValue)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    if copiedField != .totp {
                        MenuBarTOTPRingChrome()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityHint("Click to copy")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var websiteRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Website")
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            if let url = URL(string: entry.url), !entry.url.isEmpty {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text(entry.url)
                            .lineLimit(1)
                        Image(systemName: "safari")
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(entry.url)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func copyableFieldRow(
        label: String,
        field: CopiedField,
        displayValue: String,
        copyValue: String
    ) -> some View {
        let shownValue = copiedField == field ? "Copied" : displayValue

        return HStack(alignment: .center, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Button {
                copy(copyValue)
                flashCopied(field)
            } label: {
                Text(shownValue)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityHint("Click to copy")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func fieldDivider() -> some View {
        Divider().overlay(Color.primary.opacity(0.08))
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
        vaultSession.touchAccess(entryID: entry.uuid)
    }
}

private struct MenuBarTOTPRingChrome: View {
    var body: some View {
        Circle()
            .stroke(Color.green.opacity(0.65), lineWidth: 2)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}
