import SwiftUI
import Combine
import MyPassKit

/// Bordered card hosting the notes editor: label, toolbar row (undo, redo, draft
/// status, optional markdown buttons) and the text view itself. Colours are system
/// semantic ones so the card reads correctly in light and dark mode.
struct NotesEditorCard: View {
    @Binding var text: String
    /// Draft-restore requests; each one becomes an undoable `.replaceAll` command.
    private let restoreRequests: AnyPublisher<String, Never>
    let entryID: UUID
    @ObservedObject private var controller: DraftControllerBox
    let placeholder: LocalizedStringKey
    let showsMarkdownToolbar: Bool

    @State private var wrapAction: MarkdownWrapAction?
    @State private var command: MarkdownEditorCommand?
    @State private var canUndo = false
    @State private var canRedo = false
    /// A @State-held publisher keeps one 10 s cadence across the re-inits that every
    /// keystroke causes; a stored `let` would restart the timer on each edit.
    @State private var ticker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    init(
        text: Binding<String>,
        restoreRequests: AnyPublisher<String, Never> = Empty().eraseToAnyPublisher(),
        entryID: UUID,
        controller: NoteDraftController?,
        placeholder: LocalizedStringKey = "Add notes",
        showsMarkdownToolbar: Bool = false
    ) {
        _text = text
        self.restoreRequests = restoreRequests
        self.entryID = entryID
        self.controller = DraftControllerBox(controller)
        self.placeholder = placeholder
        self.showsMarkdownToolbar = showsMarkdownToolbar
    }

    /// A restore must be one undo step, hence `.replaceAll` and not a plain text assignment.
    static func command(forRestoring text: String) -> MarkdownEditorCommand {
        .replaceAll(text)
    }

    /// Short "Draft saved 1:05 PM" status, nil when nothing has been saved yet.
    static func statusText(lastSavedAt: Date?, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let lastSavedAt else { return nil }
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                     timeZone: calendar.timeZone)
        style.locale = locale
        let time = lastSavedAt.formatted(style)
        let format = String(localized: "Draft saved %@", locale: locale)
        return String(format: format, locale: locale, time)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                toolbarRow
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
                ZStack(alignment: .topLeading) {
                    // Keyed by entry so one editor (and its undo stack) is never reused
                    // across entries.
                    MarkdownTextEditor(
                        text: $text,
                        wrapAction: $wrapAction,
                        command: $command,
                        canUndo: $canUndo,
                        canRedo: $canRedo,
                        usesMonospacedFont: showsMarkdownToolbar,
                        tabMovesFocus: !showsMarkdownToolbar
                    )
                    .id(entryID)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)

                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 200, maxHeight: .infinity)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .onChange(of: text) { _, newValue in
            controller.controller?.noteTextChanged(newValue)
        }
        .onReceive(restoreRequests) { restored in
            command = Self.command(forRestoring: restored)
        }
        .onReceive(ticker) { _ in
            controller.controller?.tick()
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: 6) {
            Button { command = .undo } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!canUndo)
                .help("Undo")
                .accessibilityLabel("Undo")
                .accessibilityIdentifier("notesEditor.undo")
            Button { command = .redo } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!canRedo)
                .help("Redo")
                .accessibilityLabel("Redo")
                .accessibilityIdentifier("notesEditor.redo")

            if showsMarkdownToolbar {
                Divider().frame(height: 16).padding(.horizontal, 4)
                // Only B/I/inline-code are offered: U, H1-H3, HR and fenced code blocks
                // need block-level or raw-HTML rendering that NotesBodyRenderer's plain
                // Text display can't show, and an action with no visible effect would be
                // worse than none.
                markdownButton("bold", "B") { wrapAction = .wrap(prefix: "**", suffix: "**") }
                markdownButton("italic", "I") { wrapAction = .wrap(prefix: "*", suffix: "*") }
                markdownButton("code", "`code`") { wrapAction = .wrap(prefix: "`", suffix: "`") }
            }

            Spacer(minLength: 8)

            if let status = Self.statusText(lastSavedAt: controller.controller?.lastSavedAt) {
                Text(verbatim: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notesEditor.draftStatus")
            }
        }
        .buttonStyle(.borderless)
    }

    private func markdownButton(_ id: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .accessibilityIdentifier("markdownToolbar.\(id)")
    }
}

/// `@ObservedObject` needs a non-optional object; this forwards the optional
/// controller's change notifications so the status label refreshes on autosave.
@MainActor
final class DraftControllerBox: ObservableObject {
    let controller: NoteDraftController?
    private var token: Any?

    init(_ controller: NoteDraftController?) {
        self.controller = controller
        token = controller?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
