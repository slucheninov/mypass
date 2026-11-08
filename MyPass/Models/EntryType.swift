import Foundation

/// Discriminates which template an entry was created from. Backed by the
/// `MyPass.EntryType` custom field (see `KdbxEntry.entryType`) — an absent
/// field means `.login`, so every entry in every pre-existing vault is
/// automatically and correctly treated as Login with no migration step.
enum EntryType: String {
    case login = "Login"
    case address = "Address"
    case card = "Card"
    case notes = "Notes"
    /// An item whose main content is file attachments (the attachments themselves live in
    /// the KDBX binary pool, like on every other kind). A build that predates this case
    /// reads the unknown value as `.login` (see `KdbxEntry.entryType`): the entry shows up
    /// as a title-only login, but nothing is lost, because the attachments stay intact.
    case files = "Files"
}
