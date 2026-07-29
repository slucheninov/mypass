import Foundation

/// Discriminates which template an entry was created from. Backed by the
/// `MyPass.EntryType` custom field (see `KdbxEntry.entryType`) — an absent
/// field means `.login`, so every entry in every pre-existing vault is
/// automatically and correctly treated as Login with no migration step.
enum EntryType: String {
    case login = "Login"
    case card = "Card"
    case notes = "Notes"
}
