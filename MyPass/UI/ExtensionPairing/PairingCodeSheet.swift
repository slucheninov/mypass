import SwiftUI

struct PairingCodeSheet: View {
    let code: String
    let onCancel: () -> Void

    private var groupedCode: String {
        guard code.count == 6 else { return code }
        let index = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<index]) \(code[index...])"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect browser extension")
                .font(.title2.weight(.semibold))
            Text(groupedCode)
                .font(.system(size: 40, weight: .medium, design: .monospaced))
            Text("Enter this code in the MyPass browser extension.")
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(32)
        .frame(minWidth: 320)
    }
}
