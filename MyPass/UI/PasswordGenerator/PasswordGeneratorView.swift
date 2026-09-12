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

    /// Nil when there is no domain yet, the user chose to ignore it, or no
    /// vendored rule applies -- all three fall back to plain toggle-driven
    /// generation, matching `PasswordGenerator.generate(options:rules:)`'s
    /// own `rules: nil` default.
    private var activeRule: PasswordRules? {
        guard !ignoreActiveRule, !siteDomain.isEmpty else { return nil }
        return PasswordRulesCatalog.rules(forHost: siteDomain)
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

    /// Classes the active rule's own `required:` clauses name outright.
    private var requiredClasses: Set<PasswordRules.CharacterClass> {
        Set(activeRule?.requiredClauses.flatMap { $0 } ?? [])
    }

    private var disallowedClasses: Set<PasswordRules.CharacterClass> {
        guard let activeRule else { return [] }
        let allowed = Set(activeRule.allowedClasses)
        let asciiPrintableAllowed = allowed.contains(.asciiPrintable)
        var disallowed: Set<PasswordRules.CharacterClass> = []
        for characterClass in [PasswordRules.CharacterClass.lower, .upper, .digit, .special] {
            if !allowed.contains(characterClass) && !asciiPrintableAllowed {
                disallowed.insert(characterClass)
            }
        }
        return disallowed
    }

    /// The rule's own explicit `allowed:` set, restricted to the four
    /// toggle-backed classes this view controls -- nil when the rule
    /// places no restriction there at all (no explicit `allowed:`, or it
    /// names `.asciiPrintable`, either of which means "the user's toggles
    /// decide, the rule has no opinion here"), mirroring
    /// `PasswordGenerator.effectivePool`'s own `noExplicitAllowList` /
    /// `asciiPrintableInPlay` handling in MyPassKit.
    private var restrictedAllowedToggleClasses: Set<PasswordRules.CharacterClass>? {
        guard let activeRule else { return nil }
        guard !activeRule.allowedClasses.isEmpty, !activeRule.allowedClasses.contains(.asciiPrintable) else {
            return nil
        }
        let toggleClasses: Set<PasswordRules.CharacterClass> = [.lower, .upper, .digit, .special]
        return toggleClasses.intersection(activeRule.allowedClasses)
    }

    /// Classes locked ON regardless of the user's own toggle: the rule's
    /// `required:` clauses (Decision 4 of the spec -- "a site that
    /// mandates a digit gets one even if the user turned digits off"),
    /// plus one further case `required:` alone doesn't cover.
    ///
    /// Some real vendored rules restrict the character set without
    /// requiring anything. amundi-ee.com's whole rule is "minlength: 6;
    /// maxlength: 6; allowed: digit; max-consecutive: 3" -- a six-digit
    /// PIN. There is no `required:` clause naming digits at all, but
    /// digits are the ONLY character this rule permits. A user whose own
    /// saved generator defaults have digits turned off would sail through
    /// this screen with every toggle looking legitimate, press Generate,
    /// and get an opaque `PasswordGeneratorError.noCharacterClassSelected`
    /// -- a real, technically-correct error (the user did say no digits)
    /// that is still a bad outcome at the exact moment someone is trying
    /// to create a password for a real site.
    ///
    /// The fix applied here: when the rule's `allowed:` set restricted to
    /// these four toggle-backed classes has EXACTLY ONE member, that
    /// member is locked on the same way a `required:` class already is --
    /// visibly, via the same disabled/checked toggle UI, so the conflict
    /// is visible on the screen itself before Generate is ever pressed,
    /// rather than surfacing afterwards as an unexplained error. This is
    /// unconditional on the member's current toggle value (not "only lock
    /// it if the user currently has it off") specifically to avoid a
    /// flip-flop: a condition like "lock it only while nothing allowed is
    /// enabled" would unlock itself the instant `applyActiveRuleToToggles`
    /// switched the toggle on, letting the user immediately turn it back
    /// off and recreate the exact same dead end.
    ///
    /// Deliberately NOT extended to an `allowed:` set with two or more
    /// toggle-backed members (e.g. "allowed: digit, special"): there the
    /// user has a genuine choice of which permitted class to use, and
    /// forcing one of them on regardless of the user's own choice would
    /// take that choice away for a shape this conflict report never
    /// named. A user who turns every option in a multi-member allowed set
    /// off still gets the existing, already-clear "Select at least one
    /// character class" error below.
    private var lockedOnClasses: Set<PasswordRules.CharacterClass> {
        var locked = requiredClasses
        if let restrictedAllowedToggleClasses, restrictedAllowedToggleClasses.count == 1 {
            locked.formUnion(restrictedAllowedToggleClasses)
        }
        return locked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if initialSiteDomain.isEmpty {
                TextField("Site (optional)", text: $siteDomain)
                    .onChange(of: siteDomain) { _, _ in applyActiveRuleToToggles() }
            }

            if let activeRule {
                HStack {
                    Button {
                        showRuleExplanation = true
                    } label: {
                        Label("\(siteDomain) has password requirements", systemImage: "info.circle")
                    }
                    .popover(isPresented: $showRuleExplanation) {
                        Text(PasswordRulesSummary.describe(activeRule, domain: siteDomain))
                            .padding()
                            .frame(width: 260)
                    }
                    Spacer()
                    Toggle("Ignore", isOn: $ignoreActiveRule)
                        .toggleStyle(.checkbox)
                }
                .font(.caption)
            }

            Text("Length: \(Int(length))")
            Slider(value: $length, in: lengthRange, step: 1)

            Toggle("Lowercase", isOn: $includeLowercase)
                .disabled(lockedOnClasses.contains(.lower) || disallowedClasses.contains(.lower))
            Toggle("Uppercase", isOn: $includeUppercase)
                .disabled(lockedOnClasses.contains(.upper) || disallowedClasses.contains(.upper))
            Toggle("Digits", isOn: $includeDigits)
                .disabled(lockedOnClasses.contains(.digit) || disallowedClasses.contains(.digit))
            Toggle("Symbols", isOn: $includeSymbols)
                .disabled(lockedOnClasses.contains(.special) || disallowedClasses.contains(.special))

            Button("Generate", action: generate)
                .buttonStyle(.borderedProminent)

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

    /// Forces locked-on classes on and disallowed classes off whenever the
    /// active rule could have changed (site edited, ignore toggled, or on
    /// first appearance), and clamps the length slider into the rule's
    /// range -- matching Decision 5's "toggles for classes the rule
    /// requires are shown locked on, and toggles for classes the rule's
    /// effective allowed set excludes are shown locked off." An OPTIONAL
    /// class's toggle stays under the user's control; only locked-on/
    /// disallowed classes are pinned. See `lockedOnClasses` for why that
    /// set includes more than just `required:` classes.
    private func applyActiveRuleToToggles() {
        guard activeRule != nil else { return }
        if lockedOnClasses.contains(.lower) { includeLowercase = true }
        if lockedOnClasses.contains(.upper) { includeUppercase = true }
        if lockedOnClasses.contains(.digit) { includeDigits = true }
        if lockedOnClasses.contains(.special) { includeSymbols = true }
        if disallowedClasses.contains(.lower) { includeLowercase = false }
        if disallowedClasses.contains(.upper) { includeUppercase = false }
        if disallowedClasses.contains(.digit) { includeDigits = false }
        if disallowedClasses.contains(.special) { includeSymbols = false }
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
