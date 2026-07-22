import SwiftUI
import AppKit
import MyPassKit

struct PasswordGeneratorView: View {
    var onGenerate: (String) -> Void = { _ in }

    @State private var length: Double = 16
    @State private var includeLowercase = true
    @State private var includeUppercase = true
    @State private var includeDigits = true
    @State private var includeSymbols = true
    @State private var generatedPassword = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Длина: \(Int(length))")
            Slider(value: $length, in: 8...64, step: 1)

            Toggle("Строчные буквы", isOn: $includeLowercase)
            Toggle("Прописные буквы", isOn: $includeUppercase)
            Toggle("Цифры", isOn: $includeDigits)
            Toggle("Символы", isOn: $includeSymbols)

            Button("Сгенерировать", action: generate)
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
                    }
                    Button("Использовать") {
                        onGenerate(generatedPassword)
                    }
                }
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func generate() {
        let options = PasswordGeneratorOptions(
            length: Int(length),
            includeLowercase: includeLowercase,
            includeUppercase: includeUppercase,
            includeDigits: includeDigits,
            includeSymbols: includeSymbols
        )
        do {
            generatedPassword = try PasswordGenerator.generate(options: options)
            errorMessage = nil
        } catch PasswordGeneratorError.noCharacterClassSelected {
            errorMessage = "Выберите хотя бы один класс символов."
        } catch {
            errorMessage = "Не удалось сгенерировать пароль."
        }
    }
}
