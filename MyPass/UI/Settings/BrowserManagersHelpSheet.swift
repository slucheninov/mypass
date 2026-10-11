import AppKit
import SwiftUI

/// Static help deliberately names browser profiles: opening a URL from the native
/// app cannot reliably select the Chrome profile which supplied a pairing report.
struct BrowserManagersHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Use MyPass without other managers").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Follow these steps in each Chrome profile where you use MyPass. Turning off a manager does not delete its saved passwords or passkeys.")
                    helpSection("Google Password Manager", steps: [
                        "Open Chrome’s menu → Passwords and autofill → Google Password Manager → Settings, or paste the address below into that profile’s address bar.",
                        "Turn off offers to save passwords and passkeys, automatic passkey creation if shown, and automatic sign-in.",
                        "These controls do not remove saved credentials or guarantee that every autofill and passkey option is off. Review any remaining provider choices when signing in."
                    ], source: "https://support.google.com/chrome/answer/6197437?hl=en")
                    copyAddress("chrome://password-manager/settings")
                    helpSection("iCloud Passwords", steps: [
                        "Open Chrome’s Extensions page in the profile you use with MyPass.",
                        "Find iCloud Passwords and switch the extension off. Leave MyPass enabled.",
                        "This disables the Chrome extension only. macOS password and passkey providers are separate; the browser check cannot confirm their settings."
                    ], source: "https://support.google.com/chrome/answer/2664769?hl=en")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Optional: macOS AutoFill").font(.headline)
                        Text("For system-wide changes on current macOS, open System Settings → General → AutoFill & Passwords and review AutoFill Passwords and Passkeys. On macOS Sonoma, use System Settings → Passwords → Password Options. This affects other apps too; it is separate from disabling the Chrome extension.")
                        Link("Apple AutoFill help", destination: URL(string: "https://support.apple.com/en-us/120758")!)
                    }
                    helpSection("1Password", steps: [
                        "To use only MyPass in this profile, open Chrome’s Extensions page and switch 1Password off.",
                        "If you keep 1Password enabled, its Settings → Autofill & save offers separate controls for passkey sign-in and passkey saving. Turning those off does not turn off all password features."
                    ], source: "https://support.1password.com/save-use-passkeys/")
                    copyAddress("chrome://extensions")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Check the result").font(.headline)
                        Text("Reopen the MyPass extension and choose Check this browser. Allow the read-only check when Chrome asks. Return to MyPass Settings → Browser to see the report and its receipt time.")
                        Text("Then retry the website’s passkey action. Confirm in MyPass and wait for the website to finish. A saved key in MyPass alone does not confirm that the website completed registration.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 590, height: 570)
    }

    private func helpSection(_ title: String, steps: [String], source: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)")
            }
            Link("Official help", destination: URL(string: source)!)
        }
    }

    private func copyAddress(_ address: String) -> some View {
        HStack {
            Text(address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button("Copy address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            }
        }
    }
}
