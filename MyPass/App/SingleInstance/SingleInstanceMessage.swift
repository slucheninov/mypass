import Foundation

/// The cooperative messages exchanged between MyPass processes through
/// `DistributedNotificationCenter`. The payload travels ONLY in the
/// notification's `object` string: a sandboxed sender's `userInfo` is dropped
/// by the system (measured: a sandboxed poster delivers `object` but
/// `userInfo == nil` to every listener), so nothing may depend on it.
///
/// A message carries process identities, one requester-chosen attempt number
/// and (for `commit`) a deadline: no vault path, no token, no credential. Every
/// identity is re-validated against the kernel by the receiver, so a forged or
/// stale message can at worst make a genuine newer MyPass ask the running one
/// to quit normally, and only inside the commit's own deadline.
///
/// A takeover is two-phase. `probe` and `ready` are harmless discovery; only a
/// `commit` that still carries an unexpired deadline can make anybody quit, and
/// a `withdraw` or a `refuse` ends the attempt for good.
///
///     v2 probe    <pid> <start> <attempt>
///     v2 ready    <pid> <start> <targetPid> <targetStart> <attempt> <owner|launcher|inactive>
///     v2 commit   <pid> <start> <attempt> <deadlineMillis>
///     v2 ack      <pid> <start> <targetPid> <targetStart> <attempt>
///     v2 refuse   <pid> <start> <targetPid> <targetStart> <attempt>
///     v2 withdraw <pid> <start> <attempt>
///
/// `deadlineMillis` is the shared monotonic clock (system uptime) in
/// milliseconds; every process on the machine reads the same clock.
struct SingleInstanceMessage: Equatable {
    /// What the answering process holds, as far as a takeover is concerned.
    enum Role: String, Equatable {
        /// Runs the vault: must be asked to quit (after a `commit`).
        case owner
        /// Another launch still in its own election: yields to a newer commit.
        case launcher
        /// A launch that failed its election and only shows a message: holds
        /// nothing, needs neither a quit nor a wait.
        case inactive
    }

    enum Kind: Equatable {
        /// "I am a newer MyPass and would like to take over; who is there?" Causes no quit.
        case probe(attempt: UInt64)
        /// "I heard your probe; this is what I am."
        case ready(target: ProcessIdentity, attempt: UInt64, role: Role)
        /// "Every live peer answered; please go away before `deadlineMillis`."
        case commit(attempt: UInt64, deadlineMillis: UInt64)
        /// "I accepted your commit and am going away."
        case ack(target: ProcessIdentity, attempt: UInt64)
        /// "I was asked to go away for this attempt and declined (the user cancelled)."
        case refuse(target: ProcessIdentity, attempt: UInt64)
        /// "I give this attempt up; nobody may quit for it any more."
        case withdraw(attempt: UInt64)
    }

    let sender: ProcessIdentity
    let kind: Kind

    private static let version = "v2"
    private static let maximumWireLength = 160

    static func probe(from sender: ProcessIdentity, attempt: UInt64) -> SingleInstanceMessage {
        SingleInstanceMessage(sender: sender, kind: .probe(attempt: attempt))
    }

    static func ready(from sender: ProcessIdentity, to target: ProcessIdentity, attempt: UInt64, role: Role) -> SingleInstanceMessage {
        SingleInstanceMessage(sender: sender, kind: .ready(target: target, attempt: attempt, role: role))
    }

    static func commit(from sender: ProcessIdentity, attempt: UInt64, deadlineMillis: UInt64) -> SingleInstanceMessage {
        SingleInstanceMessage(sender: sender, kind: .commit(attempt: attempt, deadlineMillis: deadlineMillis))
    }

    static func ack(from sender: ProcessIdentity, to target: ProcessIdentity, attempt: UInt64) -> SingleInstanceMessage {
        SingleInstanceMessage(sender: sender, kind: .ack(target: target, attempt: attempt))
    }

    static func refuse(from sender: ProcessIdentity, to target: ProcessIdentity, attempt: UInt64) -> SingleInstanceMessage {
        SingleInstanceMessage(sender: sender, kind: .refuse(target: target, attempt: attempt))
    }

    static func withdraw(from sender: ProcessIdentity, attempt: UInt64) -> SingleInstanceMessage {
        SingleInstanceMessage(sender: sender, kind: .withdraw(attempt: attempt))
    }

    var wire: String {
        let head = "\(Self.version) \(Self.name(of: kind)) \(sender.pid) \(sender.startMicroseconds)"
        switch kind {
        case .probe(let attempt), .withdraw(let attempt):
            return "\(head) \(attempt)"
        case .ready(let target, let attempt, let role):
            return "\(head) \(target.pid) \(target.startMicroseconds) \(attempt) \(role.rawValue)"
        case .commit(let attempt, let deadline):
            return "\(head) \(attempt) \(deadline)"
        case .ack(let target, let attempt), .refuse(let target, let attempt):
            return "\(head) \(target.pid) \(target.startMicroseconds) \(attempt)"
        }
    }

    /// Strict parser: anything that is not exactly one of the shapes above
    /// (wrong version, extra fields, signs, non-digits, absurd length) is `nil`.
    init?(wire: String) {
        guard wire.utf8.count <= Self.maximumWireLength else { return nil }
        let fields = wire.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5, fields[0] == Self.version else { return nil }
        guard let sender = Self.identity(pid: fields[2], start: fields[3]) else { return nil }
        switch fields[1] {
        case "probe", "withdraw":
            guard fields.count == 5, let attempt = Self.number(fields[4]) else { return nil }
            self.init(sender: sender, kind: fields[1] == "probe" ? .probe(attempt: attempt) : .withdraw(attempt: attempt))
        case "commit":
            guard fields.count == 6, let attempt = Self.number(fields[4]), let deadline = Self.number(fields[5]) else { return nil }
            self.init(sender: sender, kind: .commit(attempt: attempt, deadlineMillis: deadline))
        case "ack", "refuse":
            guard fields.count == 7, let target = Self.identity(pid: fields[4], start: fields[5]),
                  let attempt = Self.number(fields[6]) else { return nil }
            self.init(sender: sender, kind: fields[1] == "ack" ? .ack(target: target, attempt: attempt) : .refuse(target: target, attempt: attempt))
        case "ready":
            guard fields.count == 8, let target = Self.identity(pid: fields[4], start: fields[5]),
                  let attempt = Self.number(fields[6]), let role = Role(rawValue: fields[7]) else { return nil }
            self.init(sender: sender, kind: .ready(target: target, attempt: attempt, role: role))
        default:
            return nil
        }
    }

    private init(sender: ProcessIdentity, kind: Kind) {
        self.sender = sender
        self.kind = kind
    }

    private static func name(of kind: Kind) -> String {
        switch kind {
        case .probe: return "probe"
        case .ready: return "ready"
        case .commit: return "commit"
        case .ack: return "ack"
        case .refuse: return "refuse"
        case .withdraw: return "withdraw"
        }
    }

    private static func identity(pid: String, start: String) -> ProcessIdentity? {
        guard isPlainDecimal(pid), isPlainDecimal(start),
              let pidValue = Int32(pid), pidValue > 0,
              let startValue = Int64(start), startValue > 0 else { return nil }
        return ProcessIdentity(pid: pidValue, startMicroseconds: startValue)
    }

    private static func number(_ text: String) -> UInt64? {
        isPlainDecimal(text) ? UInt64(text) : nil
    }

    private static func isPlainDecimal(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }
}
