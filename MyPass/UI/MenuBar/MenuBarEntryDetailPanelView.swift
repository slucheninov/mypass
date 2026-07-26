import SwiftUI
import AppKit
import MyPassKit

struct MenuBarEntryDetailPanelView: View {
    @EnvironmentObject private var vaultSession: VaultSession

    let entry: KdbxEntry
    let onBack: () -> Void

    @State private var isPasswordRevealed = false
    @State private var now = Date()
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()

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
                    fieldsCard
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
            Button("< Back", action: onBack)
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Menu {
                Button("Edit") { }
                    .disabled(true)
                Button("Share") { }
                    .disabled(true)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var heroSection: some View {
        VStack(spacing: 4) {
            LetterAvatarView(
                title: displayTitle,
                size: 40,
                cornerRadius: 10
            )
            Text(displayTitle)
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("Last modified: \(entry.lastModificationTime.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private var fieldsCard: some View {
        VStack(spacing: 0) {
            fieldRow(label: "Username", value: entry.login) {
                copy(entry.login)
            }

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
            Text(isPasswordRevealed ? entry.password : String(repeating: "•", count: max(entry.password.count, 8)))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                isPasswordRevealed.toggle()
            } label: {
                Image(systemName: isPasswordRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPasswordRevealed ? "Hide" : "Show")
            copyButton { copy(entry.password) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func totpRow(secret: String) -> some View {
        let code = TOTPCode.currentCode(secretBase32: secret, digits: 6, period: 30, algorithm: .sha1, now: now) ?? "------"
        return HStack(alignment: .center, spacing: 6) {
            Text("Code")
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(code)
                .font(.system(.body, design: .monospaced))
                .layoutPriority(1)
            MenuBarTOTPRingChrome()
            Spacer(minLength: 0)
            copyButton { copy(code) }
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

    private func fieldRow(label: String, value: String, copyAction: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            copyButton(action: copyAction)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func copyButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Copy")
    }

    private func fieldDivider() -> some View {
        Divider().overlay(Color.primary.opacity(0.08))
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
