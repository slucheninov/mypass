import SwiftUI
import AppKit
import MyPassKit

struct PasswordGeneratorView: View {
    /// The host to look up a Password Rules entry for. Passed by the caller
    /// when the generator is opened from an entry's edit screen -- the
    /// entry URL's FULL host, deliberately not reduced to a registrable
    /// domain first. `PasswordRulesCatalog.rules(forHost:)` already walks
    /// upward from the host to the registrable-domain ceiling itself, so
    /// pre-reducing the input threw away every key below that ceiling:
    /// `account.samsung.com`, `key.harvard.edu`, `id.nfpa.org` and
    /// `app.digio.in` all carry rules that their apex domains do not, and
    /// the app found none of them while the extension -- which passes
    /// `location.hostname` unreduced -- found them all. Left empty when
    /// opened standalone, in which case the view's own free-text site
    /// field is the only source of a host.
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

    /// The user's own stored preference, exactly as the four `@State`
    /// toggles and the length slider hold it. This -- never
    /// `effectiveOptions` below -- is what `generate()` persists.
    private var userOptions: PasswordGeneratorOptions {
        PasswordGeneratorOptions(
            length: Int(length),
            includeLowercase: includeLowercase,
            includeUppercase: includeUppercase,
            includeDigits: includeDigits,
            includeSymbols: includeSymbols
        )
    }

    /// `userOptions` with the active rule's forcing applied: what generation
    /// will actually use, and what the controls therefore display.
    ///
    /// An earlier version of this view achieved the same display by writing
    /// the rule's decisions straight into the `@State` toggles from
    /// `onAppear`/`onChange`. That is what made one site's restriction leak
    /// into the user's global defaults through `generate()`'s save (see
    /// `PasswordGeneratorSession`), and it also meant un-checking "Ignore"
    /// could not restore the values the user had before the rule was first
    /// honoured -- they had already been overwritten. Deriving the displayed
    /// state instead of storing it fixes both: the user's own preference is
    /// never touched, so toggling "Ignore" in either direction is now exact.
    private var effectiveOptions: PasswordGeneratorOptions {
        guard let activeRule else { return userOptions }
        return PasswordGenerator.effectiveOptions(for: userOptions, rules: activeRule)
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
    /// `PasswordRulesSummary.pluralName(for:)` and `.joinedWithAnd(_:)` so
    /// this warning and the popover's own "Only ... are permitted."
    /// sentence never disagree about what to call a class or how to list
    /// more than one of them.
    private var allowedClassesConflictMessage: String? {
        guard let conflict = ruleEvaluation?.conflictingWithAllowedClasses, !conflict.isEmpty else {
            return nil
        }
        let names = PasswordRulesSummary.joinedWithAnd(conflict.map(PasswordRulesSummary.pluralName(for:)))
        return String(localized: "\(siteDomain) only allows \(names). Enable one of them to generate a password.", comment: "Password generator warning: first argument is a website domain, second a list of character classes")
    }

    /// The slider's value, clamped into the active rule's range for display
    /// without ever writing that clamp back into `length`. The getter is what
    /// keeps `Slider` from having anything to correct: it only ever sees an
    /// in-range value, so it has no reason to push one back. A drag DOES
    /// write through, because a length the user chose by hand is their own
    /// preference and belongs in the saved defaults like any other.
    private var lengthBinding: Binding<Double> {
        Binding(
            get: { min(max(length, lengthRange.lowerBound), lengthRange.upperBound) },
            set: { length = $0 }
        )
    }

    /// A toggle's displayed value: the user's own, overridden by the rule's
    /// forcing. The setter writes only to the user's `@State`, and a locked
    /// toggle is `.disabled`, so the rule's own decision can never be
    /// mistaken for something the user chose.
    private func toggleBinding(userValue: Binding<Bool>, effectiveValue: Bool) -> Binding<Bool> {
        Binding(
            get: { effectiveValue },
            set: { userValue.wrappedValue = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if initialSiteDomain.isEmpty {
                TextField("Site (optional)", text: $siteDomain)
            }

            if let ruleForDomain {
                HStack {
                    Button {
                        showRuleExplanation = true
                    } label: {
                        Label("\(siteDomain) has password requirements", systemImage: "info.circle")
                    }
                    .popover(isPresented: $showRuleExplanation) {
                        Text(verbatim: PasswordRulesSummary.describe(ruleForDomain, domain: siteDomain))
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
                Text(verbatim: allowedClassesConflictMessage)
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            Text("Length: \(Int(lengthBinding.wrappedValue))")
            Slider(value: lengthBinding, in: lengthRange, step: 1)

            Toggle("Lowercase", isOn: toggleBinding(userValue: $includeLowercase, effectiveValue: effectiveOptions.includeLowercase))
                .disabled(isLocked(.lower))
            Toggle("Uppercase", isOn: toggleBinding(userValue: $includeUppercase, effectiveValue: effectiveOptions.includeUppercase))
                .disabled(isLocked(.upper))
            Toggle("Digits", isOn: toggleBinding(userValue: $includeDigits, effectiveValue: effectiveOptions.includeDigits))
                .disabled(isLocked(.digit))
            Toggle("Symbols", isOn: toggleBinding(userValue: $includeSymbols, effectiveValue: effectiveOptions.includeSymbols))
                .disabled(isLocked(.special))

            Button("Generate", action: generate)
                .buttonStyle(.borderedProminent)
                .disabled(allowedClassesConflictMessage != nil)

            if let errorMessage {
                // Already localized where it is set.
                Text(verbatim: errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if !generatedPassword.isEmpty {
                HStack {
                    Text(verbatim: generatedPassword)
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
    }

    /// Persists the user's own preference and generates honouring the active
    /// rule -- two separate things, kept separate by
    /// `PasswordGeneratorSession.generate(userOptions:rule:defaults:)`. See
    /// that type's doc comment for the defect this shape exists to prevent:
    /// persisting rule-derived values here made one site's character-set
    /// restriction the user's permanent global default, for the app AND for
    /// every password the extension later requested.
    private func generate() {
        do {
            generatedPassword = try PasswordGeneratorSession.generate(userOptions: userOptions, rule: activeRule)
            errorMessage = nil
        } catch PasswordGeneratorError.noCharacterClassSelected {
            errorMessage = String(localized: "Select at least one character class.", comment: "Password generator: inline message")
        } catch PasswordGeneratorError.unsatisfiableRules {
            errorMessage = String(localized: "This site's requirements conflict with your current options.", comment: "Password generator: inline message")
        } catch {
            errorMessage = String(localized: "Failed to generate password.", comment: "Password generator: inline message")
        }
    }
}
