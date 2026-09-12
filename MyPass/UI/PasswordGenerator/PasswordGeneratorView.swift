import SwiftUI
import AppKit
import MyPassKit

struct PasswordGeneratorView: View {
    /// The domain to look up a Password Rules entry for. Passed by the
    /// caller when the generator is opened from an entry's edit screen,
    /// already reduced to a registrable domain via
    /// `ExtensionEntryMatcher.registrableDomain(from:)` -- see
    /// `EntryEditView.swift`'s call site (Step 7 below). Left empty when
    /// opened standalone, in which case the view's own free-text site
    /// field is the only source of a domain.
    var initialSiteDomain: String = ""
    var onGenerate: (String) -> Void = { _ in }

    @State private var length: Double
    @State private var includeLowercase: Bool
    @State private var includeUppercase: Bool
    @State private var includeDigits: Bool
    @State private var includeSymbols: Bool
    @State private var generatedPassword = ""
    @State private var errorMessage: String?
    @State private var siteDomain: String
    @State private var ignoreActiveRule = false
    @State private var showRuleExplanation = false

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()

    init(initialSiteDomain: String = "", onGenerate: @escaping (String) -> Void = { _ in }) {
        self.initialSiteDomain = initialSiteDomain
        self.onGenerate = onGenerate
        let stored = PasswordGeneratorDefaults.load()
        _length = State(initialValue: Double(stored.length))
        _includeLowercase = State(initialValue: stored.includeLowercase)
        _includeUppercase = State(initialValue: stored.includeUppercase)
        _includeDigits = State(initialValue: stored.includeDigits)
        _includeSymbols = State(initialValue: stored.includeSymbols)
        _siteDomain = State(initialValue: initialSiteDomain)
    }

    /// The rule for the current `siteDomain`, independent of whether the
    /// user has chosen to ignore it. Used only to decide whether the
    /// "Ignore" control and the rule explanation button are shown at all.
    ///
    /// `activeRule` below -- the version that actually governs generation
    /// and toggle locking -- is nil while ignored, and an earlier version
    /// of this view gated the "Ignore" row's own visibility on
    /// `activeRule` instead of this. That meant checking "Ignore" made
    /// `activeRule` go nil, which hid the very control that would let the
    /// user check it back off: the box deleted itself the moment it was
    /// used, with no way back short of dismissing and reopening the sheet
    /// (which resets all the view's state). Gating visibility on this
    /// property instead -- which does not depend on `ignoreActiveRule` --
    /// keeps the control visible, and toggleable both ways, for as long as
    /// a rule exists for the domain at all.
    private var ruleForDomain: PasswordRules? {
        guard !siteDomain.isEmpty else { return nil }
        return PasswordRulesCatalog.rules(forHost: siteDomain)
    }

    /// Nil when there is no domain yet, the user chose to ignore it, or no
    /// vendored rule applies -- all three fall back to plain toggle-driven
    /// generation, matching `PasswordGenerator.generate(options:rules:)`'s
    /// own `rules: nil` default.
    private var activeRule: PasswordRules? {
        guard !ignoreActiveRule else { return nil }
        return ruleForDomain
    }

    private var lengthRange: ClosedRange<Double> {
        let ruleMin = Double(activeRule?.minLength ?? 8)
        let ruleMax = Double(activeRule?.maxLength ?? 64)
        let lowerBound = max(8, ruleMin)
        let upperBound = min(64, ruleMax)
        // A rule whose own min/max already conflicts with MyPass's fixed
        // 8...64 slider bounds would otherwise build an invalid
        // ClosedRange and crash the view; collapsing to a single point is
        // the safe degenerate case. Task 5's conformance test would
        // already be failing before this could happen with any vendored
        // rule.
        return lowerBound <= upperBound ? lowerBound...upperBound : lowerBound...lowerBound
    }

    /// The rule-vs-toggle evaluation for the active rule, or nil when
    /// there is none. All the actual locking/conflict logic lives in
    /// `PasswordRulesToggleEvaluator` -- a plain, testable type -- rather
    /// than in private computed properties on this view, specifically so
    /// it has its own direct test coverage (`PasswordRulesToggleEvaluatorTests`)
    /// instead of only the inspection a SwiftUI view allows.
    private var ruleEvaluation: PasswordRulesToggleEvaluator.Evaluation? {
        guard let activeRule else { return nil }
        let toggles = PasswordRulesToggleEvaluator.Toggles(
            includeLowercase: includeLowercase,
            includeUppercase: includeUppercase,
            includeDigits: includeDigits,
            includeSymbols: includeSymbols
        )
        return PasswordRulesToggleEvaluator.evaluate(rule: activeRule, toggles: toggles)
    }

    private func isLocked(_ characterClass: PasswordRules.CharacterClass) -> Bool {
        guard let ruleEvaluation else { return false }
        return ruleEvaluation.lockedOn.contains(characterClass) || ruleEvaluation.lockedOff.contains(characterClass)
    }

    /// A warning naming the rule's permitted classes whenever the user's
    /// current toggle selection shares nothing with them -- the general
    /// shape of the amundi-ee.com conflict (Task 7's original question)
    /// that locking a single class doesn't cover: a rule permitting two or
    /// more specific classes with no `required:` clause at all, where the
    /// user's current selection still manages to avoid every one of them
    /// (pixnet.cc's "allowed: lower, upper" is a real vendored example).
    /// Shown before Generate is pressed, and worded with
    /// `PasswordRulesSummary.pluralName(for:)` so this warning and the
    /// popover's own "only permits..." sentence never disagree about what
    /// to call a class.
    private var allowedClassesConflictMessage: String? {
        guard let conflict = ruleEvaluation?.conflictingWithAllowedClasses, !conflict.isEmpty else {
            return nil
        }
        let names = conflict.map(PasswordRulesSummary.pluralName(for:)).joined(separator: ", ")
        return "\(siteDomain) only allows \(names). Enable one of them to generate a password."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if initialSiteDomain.isEmpty {
                TextField("Site (optional)", text: $siteDomain)
                    .onChange(of: siteDomain) { _, _ in applyActiveRuleToToggles() }
            }

            if let ruleForDomain {
                HStack {
                    Button {
                        showRuleExplanation = true
                    } label: {
                        Label("\(siteDomain) has password requirements", systemImage: "info.circle")
                    }
                    .popover(isPresented: $showRuleExplanation) {
                        Text(PasswordRulesSummary.describe(ruleForDomain, domain: siteDomain))
                            .padding()
                            .frame(width: 260)
                    }
                    Spacer()
                    Toggle("Ignore", isOn: $ignoreActiveRule)
                        .toggleStyle(.checkbox)
                }
                .font(.caption)
            }

            if let allowedClassesConflictMessage {
                Text(allowedClassesConflictMessage)
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            Text("Length: \(Int(length))")
            Slider(value: $length, in: lengthRange, step: 1)

            Toggle("Lowercase", isOn: $includeLowercase)
                .disabled(isLocked(.lower))
            Toggle("Uppercase", isOn: $includeUppercase)
                .disabled(isLocked(.upper))
            Toggle("Digits", isOn: $includeDigits)
                .disabled(isLocked(.digit))
            Toggle("Symbols", isOn: $includeSymbols)
                .disabled(isLocked(.special))

            Button("Generate", action: generate)
                .buttonStyle(.borderedProminent)
                .disabled(allowedClassesConflictMessage != nil)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if !generatedPassword.isEmpty {
                HStack {
                    Text(generatedPassword)
                        .font(.system(.body, design: .monospaced))
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(generatedPassword, forType: .string)
                        ClipboardAutoClear.schedule(value: generatedPassword, after: ClipboardClearInterval.seconds(), pasteboard: pasteboard, clock: clock)
                    }
                    Button("Use") {
                        onGenerate(generatedPassword)
                    }
                }
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear(perform: applyActiveRuleToToggles)
    }

    /// Forces locked-on classes on and locked-off classes off whenever the
    /// active rule could have changed (site edited, or on first
    /// appearance), and clamps the length slider into the rule's range --
    /// matching Decision 5's "toggles for classes the rule requires are
    /// shown locked on, and toggles for classes the rule's effective
    /// allowed set excludes are shown locked off." An OPTIONAL class's
    /// toggle stays under the user's control; only locked-on/locked-off
    /// classes are pinned. See `PasswordRulesToggleEvaluator.lockedOnClasses(for:)`
    /// for why that set includes more than just `required:` classes.
    ///
    /// Deliberately NOT re-run when `ignoreActiveRule` changes: toggling
    /// "Ignore" off does not restore whatever toggle values were in effect
    /// before the rule was first honoured, only the boundary case this
    /// task's review explicitly left alone -- it never misleads anyone
    /// about the site's policy, since the toggle UI's disabled state
    /// itself already reflects the reactivated rule correctly on every
    /// render, only the values a user changed while ignoring do not snap
    /// back automatically.
    private func applyActiveRuleToToggles() {
        guard let ruleEvaluation else { return }
        if ruleEvaluation.lockedOn.contains(.lower) { includeLowercase = true }
        if ruleEvaluation.lockedOn.contains(.upper) { includeUppercase = true }
        if ruleEvaluation.lockedOn.contains(.digit) { includeDigits = true }
        if ruleEvaluation.lockedOn.contains(.special) { includeSymbols = true }
        if ruleEvaluation.lockedOff.contains(.lower) { includeLowercase = false }
        if ruleEvaluation.lockedOff.contains(.upper) { includeUppercase = false }
        if ruleEvaluation.lockedOff.contains(.digit) { includeDigits = false }
        if ruleEvaluation.lockedOff.contains(.special) { includeSymbols = false }
        length = min(max(length, lengthRange.lowerBound), lengthRange.upperBound)
    }

    private func generate() {
        let options = PasswordGeneratorOptions(
            length: Int(length),
            includeLowercase: includeLowercase,
            includeUppercase: includeUppercase,
            includeDigits: includeDigits,
            includeSymbols: includeSymbols
        )
        PasswordGeneratorDefaults.save(options)
        do {
            generatedPassword = try PasswordGenerator.generate(options: options, rules: activeRule)
            errorMessage = nil
        } catch PasswordGeneratorError.noCharacterClassSelected {
            errorMessage = "Select at least one character class."
        } catch PasswordGeneratorError.unsatisfiableRules {
            errorMessage = "This site's requirements conflict with your current options."
        } catch {
            errorMessage = "Failed to generate password."
        }
    }
}
