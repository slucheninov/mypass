import Foundation

enum VaultICloudFolderSelection {
    static func resolveVaultFolder(from pickedFolderURL: URL, fileManager: FileManager = .default) throws -> URL {
        let alreadyHoldsVault = fileManager.fileExists(
            atPath: pickedFolderURL.appendingPathComponent("vault.kdbx").path
        )
        let isMyPassFolder = pickedFolderURL.lastPathComponent.compare("MyPass", options: .caseInsensitive) == .orderedSame
        if alreadyHoldsVault || isMyPassFolder {
            return pickedFolderURL
        }
        let vaultFolderURL = pickedFolderURL.appendingPathComponent("MyPass", isDirectory: true)
        try fileManager.createDirectory(at: vaultFolderURL, withIntermediateDirectories: true)
        return vaultFolderURL
    }
}
