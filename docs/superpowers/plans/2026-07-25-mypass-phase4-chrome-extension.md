# MyPass Phase 4 (Chrome): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Phase 4 - Chrome extension (Manifest V3) with autofill of saved logins and an offer to save a new login, communicating with MyPass.app through a native helper process `ChromeHost` and loopback TCP + Keychain token, according to `docs/superpowers/specs/2026-07-25-mypass-phase4-chrome-extension-design.md `.

**Architecture:** New leaf package `Packages/ExtensionBridgeKit` contains a native-messaging framing codec, common Codable request/response types and Keychain port+token storage (reused by both `MyPass.app`, and `ChromeHost`). Inside `MyPass`(application) - module `ExtensionBridge`: `LoopbackServer`(Network.framework, TCP on `127.0.0.1:<random>`), `ExtensionBridgeService`(talks to `VaultSession`), `ExtensionEntryMatcher`(domain matching).`ChromeHost`— a separate unsandboxed executable target that relays native-messaging stdio ↔ TCP.`ChromeExtension/`- pure MV3 JS (without a build step):`background.js`, `content.js`, `popup.html `/` popup.js `.

**Tech Stack:** Swift 5.10, SwiftUI/AppKit (macOS 14+), Network.framework, Security.framework (Keychain), Swift Package Manager, XcodeGen (project.yml), Chrome Manifest V3 (JavaScript, no build step — plain JS, no TypeScript/bundler, in the spirit of minimal project dependencies), XCTest.

## Global Constraints

- MyPass.app remains sandboxed (`com.apple.security.app-sandbox = true`), without App Group.
- IPC transport - loopback TCP (`127.0.0.1`, random free port) + one-time token in Keychain; NOT Mach XPC, NOT Unix domain socket in the App Group (both alternatives were rejected by the design spec).
- NO autofill when the page is simply loaded - filling out form fields only by an explicit user click in the popup.
- `getCredentials` NEVER returns password - only `[{id, title, username}]`; the password is given only in response to a specific `fillCredential` by id.
- `fillCredential` re-checks the correspondence of the entry domain and URL - as on the side `ExtensionBridgeService`(step 7 flow), and on the side `content.js` before filling.
- Native messaging host manifest (`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.mypass.chromehost.json`) must have `allowed_origins`, limited to a specific extension ID.
- Swift tools version 5.10, platform floor macOS 14.0 (same as `Packages/MyPassKit/Package.swift`, `Packages/SyncKit/Package.swift`, `project.yml`).
- No placeholders in the code - each step below contains complete, real code.
- Outside the scope of this phase (NOT implemented): Safari App Extension and general WebExtension layer (Phase 4b), badge indicator of the number of matches, access to the password generator from the extension, TOTP copy-to-clipboard without filling out the form.

---

### Task 1: `ExtensionBridgeKit` package scaffold + native messaging framing codec

**Files:**
- Create: `Packages/ExtensionBridgeKit/Package.swift`
- Create: `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/NativeMessagingCodec.swift`
- Modify: `project.yml`(add package `ExtensionBridgeKit` V `packages:` and target dependency `MyPass` from it)
- Test: `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/NativeMessagingCodecTests.swift`

**Interfaces:**
- Consumes: nothing - this is the foundation of Phase 4.
- Produces:
```swift
public enum NativeMessagingCodec {
    public static func encode(_ payload: Data) -> Data
}

public final class NativeMessagingFrameReader {
    public init()
    public func feed(_ data: Data) -> [Data]
}
```
Used by all subsequent tasks: Task 2 (encodes/decodes messages), Task 6 (`LoopbackServer`), Task 8/9 (`ChromeHost`).

- [ ] **Step 1: Write the failing test**

Create `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/NativeMessagingCodecTests.swift`:

```swift
import XCTest
@testable import ExtensionBridgeKit

final class NativeMessagingCodecTests: XCTestCase {
    func testEncodePrependsFourByteLittleEndianLength() {
        let payload = Data("hi".utf8)
        let framed = NativeMessagingCodec.encode(payload)
        XCTAssertEqual(framed.count, 4 + payload.count)
        XCTAssertEqual(Array(framed.prefix(4)), [2, 0, 0, 0])
        XCTAssertEqual(framed.suffix(from: 4), payload)
    }

    func testFeedReturnsDecodedFrameWhenAllBytesArrivedAtOnce() {
        let payload = Data("hello".utf8)
        let framed = NativeMessagingCodec.encode(payload)
        let reader = NativeMessagingFrameReader()
        let frames = reader.feed(framed)
        XCTAssertEqual(frames, [payload])
    }

    func testFeedAccumulatesAcrossMultiplePartialCalls() {
        let payload = Data("partial-frame-payload".utf8)
        let framed = NativeMessagingCodec.encode(payload)
        let reader = NativeMessagingFrameReader()

        let firstChunk = framed.prefix(3)
        let secondChunk = framed.subdata(in: 3..<10)
        let thirdChunk = framed.subdata(in: 10..<framed.count)

        XCTAssertEqual(reader.feed(Data(firstChunk)), [])
        XCTAssertEqual(reader.feed(secondChunk), [])
        XCTAssertEqual(reader.feed(thirdChunk), [payload])
    }

    func testFeedReturnsMultipleFramesFromOneCall() {
        let first = Data("frame-one".utf8)
        let second = Data("frame-two".utf8)
        var combined = NativeMessagingCodec.encode(first)
        combined.append(NativeMessagingCodec.encode(second))

        let reader = NativeMessagingFrameReader()
        let frames = reader.feed(combined)
        XCTAssertEqual(frames, [first, second])
    }

    func testEmptyPayloadRoundTrips() {
        let payload = Data()
        let framed = NativeMessagingCodec.encode(payload)
        let reader = NativeMessagingFrameReader()
        XCTAssertEqual(reader.feed(framed), [payload])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ExtensionBridgeKit && swift test --filter NativeMessagingCodecTests`
Expected: FAIL — package/module `ExtensionBridgeKit` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `Packages/ExtensionBridgeKit/Package.swift`:

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ExtensionBridgeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExtensionBridgeKit", targets: ["ExtensionBridgeKit"])
    ],
    dependencies: [],
    targets: [
        .target(name: "ExtensionBridgeKit", dependencies: []),
        .testTarget(name: "ExtensionBridgeKitTests", dependencies: ["ExtensionBridgeKit"])
    ]
)
```

Create `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/NativeMessagingCodec.swift`:

```swift
import Foundation

/// 4-byte little-endian length prefix + raw JSON payload, matching Chrome's
/// native messaging framing (https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).
/// Shared by both hops: ChromeHost <-> Chrome over stdio, and ChromeHost <-> MyPass.app over TCP.
public enum NativeMessagingCodec {
    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }
}

/// Incremental decoder: accumulates bytes fed via `feed(_:)` and returns zero or
/// more complete payloads, tolerating partial reads and multiple frames per call —
/// both are normal on a real stdio/TCP stream.
public final class NativeMessagingFrameReader {
    private var buffer = Data()

    public init() {}

    public func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while buffer.count >= 4 {
            let lengthBytes = [UInt8](buffer.prefix(4))
            let length = UInt32(lengthBytes[0])
                | (UInt32(lengthBytes[1]) << 8)
                | (UInt32(lengthBytes[2]) << 16)
                | (UInt32(lengthBytes[3]) << 24)
            let frameLength = Int(length)

            guard buffer.count >= 4 + frameLength else { break }

            let frame = buffer.subdata(in: 4..<(4 + frameLength))
            frames.append(frame)
            buffer.removeSubrange(0..<(4 + frameLength))
        }

        return frames
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/ExtensionBridgeKit && swift test --filter NativeMessagingCodecTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Register the package and wire it into `MyPass`**

Modify `project.yml` — add `ExtensionBridgeKit` to the top-level `packages:` map and to the `MyPass` target's `dependencies:`:

```yaml
packages:
  MyPassKit:
    path: Packages/MyPassKit
  SyncKit:
    path: Packages/SyncKit
  ExtensionBridgeKit:
    path: Packages/ExtensionBridgeKit
targets:
  MyPass:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: MyPass
    dependencies:
      - package: MyPassKit
      - package: SyncKit
      - package: ExtensionBridgeKit
```

(`ChromeHost` target does not exist yet — it is created in Task 8, and will also list `ExtensionBridgeKit` there.)

Run: `xcodegen generate`
Expected: regenerates `MyPass.xcodeproj` without errors; `ExtensionBridgeKit` now resolvable from the `MyPass` target.

- [ ] **Step 6: Commit**

```bash
git add Packages/ExtensionBridgeKit/Package.swift Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/NativeMessagingCodec.swift Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/NativeMessagingCodecTests.swift project.yml MyPass.xcodeproj
git commit -m "Phase 4, Task 1: ExtensionBridgeKit package scaffold + native messaging framing codec"
```

---

### Task 2: `ExtensionBridgeKit` message types

**Files:**
- Create: `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`
- Test: `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift`

**Interfaces:**
- Consumes: nothing new from Task 1 (parallel type definitions in the same package).
- Produces (wire format documented and pinned by the tests in this task — every request carries a `token: String` sibling field alongside its discriminator, per the token-validation design used by `LoopbackServer` in Task 6):
```swift
public enum ExtensionBridgeRequest: Equatable, Codable {
    case getCredentials(token: String, url: String)
    case fillCredential(token: String, id: String, url: String)
    case proposeSaveLogin(token: String, url: String, username: String, password: String)
}

public struct ExtensionCredentialSummary: Codable, Equatable {
    public let id: String
    public let title: String
    public let username: String
    public init(id: String, title: String, username: String)
}

public enum ExtensionBridgeResponse: Equatable, Codable {
    case locked
    case credentialList([ExtensionCredentialSummary])
    case credential(username: String, password: String, totp: String?)
    case saveProposalAccepted
    case error(String)
}
```
Consumed by Task 3 (token store types are separate but live in the same package), Task 5 (`ExtensionBridgeService.handle(_:) -> ExtensionBridgeResponse`), Task 6 (`LoopbackServer` decodes `ExtensionBridgeRequest` / encodes `ExtensionBridgeResponse`), Task 9 (`ChromeHost` relay reads the `token` field), Task 10-12 (JS side mirrors this exact JSON shape).

- [ ] **Step 1: Write the failing test**

Create `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift`:

```swift
import XCTest
@testable import ExtensionBridgeKit

final class ExtensionBridgeMessagesTests: XCTestCase {
    private func jsonObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Requests

    func testGetCredentialsRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.getCredentials(token: "tok-1", url: "https://example.com")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "getCredentials")
        XCTAssertEqual(object["token"] as? String, "tok-1")
        XCTAssertEqual(object["url"] as? String, "https://example.com")
    }

    func testFillCredentialRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.fillCredential(token: "tok-2", id: "entry-1", url: "https://example.com/login")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "fillCredential")
        XCTAssertEqual(object["token"] as? String, "tok-2")
        XCTAssertEqual(object["id"] as? String, "entry-1")
        XCTAssertEqual(object["url"] as? String, "https://example.com/login")
    }

    func testProposeSaveLoginRoundTripsAndHasExpectedShape() throws {
        let request = ExtensionBridgeRequest.proposeSaveLogin(
            token: "tok-3", url: "https://example.com/signup", username: "alice", password: "s3cret"
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "proposeSaveLogin")
        XCTAssertEqual(object["token"] as? String, "tok-3")
        XCTAssertEqual(object["username"] as? String, "alice")
        XCTAssertEqual(object["password"] as? String, "s3cret")
    }

    func testDecodingUnknownRequestTypeThrows() {
        let data = Data("{\"type\":\"bogus\",\"token\":\"t\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data))
    }

    // MARK: - Responses

    func testLockedRoundTripsAndHasExpectedShape() throws {
        let response = ExtensionBridgeResponse.locked
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertEqual(try jsonObject(from: data)["type"] as? String, "locked")
    }

    func testCredentialListRoundTripsAndNeverIncludesAPasswordKey() throws {
        let response = ExtensionBridgeResponse.credentialList([
            ExtensionCredentialSummary(id: "1", title: "Example", username: "alice")
        ])
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "credentialList")
        let credentials = try XCTUnwrap(object["credentials"] as? [[String: Any]])
        XCTAssertEqual(credentials.count, 1)
        XCTAssertEqual(credentials[0]["id"] as? String, "1")
        XCTAssertEqual(credentials[0]["title"] as? String, "Example")
        XCTAssertEqual(credentials[0]["username"] as? String, "alice")
        XCTAssertNil(credentials[0]["password"], "credentialList must never carry a password field")
    }

    func testCredentialRoundTripsWithTotp() throws {
        let response = ExtensionBridgeResponse.credential(username: "alice", password: "s3cret", totp: "JBSWY3DP")
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "credential")
        XCTAssertEqual(object["username"] as? String, "alice")
        XCTAssertEqual(object["password"] as? String, "s3cret")
        XCTAssertEqual(object["totp"] as? String, "JBSWY3DP")
    }

    func testCredentialRoundTripsWithoutTotp() throws {
        let response = ExtensionBridgeResponse.credential(username: "alice", password: "s3cret", totp: nil)
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertNil(try jsonObject(from: data)["totp"])
    }

    func testSaveProposalAcceptedRoundTrips() throws {
        let response = ExtensionBridgeResponse.saveProposalAccepted
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)
        XCTAssertEqual(try jsonObject(from: data)["type"] as? String, "saveProposalAccepted")
    }

    func testErrorRoundTripsAndHasExpectedShape() throws {
        let response = ExtensionBridgeResponse.error("invalid token")
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeResponse.self, from: data), response)

        let object = try jsonObject(from: data)
        XCTAssertEqual(object["type"] as? String, "error")
        XCTAssertEqual(object["message"] as? String, "invalid token")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ExtensionBridgeKit && swift test --filter ExtensionBridgeMessagesTests`
Expected: FAIL — `ExtensionBridgeRequest `/`ExtensionBridgeResponse `/`ExtensionCredentialSummary` do not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift`:

```swift
import Foundation

// MARK: - Requests

public enum ExtensionBridgeRequest: Equatable {
    case getCredentials(token: String, url: String)
    case fillCredential(token: String, id: String, url: String)
    case proposeSaveLogin(token: String, url: String, username: String, password: String)
}

extension ExtensionBridgeRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, token, url, id, username, password
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let token = try container.decode(String.self, forKey: .token)
        switch type {
        case "getCredentials":
            let url = try container.decode(String.self, forKey: .url)
            self = .getCredentials(token: token, url: url)
        case "fillCredential":
            let id = try container.decode(String.self, forKey: .id)
            let url = try container.decode(String.self, forKey: .url)
            self = .fillCredential(token: token, id: id, url: url)
        case "proposeSaveLogin":
            let url = try container.decode(String.self, forKey: .url)
            let username = try container.decode(String.self, forKey: .username)
            let password = try container.decode(String.self, forKey: .password)
            self = .proposeSaveLogin(token: token, url: url, username: username, password: password)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown ExtensionBridgeRequest type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .getCredentials(let token, let url):
            try container.encode("getCredentials", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(url, forKey: .url)
        case .fillCredential(let token, let id, let url):
            try container.encode("fillCredential", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(id, forKey: .id)
            try container.encode(url, forKey: .url)
        case .proposeSaveLogin(let token, let url, let username, let password):
            try container.encode("proposeSaveLogin", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(url, forKey: .url)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
        }
    }
}

// MARK: - Shared value types

public struct ExtensionCredentialSummary: Codable, Equatable {
    public let id: String
    public let title: String
    public let username: String

    public init(id: String, title: String, username: String) {
        self.id = id
        self.title = title
        self.username = username
    }
}

// MARK: - Responses

public enum ExtensionBridgeResponse: Equatable {
    case locked
    case credentialList([ExtensionCredentialSummary])
    case credential(username: String, password: String, totp: String?)
    case saveProposalAccepted
    case error(String)
}

extension ExtensionBridgeResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, credentials, username, password, totp, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "locked":
            self = .locked
        case "credentialList":
            let credentials = try container.decode([ExtensionCredentialSummary].self, forKey: .credentials)
            self = .credentialList(credentials)
        case "credential":
            let username = try container.decode(String.self, forKey: .username)
            let password = try container.decode(String.self, forKey: .password)
            let totp = try container.decodeIfPresent(String.self, forKey: .totp)
            self = .credential(username: username, password: password, totp: totp)
        case "saveProposalAccepted":
            self = .saveProposalAccepted
        case "error":
            let message = try container.decode(String.self, forKey: .message)
            self = .error(message)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown ExtensionBridgeResponse type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .locked:
            try container.encode("locked", forKey: .type)
        case .credentialList(let credentials):
            try container.encode("credentialList", forKey: .type)
            try container.encode(credentials, forKey: .credentials)
        case .credential(let username, let password, let totp):
            try container.encode("credential", forKey: .type)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
            try container.encodeIfPresent(totp, forKey: .totp)
        case .saveProposalAccepted:
            try container.encode("saveProposalAccepted", forKey: .type)
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/ExtensionBridgeKit && swift test --filter ExtensionBridgeMessagesTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift
git commit -m "Phase 4, Task 2: ExtensionBridgeKit Codable request/response message types"
```

---

### Task 3: `ExtensionBridgeTokenStore`

**Files:**
- Create: `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeTokenStore.swift`
- Test: `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeTokenStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
```swift
public struct ExtensionBridgeEndpoint: Codable, Equatable {
    public let port: UInt16
    public let token: String
    public init(port: UInt16, token: String)
}

public protocol ExtensionBridgeTokenStoring {
    func save(_ endpoint: ExtensionBridgeEndpoint) throws
    func load() throws -> ExtensionBridgeEndpoint?
    func clear() throws
}

public final class InMemoryExtensionBridgeTokenStore: ExtensionBridgeTokenStoring {
    public init()
}

public final class ExtensionBridgeTokenStore: ExtensionBridgeTokenStoring {
    public init()
    public static func generateToken() -> String
}
```
Consumed by Task 6 (`LoopbackServer` persists the live endpoint), Task 8/9 (`ChromeHost` reads it cross-process). CRITICAL: `ExtensionBridgeTokenStore` explicitly sets `kSecAttrAccessGroup: "com.mypass.app.keychain"` on every query, unlike `CredentialKeychainStore` in `SyncKit` (which relies on the app's default access group because it's only ever read from within `MyPass.app`) — this store must be readable by `ChromeHost`, a separate executable outside the app bundle.

- [ ] **Step 1: Write the failing test**

Create `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeTokenStoreTests.swift`:

```swift
import XCTest
@testable import ExtensionBridgeKit

final class ExtensionBridgeTokenStoreTests: XCTestCase {

    // MARK: - InMemory (always run)

    func testInMemoryStoreStartsEmpty() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        XCTAssertNil(try store.load())
    }

    func testInMemoryStoreSavesAndLoads() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        let endpoint = ExtensionBridgeEndpoint(port: 54321, token: "abc123")
        try store.save(endpoint)
        XCTAssertEqual(try store.load(), endpoint)
    }

    func testInMemoryStoreClearRemovesEndpoint() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        try store.save(ExtensionBridgeEndpoint(port: 1, token: "x"))
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testInMemoryStoreOverwritesPreviousEndpoint() throws {
        let store = InMemoryExtensionBridgeTokenStore()
        try store.save(ExtensionBridgeEndpoint(port: 1, token: "first"))
        try store.save(ExtensionBridgeEndpoint(port: 2, token: "second"))
        XCTAssertEqual(try store.load(), ExtensionBridgeEndpoint(port: 2, token: "second"))
    }

    // MARK: - generateToken (pure, always run)

    func testGenerateTokenProducesNonEmptyBase64() {
        let token = ExtensionBridgeTokenStore.generateToken()
        XCTAssertFalse(token.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: token), "token must be valid base64")
    }

    func testGenerateTokenProducesDistinctValues() {
        let first = ExtensionBridgeTokenStore.generateToken()
        let second = ExtensionBridgeTokenStore.generateToken()
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Real Keychain (gated)

    private func requireKeychainTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYPASS_KEYCHAIN_TESTS"] == "1",
            "set MYPASS_KEYCHAIN_TESTS=1 to run tests against the real Keychain"
        )
    }

    func testRealKeychainStoreSavesLoadsAndClears() throws {
        try requireKeychainTestsEnabled()
        let store = ExtensionBridgeTokenStore()
        try store.clear()
        XCTAssertNil(try store.load())

        let endpoint = ExtensionBridgeEndpoint(port: 49200, token: ExtensionBridgeTokenStore.generateToken())
        try store.save(endpoint)
        XCTAssertEqual(try store.load(), endpoint)

        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testRealKeychainStoreSaveOverwritesExistingEndpoint() throws {
        try requireKeychainTestsEnabled()
        let store = ExtensionBridgeTokenStore()
        try store.save(ExtensionBridgeEndpoint(port: 1, token: "first"))
        try store.save(ExtensionBridgeEndpoint(port: 2, token: "second"))
        XCTAssertEqual(try store.load(), ExtensionBridgeEndpoint(port: 2, token: "second"))
        try store.clear()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ExtensionBridgeKit && swift test --filter ExtensionBridgeTokenStoreTests`
Expected: FAIL — `ExtensionBridgeEndpoint `/`ExtensionBridgeTokenStoring `/stores do not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeTokenStore.swift`:

```swift
import Foundation
import Security

public struct ExtensionBridgeEndpoint: Codable, Equatable {
    public let port: UInt16
    public let token: String

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }
}

public protocol ExtensionBridgeTokenStoring {
    func save(_ endpoint: ExtensionBridgeEndpoint) throws
    func load() throws -> ExtensionBridgeEndpoint?
    func clear() throws
}

public enum ExtensionBridgeTokenStoreError: Error {
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case decodingFailed
}

public final class InMemoryExtensionBridgeTokenStore: ExtensionBridgeTokenStoring {
    private var stored: ExtensionBridgeEndpoint?

    public init() {}

    public func save(_ endpoint: ExtensionBridgeEndpoint) throws {
        stored = endpoint
    }

    public func load() throws -> ExtensionBridgeEndpoint? {
        stored
    }

    public func clear() throws {
        stored = nil
    }
}

/// Cross-process Keychain store for the live loopback endpoint. Unlike
/// `CredentialKeychainStore` (SyncKit), this store is read by `ChromeHost` — a
/// separate executable outside the MyPass.app bundle with a different code
/// signature — so it MUST use an explicit shared access group rather than the
/// app's implicit default one. `ChromeHost.entitlements` (Task 8) must declare
/// membership in the same access group, and both targets must be signed with
/// the same Apple Developer Team ID for cross-process Keychain access to work;
/// that signing requirement cannot be verified by an automated test.
public final class ExtensionBridgeTokenStore: ExtensionBridgeTokenStoring {
    private let service = "com.mypass.extensionbridge.endpoint"
    private let account = "loopback"
    private let accessGroup = "com.mypass.app.keychain"

    public init() {}

    public func save(_ endpoint: ExtensionBridgeEndpoint) throws {
        guard let data = try? JSONEncoder().encode(endpoint) else {
            throw ExtensionBridgeTokenStoreError.encodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ExtensionBridgeTokenStoreError.unexpectedStatus(status)
        }
    }

    public func load() throws -> ExtensionBridgeEndpoint? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ExtensionBridgeTokenStoreError.unexpectedStatus(status)
        }
        guard let endpoint = try? JSONDecoder().decode(ExtensionBridgeEndpoint.self, from: data) else {
            throw ExtensionBridgeTokenStoreError.decodingFailed
        }
        return endpoint
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExtensionBridgeTokenStoreError.unexpectedStatus(status)
        }
    }

    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/ExtensionBridgeKit && swift test --filter ExtensionBridgeTokenStoreTests`
Expected: PASS (6 always-run tests; 2 Keychain tests SKIP without `MYPASS_KEYCHAIN_TESTS=1`).

Optionally verify the gated tests too: `MYPASS_KEYCHAIN_TESTS=1 swift test --filter ExtensionBridgeTokenStoreTests` (requires a local Keychain and may prompt for access — matches the existing `CredentialKeychainStoreTests` convention).

- [ ] **Step 5: Commit**

```bash
git add Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeTokenStore.swift Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeTokenStoreTests.swift
git commit -m "Phase 4, Task 3: ExtensionBridgeTokenStore (cross-process Keychain access group)"
```

---

### Task 4: `ExtensionEntryMatcher` (domain matching)

**Files:**
- Create: `MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift`
- Test: `MyPassTests/ExtensionEntryMatcherTests.swift`

**Interfaces:**
- Consumes: `KdbxGroup `/`KdbxEntry` from `MyPassKit`; `entry.url `/` entry.title `/` entry.login` internal convenience accessors (`MyPass/Models/KdbxEntry+Convenience.swift`); `EntrySearch.allEntries(in:)` (`MyPass/UI/EntryList/EntrySearch.swift`), same target so no import needed.
- Produces:
```swift
enum ExtensionEntryMatcher {
    static func registrableDomain(from urlString: String) -> String?
    static func matchingEntries(in group: KdbxGroup, forURL urlString: String) -> [KdbxEntry]
}
```
Consumed by Task 5 (`ExtensionBridgeService.handle(_:)`).

- [ ] **Step 1: Write the failing test**

Create `MyPassTests/ExtensionEntryMatcherTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class ExtensionEntryMatcherTests: XCTestCase {
    private func makeEntry(url: String, title: String = "Entry") -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry.title = title
        entry.url = url
        return entry
    }

    private func makeGroup(entries: [KdbxEntry]) -> KdbxGroup {
        let now = Date()
        return KdbxGroup(
            uuid: UUID(),
            name: "Root",
            iconID: 0,
            creationTime: now,
            lastModificationTime: now,
            locationChanged: now,
            entries: entries,
            subgroups: []
        )
    }

    // MARK: - registrableDomain

    func testRegistrableDomainStripsOneSubdomainLabel() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "https://login.example.com/path"), "example.com")
    }

    func testRegistrableDomainOfBareApexDomainIsUnchanged() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "https://example.com"), "example.com")
    }

    func testRegistrableDomainHandlesUrlWithoutScheme() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "example.com/login"), "example.com")
    }

    func testRegistrableDomainIsCaseInsensitive() {
        XCTAssertEqual(ExtensionEntryMatcher.registrableDomain(from: "https://Example.COM"), "example.com")
    }

    func testRegistrableDomainOfEmptyStringIsNil() {
        XCTAssertNil(ExtensionEntryMatcher.registrableDomain(from: ""))
    }

    // MARK: - matchingEntries

    func testMatchingEntriesIncludesSubdomainMatch() {
        let entry = makeEntry(url: "https://example.com/login")
        let group = makeGroup(entries: [entry])
        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://login.example.com/signin")
        XCTAssertEqual(matches.map(\.uuid), [entry.uuid])
    }

    func testMatchingEntriesExcludesNonMatchingDomain() {
        let entry = makeEntry(url: "https://example.com")
        let group = makeGroup(entries: [entry])
        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://other.com")
        XCTAssertTrue(matches.isEmpty)
    }

    func testMatchingEntriesExcludesEntriesWithEmptyUrl() {
        let entry = makeEntry(url: "")
        let group = makeGroup(entries: [entry])
        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://example.com")
        XCTAssertTrue(matches.isEmpty)
    }

    func testMatchingEntriesIsCaseInsensitive() {
        let entry = makeEntry(url: "https://Example.com")
        let group = makeGroup(entries: [entry])
        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://EXAMPLE.COM")
        XCTAssertEqual(matches.map(\.uuid), [entry.uuid])
    }

    func testMatchingEntriesWalksSubgroups() {
        let entry = makeEntry(url: "https://example.com")
        let now = Date()
        let subgroup = KdbxGroup(
            uuid: UUID(), name: "Sub", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: [entry], subgroups: []
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: now, lastModificationTime: now, locationChanged: now,
            entries: [], subgroups: [subgroup]
        )
        let matches = ExtensionEntryMatcher.matchingEntries(in: root, forURL: "https://example.com")
        XCTAssertEqual(matches.map(\.uuid), [entry.uuid])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionEntryMatcherTests`
Expected: FAIL — `ExtensionEntryMatcher` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift`:

```swift
import Foundation
import MyPassKit

enum ExtensionEntryMatcher {
    /// Naive "last two DNS labels" heuristic — NOT a real public-suffix-list
    /// lookup. It misidentifies multi-part suffixes such as "example.co.uk"
    /// (collapses to "co.uk" instead of "example.co.uk"). Accepted as a known
    /// limitation for the Phase 4 MVP; revisit with a PSL library before
    /// widening scope beyond simple .com/.org/.net-style domains.
    static func registrableDomain(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var host = URL(string: trimmed)?.host
        if host == nil {
            host = URL(string: "https://" + trimmed)?.host
        }
        guard let resolvedHost = host?.lowercased(), !resolvedHost.isEmpty else { return nil }

        let labels = resolvedHost.split(separator: ".")
        guard labels.count >= 2 else { return resolvedHost }
        return labels.suffix(2).joined(separator: ".")
    }

    static func matchingEntries(in group: KdbxGroup, forURL urlString: String) -> [KdbxEntry] {
        guard let targetDomain = registrableDomain(from: urlString) else { return [] }
        return EntrySearch.allEntries(in: group).filter { entry in
            guard !entry.url.isEmpty, let entryDomain = registrableDomain(from: entry.url) else {
                return false
            }
            return entryDomain == targetDomain
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionEntryMatcherTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift MyPassTests/ExtensionEntryMatcherTests.swift
git commit -m "Phase 4, Task 4: ExtensionEntryMatcher domain matching (registrable-domain heuristic)"
```

---

### Task 5: `ExtensionBridgeService`

**Files:**
- Create: `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift`
- Test: `MyPassTests/ExtensionBridgeServiceTests.swift`

**Interfaces:**
- Consumes: `VaultSession` (`currentDatabase`, `mutate(_:)`), `ExtensionEntryMatcher.matchingEntries(in:forURL:)` (Task 4), `ExtensionBridgeRequest `/`ExtensionBridgeResponse `/`ExtensionCredentialSummary` (Task 2), `entry.title `/`.login `/`.password `/`.totpSecretBase32`.
- Produces:
```swift
final class ExtensionBridgeService {
    weak var vaultSession: VaultSession?
    var onSaveProposal: ((_ url: String, _ username: String, _ password: String) -> Void)?
    init(vaultSession: VaultSession)
    func handle(_ request: ExtensionBridgeRequest) -> ExtensionBridgeResponse
}
```
Consumed by Task 6 (`LoopbackServer`'s injected handler closure), Task 7 (wired in `MyPassApp.init()`). `onSaveProposal` itself is set to a real closure (not left as a bare extension point) in Task 13, which activates the main window and presents a pre-filled create-entry form.

- [ ] **Step 1: Write the failing test**

Create `MyPassTests/ExtensionBridgeServiceTests.swift`:

```swift
import XCTest
import MyPassKit
import ExtensionBridgeKit
@testable import MyPass

final class ExtensionBridgeServiceTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!
    var session: VaultSession!
    var service: ExtensionBridgeService!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassExtensionBridgeServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
        session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        service = ExtensionBridgeService(vaultSession: session)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func addFixtureEntry(title: String, username: String, password: String, url: String) -> UUID {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        entry.title = title
        entry.login = username
        entry.password = password
        entry.url = url
        session.mutate { db in
            db.rootGroup.entries.append(entry)
        }
        return entry.uuid
    }

    func testGetCredentialsReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com"))
        XCTAssertEqual(response, .locked)
    }

    func testGetCredentialsReturnsMatchingSummariesWithoutPasswords() {
        _ = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com/login"))
        guard case .credentialList(let summaries) = response else {
            return XCTFail("expected credentialList, got \(response)")
        }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].title, "Example")
        XCTAssertEqual(summaries[0].username, "alice")
    }

    func testGetCredentialsExcludesNonMatchingDomain() {
        _ = addFixtureEntry(title: "Other", username: "bob", password: "pw", url: "https://other.com")
        let response = service.handle(.getCredentials(token: "t", url: "https://example.com"))
        XCTAssertEqual(response, .credentialList([]))
    }

    func testFillCredentialReturnsPasswordAndTotpForMatchingEntry() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        session.mutate { db in
            if let index = db.rootGroup.entries.firstIndex(where: { $0.uuid == id }) {
                db.rootGroup.entries[index].totpSecretBase32 = "JBSWY3DP"
            }
        }
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://example.com"))
        XCTAssertEqual(response, .credential(username: "alice", password: "s3cret", totp: "JBSWY3DP"))
    }

    func testFillCredentialReturnsErrorWhenDomainDoesNotMatch() {
        let id = addFixtureEntry(title: "Example", username: "alice", password: "s3cret", url: "https://example.com")
        let response = service.handle(.fillCredential(token: "t", id: id.uuidString, url: "https://not-example.com"))
        XCTAssertEqual(response, .error("entry not found or domain mismatch"))
    }

    func testFillCredentialReturnsLockedWhenVaultIsLocked() {
        session.lock()
        let response = service.handle(.fillCredential(token: "t", id: UUID().uuidString, url: "https://example.com"))
        XCTAssertEqual(response, .locked)
    }

    func testProposeSaveLoginInvokesClosureAndReturnsAccepted() {
        var captured: (url: String, username: String, password: String)?
        service.onSaveProposal = { url, username, password in
            captured = (url, username, password)
        }
        let response = service.handle(.proposeSaveLogin(
            token: "t", url: "https://example.com/signup", username: "carol", password: "pw123"
        ))
        XCTAssertEqual(response, .saveProposalAccepted)
        XCTAssertEqual(captured?.url, "https://example.com/signup")
        XCTAssertEqual(captured?.username, "carol")
        XCTAssertEqual(captured?.password, "pw123")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionBridgeServiceTests`
Expected: FAIL — `ExtensionBridgeService` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift`:

```swift
import Foundation
import MyPassKit
import ExtensionBridgeKit

/// UI-agnostic request handler for the browser-extension bridge. Token
/// validation happens one layer up, in `LoopbackServer` (Phase 4, Task 6),
/// before a request ever reaches this type — `handle(_:)` trusts its caller.
final class ExtensionBridgeService {
    weak var vaultSession: VaultSession?
    /// Fired for `.proposeSaveLogin` requests. Wired to real window-activation +
    /// pre-filled create-entry UI in Task 13 (`MyPassApp.init()` sets this to a
    /// closure that populates `NavigationState.pendingSaveProposal` and brings
    /// `MyPass.app` to the foreground) — not left as a bare extension point.
    var onSaveProposal: ((_ url: String, _ username: String, _ password: String) -> Void)?

    init(vaultSession: VaultSession) {
        self.vaultSession = vaultSession
    }

    func handle(_ request: ExtensionBridgeRequest) -> ExtensionBridgeResponse {
        switch request {
        case .getCredentials(_, let url):
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            let summaries = matches.map {
                ExtensionCredentialSummary(id: $0.uuid.uuidString, title: $0.title, username: $0.login)
            }
            return .credentialList(summaries)

        case .fillCredential(_, let id, let url):
            guard let database = vaultSession?.currentDatabase else {
                return .locked
            }
            let matches = ExtensionEntryMatcher.matchingEntries(in: database.rootGroup, forURL: url)
            guard let entry = matches.first(where: { $0.uuid.uuidString == id }) else {
                return .error("entry not found or domain mismatch")
            }
            return .credential(username: entry.login, password: entry.password, totp: entry.totpSecretBase32)

        case .proposeSaveLogin(_, let url, let username, let password):
            onSaveProposal?(url, username, password)
            return .saveProposalAccepted
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ExtensionBridgeServiceTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/ExtensionBridge/ExtensionBridgeService.swift MyPassTests/ExtensionBridgeServiceTests.swift
git commit -m "Phase 4, Task 5: ExtensionBridgeService (getCredentials/fillCredential/proposeSaveLogin)"
```

---

### Task 6: `LoopbackServer`

**Files:**
- Create: `MyPass/State/ExtensionBridge/LoopbackServer.swift`
- Test: `MyPassTests/LoopbackServerTests.swift`

**Interfaces:**
- Consumes: `ExtensionBridgeTokenStoring `/`InMemoryExtensionBridgeTokenStore `/`ExtensionBridgeTokenStore `/`ExtensionBridgeEndpoint` (Task 3), `ExtensionBridgeRequest `/`ExtensionBridgeResponse` (Task 2), `NativeMessagingCodec `/`NativeMessagingFrameReader` (Task 1).
- Produces:
```swift
final class LoopbackServer {
    enum LoopbackServerError: Error { case listenerFailed, timedOut }
    init(tokenStore: ExtensionBridgeTokenStoring, handler: @escaping (ExtensionBridgeRequest) -> ExtensionBridgeResponse)
    private(set) var port: UInt16?
    func start() throws
    func stop()
    static func isValidToken(_ candidate: String, expected: String) -> Bool
}
```
Consumed by Task 7 (`MyPassApp.init()` constructs and starts it, `AppDelegate.extensionBridgeServer` retains it).

- [ ] **Step 1: Write the failing test**

Create `MyPassTests/LoopbackServerTests.swift`:

```swift
import XCTest
import Network
import ExtensionBridgeKit
@testable import MyPass

final class LoopbackServerTests: XCTestCase {
    func testIsValidTokenMatchesExactString() {
        XCTAssertTrue(LoopbackServer.isValidToken("abc", expected: "abc"))
    }

    func testIsValidTokenRejectsMismatch() {
        XCTAssertFalse(LoopbackServer.isValidToken("abc", expected: "xyz"))
    }

    func testIsValidTokenRejectsEmptyCandidate() {
        XCTAssertFalse(LoopbackServer.isValidToken("", expected: "abc"))
    }

    func testServerRoundTripsAValidGetCredentialsRequest() throws {
        let tokenStore = InMemoryExtensionBridgeTokenStore()
        let server = LoopbackServer(tokenStore: tokenStore) { request in
            guard case .getCredentials = request else { return .error("unexpected") }
            return .credentialList([ExtensionCredentialSummary(id: "1", title: "Test", username: "u")])
        }
        try server.start()
        defer { server.stop() }

        guard let port = server.port, let endpoint = try tokenStore.load() else {
            return XCTFail("server did not persist an endpoint after start()")
        }
        XCTAssertEqual(endpoint.port, port)

        let expectation = expectation(description: "response received")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let reader = NativeMessagingFrameReader()
        var receivedResponse: ExtensionBridgeResponse?

        connection.stateUpdateHandler = { state in
            if state == .ready {
                let request = ExtensionBridgeRequest.getCredentials(token: endpoint.token, url: "https://example.com")
                let payload = try! JSONEncoder().encode(request)
                connection.send(content: NativeMessagingCodec.encode(payload), completion: .contentProcessed { _ in })
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data else { return }
            let frames = reader.feed(data)
            if let frame = frames.first, let response = try? JSONDecoder().decode(ExtensionBridgeResponse.self, from: frame) {
                receivedResponse = response
                expectation.fulfill()
            }
        }
        connection.start(queue: .main)

        wait(for: [expectation], timeout: 5)
        connection.cancel()
        XCTAssertEqual(
            receivedResponse,
            .credentialList([ExtensionCredentialSummary(id: "1", title: "Test", username: "u")])
        )
    }

    func testServerRejectsInvalidToken() throws {
        let tokenStore = InMemoryExtensionBridgeTokenStore()
        let server = LoopbackServer(tokenStore: tokenStore) { _ in
            .credentialList([ExtensionCredentialSummary(id: "1", title: "Should not be reached", username: "u")])
        }
        try server.start()
        defer { server.stop() }
        guard let port = server.port else { return XCTFail("server did not report a port") }

        let expectation = expectation(description: "error response received")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let reader = NativeMessagingFrameReader()
        var receivedResponse: ExtensionBridgeResponse?

        connection.stateUpdateHandler = { state in
            if state == .ready {
                let request = ExtensionBridgeRequest.getCredentials(token: "wrong-token", url: "https://example.com")
                let payload = try! JSONEncoder().encode(request)
                connection.send(content: NativeMessagingCodec.encode(payload), completion: .contentProcessed { _ in })
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data else { return }
            let frames = reader.feed(data)
            if let frame = frames.first, let response = try? JSONDecoder().decode(ExtensionBridgeResponse.self, from: frame) {
                receivedResponse = response
                expectation.fulfill()
            }
        }
        connection.start(queue: .main)

        wait(for: [expectation], timeout: 5)
        connection.cancel()
        XCTAssertEqual(receivedResponse, .error("invalid token"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/LoopbackServerTests`
Expected: FAIL — `LoopbackServer` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `MyPass/State/ExtensionBridge/LoopbackServer.swift`:

```swift
import Foundation
import Network
import ExtensionBridgeKit

/// TCP listener on 127.0.0.1, random OS-assigned port, guarding every request
/// with a per-launch token persisted to Keychain (Task 3). Owns no UI state —
/// delegates request handling entirely to the injected `handler` closure
/// (`ExtensionBridgeService.handle`, wired in Task 7), dispatched onto the
/// main thread since it touches `VaultSession`.
final class LoopbackServer {
    enum LoopbackServerError: Error {
        case listenerFailed
        case timedOut
    }

    private let tokenStore: ExtensionBridgeTokenStoring
    private let handler: (ExtensionBridgeRequest) -> ExtensionBridgeResponse
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private var token: String = ""

    private(set) var port: UInt16?

    init(tokenStore: ExtensionBridgeTokenStoring, handler: @escaping (ExtensionBridgeRequest) -> ExtensionBridgeResponse) {
        self.tokenStore = tokenStore
        self.handler = handler
    }

    static func isValidToken(_ candidate: String, expected: String) -> Bool {
        !candidate.isEmpty && candidate == expected
    }

    func start() throws {
        let newListener = try NWListener(using: .tcp, on: .any)
        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed:
                startError = LoopbackServerError.listenerFailed
                semaphore.signal()
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.start(queue: .main)

        guard semaphore.wait(timeout: .now() + 5) == .success,
              startError == nil,
              let assignedPort = newListener.port else {
            newListener.cancel()
            throw startError ?? LoopbackServerError.timedOut
        }

        let generatedToken = ExtensionBridgeTokenStore.generateToken()
        try tokenStore.save(ExtensionBridgeEndpoint(port: assignedPort.rawValue, token: generatedToken))

        listener = newListener
        port = assignedPort.rawValue
        token = generatedToken
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activeConnections.forEach { $0.cancel() }
        activeConnections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        activeConnections.append(connection)
        let reader = NativeMessagingFrameReader()
        connection.start(queue: .main)
        receive(on: connection, reader: reader)
    }

    private func receive(on connection: NWConnection, reader: NativeMessagingFrameReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for frame in reader.feed(data) {
                    self.handleFrame(frame, on: connection)
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                self.activeConnections.removeAll { $0 === connection }
                return
            }
            self.receive(on: connection, reader: reader)
        }
    }

    private func handleFrame(_ frame: Data, on connection: NWConnection) {
        guard let request = try? JSONDecoder().decode(ExtensionBridgeRequest.self, from: frame) else {
            send(.error("malformed request"), on: connection)
            return
        }
        guard LoopbackServer.isValidToken(requestToken(from: request), expected: token) else {
            send(.error("invalid token"), on: connection)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let response = self.handler(request)
            self.send(response, on: connection)
        }
    }

    private func requestToken(from request: ExtensionBridgeRequest) -> String {
        switch request {
        case .getCredentials(let token, _): return token
        case .fillCredential(let token, _, _): return token
        case .proposeSaveLogin(let token, _, _, _): return token
        }
    }

    private func send(_ response: ExtensionBridgeResponse, on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(response) else { return }
        connection.send(content: NativeMessagingCodec.encode(payload), completion: .contentProcessed { _ in })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/LoopbackServerTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/ExtensionBridge/LoopbackServer.swift MyPassTests/LoopbackServerTests.swift
git commit -m "Phase 4, Task 6: LoopbackServer (TCP 127.0.0.1, token-gated framed JSON)"
```

---

### Task 7: Wire `LoopbackServer` + `ExtensionBridgeService` into `MyPassApp.init()` and `AppDelegate`

**Files:**
- Modify: `MyPass/AppDelegate.swift`
- Modify: `MyPass/MyPassApp.swift`

**Interfaces:**
- Consumes: `LoopbackServer` (Task 6), `ExtensionBridgeService` (Task 5), `ExtensionBridgeTokenStore` (Task 3), the existing `session `/`_vaultSession` local variables in `MyPassApp.init()`, the existing `AppDelegate` static-property idiom.
- Produces: `AppDelegate.extensionBridgeServer: LoopbackServer?`, populated at app launch — consumed by nothing further in this plan (it is the terminal wiring point), but keeps the server retained for the app's lifetime.

- [ ] **Step 1: Modify `AppDelegate.swift`**

Add the new static property, following the exact existing idiom (`activityMonitorToken`, `backgroundSyncTimer`, `localFolderChangeWatcher`):

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var activityMonitorToken: Any?
    static var backgroundSyncTimer: Timer?
    static var localFolderChangeWatcher: LocalFolderChangeWatcher?
    /// Phase 4: retains the loopback server that bridges MyPass.app to ChromeHost
    /// for the lifetime of the app.
    static var extensionBridgeServer: LoopbackServer?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
```

- [ ] **Step 2: Modify `MyPassApp.swift`**

Immediately after `_vaultSession = StateObject(wrappedValue: session)` in `init()`, add:

```swift
let extensionBridgeService = ExtensionBridgeService(vaultSession: session)
let extensionBridgeServer = LoopbackServer(
    tokenStore: ExtensionBridgeTokenStore(),
    handler: extensionBridgeService.handle
)
try? extensionBridgeServer.start()
AppDelegate.extensionBridgeServer = extensionBridgeServer

NativeMessagingHostInstaller.installIfNeeded(
    hostBinaryPath: NativeMessagingHostInstaller.debugChromeHostBinaryPath,
    extensionID: NativeMessagingHostInstaller.developmentPlaceholderExtensionID
)
```

(`NativeMessagingHostInstaller` and its two placeholder constants are created in Task 8 — this task only adds the call site; the build will not compile until Task 8 lands. If executing tasks strictly in order, treat Tasks 7 and 8 as landing together in one build-verifiable checkpoint, or stub `NativeMessagingHostInstaller` minimally in this task and flesh it out in Task 8 — this plan takes the former approach: Task 7's manual verification step below assumes Task 8 has already been applied.)

- [ ] **Step 3: Manual verification (build + smoke test)**

This wiring lives in `MyPassApp.init()`, which is not directly unit-testable (it's `@main` app struct construction). Verify manually:

```bash
xcodegen generate
xcodebuild -project MyPass.xcodeproj -scheme MyPass build
```

Expected: build succeeds (once Task 8's `NativeMessagingHostInstaller` exists).

Then run the built app (`open` the `.app` product, or run from Xcode), and confirm the listener came up:
1. Add a one-time `os_log("ExtensionBridge listening on port %d", log: .default, type: .info, extensionBridgeServer.port ?? 0)` call right after `try? extensionBridgeServer.start()` (temporary, for this verification step only — leave it in, it is harmless and useful for future debugging of "app not running" reports).
2. Open Console.app, filter by process `MyPass`, launch the app, confirm the log line appears with a non-zero port.
3. Take note of the printed port, then from Terminal run `nc -z 127.0.0.1 <port>` — expect `Connection to 127.0.0.1 port <port> succeeded!`, confirming the TCP listener is actually accepting connections.

- [ ] **Step 4: Commit**

```bash
git add MyPass/AppDelegate.swift MyPass/MyPassApp.swift
git commit -m "Phase 4, Task 7: wire LoopbackServer + ExtensionBridgeService into app launch"
```

---

### Task 8: `ChromeHost` executable target scaffold + native-messaging-manifest installer

**Files:**
- Modify: `project.yml` (add `ChromeHost` `type: tool` target)
- Create: `ChromeHost/ChromeHost.entitlements`
- Create: `ChromeHost/main.swift`
- Create: `MyPass/State/ExtensionBridge/NativeMessagingHostInstaller.swift`
- Test: `MyPassTests/NativeMessagingHostInstallerTests.swift`

**Interfaces:**
- Consumes: `NativeMessagingCodec `/`NativeMessagingFrameReader` (Task 1), `ExtensionBridgeKit` package dependency.
- Produces:
```swift
enum NativeMessagingHostInstaller {
    static let developmentPlaceholderExtensionID: String
    static var debugChromeHostBinaryPath: String { get }
    static func installIfNeeded(hostBinaryPath: String, extensionID: String, directory: URL = defaultDirectory) throws
}
```
Consumed by Task 7's `MyPassApp.init()` call site (already written, forward-referencing this task). `ChromeHost/main.swift`'s stdio loop scaffold is fleshed out into the real relay in Task 9.

- [ ] **Step 1: Modify `project.yml`**

Add the `ChromeHost` tool target, and add `ExtensionBridgeKit` to it:

```yaml
targets:
  MyPass:
    # ... unchanged ...
  ChromeHost:
    type: tool
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: ChromeHost
    dependencies:
      - package: ExtensionBridgeKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.mypass.chromehost
        CODE_SIGN_ENTITLEMENTS: ChromeHost/ChromeHost.entitlements
        MARKETING_VERSION: "0.1.0"
  MyPassTests:
    # ... unchanged ...
```

- [ ] **Step 2: Create `ChromeHost/ChromeHost.entitlements`**

Design note: `ChromeHost` is a native-messaging host launched directly by Chrome as a plain child process — it is NOT App Sandboxed (there is deliberately no `com.apple.security.app-sandbox` key here), only entitled for the shared Keychain access group it needs to read the loopback endpoint written by `MyPass.app `.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.keychain-access-groups</key>
    <array>
        <string>com.mypass.app.keychain</string>
    </array>
</dict>
</plist>
```

MANUAL VERIFICATION NOTE (cannot be automated): for `SecItemCopyMatching `/`SecItemAdd` calls tagged with `kSecAttrAccessGroup: "com.mypass.app.keychain"` to actually succeed across processes, both `MyPass.app` and `ChromeHost` must be code-signed with the **same Apple Developer Team ID**. There is no test in this plan that verifies this — it must be checked manually in Xcode's signing settings for both targets (Signing & Capabilities tab) before relying on cross-process Keychain sharing in Task 9's manual smoke test.

- [ ] **Step 3: Create `ChromeHost/main.swift` (scaffold — echoes frames, real relay logic lands in Task 9)**

```swift
import Foundation
import ExtensionBridgeKit

let reader = NativeMessagingFrameReader()
let stdin = FileHandle.standardInput
let stdout = FileHandle.standardOutput

FileHandle.standardError.write(Data("ChromeHost started\n".utf8))

while true {
    let chunk = stdin.availableData
    if chunk.isEmpty {
        break
    }
    let frames = reader.feed(chunk)
    for frame in frames {
        // Scaffolding only: echo the raw frame back framed, unchanged, so the
        // stdio loop itself can be smoke-tested before Task 9 replaces this
        // body with the real stdio<->TCP relay.
        stdout.write(NativeMessagingCodec.encode(frame))
    }
}
```

- [ ] **Step 4: Create `NativeMessagingHostInstaller.swift`**

```swift
import Foundation

enum NativeMessagingHostInstaller {
    /// Placeholder until Task 12 (loading the unpacked extension via
    /// chrome://extensions) produces a real ID. Rewriting the manifest with
    /// the real ID after that point is a manual dev-workflow step — see the
    /// Task 12 checklist. Not suitable for distribution as-is.
    static let developmentPlaceholderExtensionID = "REPLACE_WITH_UNPACKED_EXTENSION_ID"

    /// Debug build product path convention for local development. Not a
    /// stable path for distribution — revisit before shipping outside a dev
    /// machine (e.g. resolve the real installed ChromeHost path instead).
    static var debugChromeHostBinaryPath: String {
        NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData/MyPass/Build/Products/Debug/ChromeHost"
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
    }

    static func installIfNeeded(
        hostBinaryPath: String,
        extensionID: String,
        directory: URL = defaultDirectory
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "name": "com.mypass.chromehost",
            "description": "MyPass native messaging host",
            "path": hostBinaryPath,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"]
        ]
        let newData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])

        let fileURL = directory.appendingPathComponent("com.mypass.chromehost.json")
        if let existingData = try? Data(contentsOf: fileURL), existingData == newData {
            return
        }
        try newData.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 5: Write the failing test**

Create `MyPassTests/NativeMessagingHostInstallerTests.swift`:

```swift
import XCTest
@testable import MyPass

final class NativeMessagingHostInstallerTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassNativeMessagingHostInstallerTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInstallWritesManifestWithExpectedShape() throws {
        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost",
            extensionID: "abcdefghijklmnop",
            directory: tempDir
        )
        let fileURL = tempDir.appendingPathComponent("com.mypass.chromehost.json")
        let data = try Data(contentsOf: fileURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["name"] as? String, "com.mypass.chromehost")
        XCTAssertEqual(object["path"] as? String, "/usr/local/bin/ChromeHost")
        XCTAssertEqual(object["type"] as? String, "stdio")
        let allowedOrigins = try XCTUnwrap(object["allowed_origins"] as? [String])
        XCTAssertEqual(allowedOrigins, ["chrome-extension://abcdefghijklmnop/"])
    }

    func testInstallCreatesDirectoryIfMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost",
            extensionID: "abcdefghijklmnop",
            directory: tempDir
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testInstallIsIdempotentWhenContentIsUnchanged() throws {
        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost", extensionID: "abcdefghijklmnop", directory: tempDir
        )
        let fileURL = tempDir.appendingPathComponent("com.mypass.chromehost.json")
        let firstContent = try Data(contentsOf: fileURL)

        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost", extensionID: "abcdefghijklmnop", directory: tempDir
        )
        let secondContent = try Data(contentsOf: fileURL)
        XCTAssertEqual(firstContent, secondContent, "content should be byte-identical after a no-op reinstall")
    }

    func testInstallRewritesWhenContentChanges() throws {
        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost", extensionID: "abcdefghijklmnop", directory: tempDir
        )
        try NativeMessagingHostInstaller.installIfNeeded(
            hostBinaryPath: "/usr/local/bin/ChromeHost", extensionID: "zzzzzzzzzzzzzzzz", directory: tempDir
        )
        let fileURL = tempDir.appendingPathComponent("com.mypass.chromehost.json")
        let data = try Data(contentsOf: fileURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowedOrigins = try XCTUnwrap(object["allowed_origins"] as? [String])
        XCTAssertEqual(allowedOrigins, ["chrome-extension://zzzzzzzzzzzzzzzz/"])
    }
}
```

- [ ] **Step 6: Run test to verify it fails, then passes**

Run: `xcodegen generate && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/NativeMessagingHostInstallerTests`
Expected: FAILs first (type doesn't exist) before Step 4's code is added; PASS (4 tests) after.

- [ ] **Step 7: Manual smoke test for `ChromeHost` scaffold**

```bash
xcodebuild -project MyPass.xcodeproj -scheme ChromeHost build
```

Then locate the built binary (e.g. `~/Library/Developer/Xcode/DerivedData/MyPass-*/Build/Products/Debug/ChromeHost`) and run it directly, piping one hand-crafted framed message via `python3`:

```bash
python3 -c '
import struct, sys
payload = b"{\"hello\":\"world\"}"
sys.stdout.buffer.write(struct.pack("<I", len(payload)) + payload)
' | ~/Library/Developer/Xcode/DerivedData/MyPass-*/Build/Products/Debug/ChromeHost | xxd
```

Expected: the same 4-byte-length-prefixed frame is echoed back on stdout (visible via `xxd` as the identical bytes), confirming the stdio read/decode/encode/write loop works end to end before Task 9 adds real relay logic.

- [ ] **Step 8: Commit**

```bash
git add project.yml ChromeHost/ChromeHost.entitlements ChromeHost/main.swift MyPass/State/ExtensionBridge/NativeMessagingHostInstaller.swift MyPassTests/NativeMessagingHostInstallerTests.swift MyPass.xcodeproj
git commit -m "Phase 4, Task 8: ChromeHost target scaffold + NativeMessagingHostInstaller"
```

---

### Task 9: `ChromeHost` relay logic: stdio ↔ TCP bridge

**Files:**
- Create: `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/RelayTokenInjector.swift`
- Create: `ChromeHost/Relay.swift`
- Modify: `ChromeHost/main.swift`
- Test: `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/RelayTokenInjectorTests.swift`

**Interfaces:**
- Consumes: `NativeMessagingCodec `/`NativeMessagingFrameReader` (Task 1), `ExtensionBridgeTokenStore `/`ExtensionBridgeTokenStoring `/`ExtensionBridgeEndpoint` (Task 3).
- Produces: `RelayTokenInjector.injectToken(into:token:) throws -> Data` (pure, unit-testable — the only piece of this task testable without a live socket/process); `Relay.run()` (the full stdio↔TCP bridge, manually smoke-tested).

The pure token-injection function is placed in `ExtensionBridgeKit` (not in `ChromeHost` itself) specifically so it can be covered by ordinary XCTest without standing up a separate test target for the `tool`-type `ChromeHost` executable.

- [ ] **Step 1: Write the failing test**

Create `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/RelayTokenInjectorTests.swift`:

```swift
import XCTest
@testable import ExtensionBridgeKit

final class RelayTokenInjectorTests: XCTestCase {
    func testInjectTokenAddsTokenFieldToExistingObject() throws {
        let requestJSON = Data("{\"type\":\"getCredentials\",\"url\":\"https://example.com\"}".utf8)
        let result = try RelayTokenInjector.injectToken(into: requestJSON, token: "tok-abc")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(object["token"] as? String, "tok-abc")
        XCTAssertEqual(object["type"] as? String, "getCredentials")
        XCTAssertEqual(object["url"] as? String, "https://example.com")
    }

    func testInjectTokenOverwritesExistingTokenField() throws {
        let requestJSON = Data("{\"type\":\"getCredentials\",\"token\":\"old\",\"url\":\"https://example.com\"}".utf8)
        let result = try RelayTokenInjector.injectToken(into: requestJSON, token: "new-token")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(object["token"] as? String, "new-token")
    }

    func testInjectTokenThrowsOnMalformedJSON() {
        let malformed = Data("not json".utf8)
        XCTAssertThrowsError(try RelayTokenInjector.injectToken(into: malformed, token: "t"))
    }

    func testInjectTokenThrowsOnNonObjectJSON() {
        let arrayJSON = Data("[1,2,3]".utf8)
        XCTAssertThrowsError(try RelayTokenInjector.injectToken(into: arrayJSON, token: "t"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/ExtensionBridgeKit && swift test --filter RelayTokenInjectorTests`
Expected: FAIL — `RelayTokenInjector` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/RelayTokenInjector.swift`:

```swift
import Foundation

/// Injects the loopback auth token into an outgoing request on ChromeHost's
/// behalf, so the token never has to be known by, or pass through, the
/// browser extension itself (background.js/content.js/popup.js never see it) —
/// an extra security property beyond what the design spec strictly requires.
public enum RelayTokenInjector {
    public enum RelayTokenInjectorError: Error {
        case invalidJSON
    }

    public static func injectToken(into requestJSON: Data, token: String) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: requestJSON) as? [String: Any] else {
            throw RelayTokenInjectorError.invalidJSON
        }
        object["token"] = token
        return try JSONSerialization.data(withJSONObject: object)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/ExtensionBridgeKit && swift test --filter RelayTokenInjectorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Create `ChromeHost/Relay.swift`**

```swift
import Foundation
import Network
import ExtensionBridgeKit

enum Relay {
    static func run(tokenStore: ExtensionBridgeTokenStoring = ExtensionBridgeTokenStore()) {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        let requestReader = NativeMessagingFrameReader()
        let responseReader = NativeMessagingFrameReader()

        guard let endpoint = (try? tokenStore.load()) ?? nil else {
            writeError("app_not_running", to: stdout)
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: endpoint.port) else {
            writeError("app_not_running", to: stdout)
            return
        }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)

        let readySemaphore = DispatchSemaphore(value: 0)
        var connectionFailed = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readySemaphore.signal()
            case .failed, .cancelled:
                connectionFailed = true
                readySemaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: .main)
        _ = readySemaphore.wait(timeout: .now() + 5)

        guard !connectionFailed else {
            writeError("app_not_running", to: stdout)
            return
        }

        func receiveResponses() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    for frame in responseReader.feed(data) {
                        stdout.write(NativeMessagingCodec.encode(frame))
                    }
                }
                if isComplete || error != nil {
                    return
                }
                receiveResponses()
            }
        }
        receiveResponses()

        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty {
                break
            }
            for frame in requestReader.feed(chunk) {
                guard let framedRequest = try? RelayTokenInjector.injectToken(into: frame, token: endpoint.token) else {
                    writeError("malformed_request", to: stdout)
                    continue
                }
                connection.send(content: NativeMessagingCodec.encode(framedRequest), completion: .contentProcessed { _ in })
            }
        }

        connection.cancel()
    }

    private static func writeError(_ message: String, to handle: FileHandle) {
        let payload = Data("{\"type\":\"error\",\"message\":\"\(message)\"}".utf8)
        handle.write(NativeMessagingCodec.encode(payload))
    }
}
```

- [ ] **Step 6: Replace `ChromeHost/main.swift`'s echo scaffold with the real relay entry point**

```swift
import Foundation

Relay.run()
```

- [ ] **Step 7: Add `ExtensionBridgeKit` dependency check + manual smoke test**

`ChromeHost` already depends on `ExtensionBridgeKit` (Task 8). Rebuild:

```bash
xcodebuild -project MyPass.xcodeproj -scheme ChromeHost build
```

Manual end-to-end smoke test (requires MyPass.app running from Task 7, so a real `LoopbackServer` endpoint exists in Keychain):
1. Launch `MyPass.app` (Task 7's wiring starts `LoopbackServer` and persists the endpoint).
2. Run the built `ChromeHost` binary directly and pipe a hand-crafted `getCredentials` request (without a `token` field — `Relay.run()` injects it):
```bash
python3 -c '
import struct, sys
payload = b"{\"type\":\"getCredentials\",\"url\":\"https://example.com\"}"
sys.stdout.buffer.write(struct.pack("<I", len(payload)) + payload)
' | ~/Library/Developer/Xcode/DerivedData/MyPass-*/Build/Products/Debug/ChromeHost | xxd
```
Expected: a framed JSON response is printed — `{"type":"locked"}` if the vault is locked, or `{"type":"credentialList","credentials":[...]}` if unlocked — confirming the full stdio → token-inject → TCP → `ExtensionBridgeService` → TCP → stdio round trip works.
3. Quit `MyPass.app` and repeat step 2: expect `{"type":"error","message":"app_not_running"}` since the TCP connection now fails.

- [ ] **Step 8: Commit**

```bash
git add Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/RelayTokenInjector.swift Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/RelayTokenInjectorTests.swift ChromeHost/Relay.swift ChromeHost/main.swift
git commit -m "Phase 4, Task 9: ChromeHost stdio<->TCP relay with token injection"
```

---

### Task 10: Chrome extension — `manifest.json` + `background.js`

**Files:**
- Create: `ChromeExtension/manifest.json`
- Create: `ChromeExtension/background.js`
- Test: `ChromeExtension/tests/background.manifest.test.js`

**Interfaces:**
- Consumes: nothing from Swift tasks directly — talks to `ChromeHost` via `chrome.runtime.sendNativeMessage("com.mypass.chromehost", message, callback)`, exchanging the exact JSON shapes pinned by Task 2's tests (`{"type":"getCredentials","url":...}` etc., response `{"type":"locked"}` / `{"type":"credentialList","credentials":[{"id","title","username"}]}` / `{"type":"credential","username","password","totp"}` / `{"type":"saveProposalAccepted"}` / `{"type":"error","message"}`).
- Produces: a `chrome.runtime.onMessage` listener that `content.js` (Task 11) and `popup.js` (Task 12) send `{type: "getCredentials"|"fillCredential"|"proposeSaveLogin", ...}` messages to, and an `applyFill` message (`{type: "applyFill", username, password, totp}`) that `background.js` forwards to the active tab's `content.js` after a successful `fillCredential `.

- [ ] **Step 1: Create `ChromeExtension/manifest.json`**

```json
{
  "manifest_version": 3,
  "name": "MyPass",
  "version": "0.1.0",
  "description": "Autofill and save logins from MyPass",
  "permissions": ["nativeMessaging", "activeTab", "scripting"],
  "background": {
    "service_worker": "background.js"
  },
  "action": {
    "default_popup": "popup.html"
  },
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["content.js"],
      "run_at": "document_idle"
    }
  ]
}
```

- [ ] **Step 2: Create `ChromeExtension/background.js`**

```javascript
const NATIVE_HOST_NAME = "com.mypass.chromehost";

function sendNativeMessage(message) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(NATIVE_HOST_NAME, message, (response) => {
      if (chrome.runtime.lastError || !response) {
        resolve({ type: "error", message: "app_not_running" });
        return;
      }
      resolve(response);
    });
  });
}

function relayFillToActiveTab(credentialResponse) {
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    const activeTab = tabs[0];
    if (!activeTab || activeTab.id === undefined) return;
    chrome.tabs.sendMessage(activeTab.id, {
      type: "applyFill",
      username: credentialResponse.username,
      password: credentialResponse.password,
      totp: credentialResponse.totp || null
    });
  });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const knownTypes = ["getCredentials", "fillCredential", "proposeSaveLogin"];
  if (!message || !knownTypes.includes(message.type)) {
    return false;
  }

  sendNativeMessage(message).then((response) => {
    if (message.type === "fillCredential" && response && response.type === "credential") {
      relayFillToActiveTab(response);
    }
    sendResponse(response);
  });

  return true; // keep the message channel open for the async sendNativeMessage response
});
```

Judgment call: the design spec sketches `chrome.runtime.connectNative` (a persistent port); this plan uses `chrome.runtime.sendNativeMessage` (one-shot request/response) instead, since MV3 service workers are not guaranteed to stay alive between messages and a one-shot call maps directly onto `LoopbackServer`'s per-request-response model with no additional connection-lifecycle bookkeeping — behaviorally equivalent for this design's request/response traffic pattern.

- [ ] **Step 3: Write the manifest regression test**

Create `ChromeExtension/tests/background.manifest.test.js`:

```javascript
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const manifestPath = path.join(__dirname, '..', 'manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

assert.strictEqual(manifest.manifest_version, 3, 'manifest_version must be 3');
assert.strictEqual(manifest.name, 'MyPass');
assert.ok(Array.isArray(manifest.permissions), 'permissions must be an array');
assert.ok(manifest.permissions.includes('nativeMessaging'), 'missing nativeMessaging permission');
assert.ok(manifest.permissions.includes('activeTab'), 'missing activeTab permission');
assert.ok(manifest.permissions.includes('scripting'), 'missing scripting permission');
assert.strictEqual(manifest.background.service_worker, 'background.js');
assert.strictEqual(manifest.action.default_popup, 'popup.html');
assert.strictEqual(manifest.content_scripts.length, 1);
assert.strictEqual(manifest.content_scripts[0].js[0], 'content.js');
assert.strictEqual(manifest.content_scripts[0].matches[0], '<all_urls>');
assert.strictEqual(manifest.content_scripts[0].run_at, 'document_idle');

console.log('manifest.json OK');
```

This test only catches manifest typos/regressions — it does not exercise runtime behavior. Deeper `background.js` behavior is covered by the manual Chrome-load step below and the end-to-end checklist in Task 12.

- [ ] **Step 4: Run the test to verify it fails, then passes**

Before `manifest.json` exists: `node ChromeExtension/tests/background.manifest.test.js` → FAIL (`ENOENT` reading `manifest.json`).
After Step 1: `node ChromeExtension/tests/background.manifest.test.js` → PASS, prints `manifest.json OK `.

- [ ] **Step 5: Manual verification**

Open `chrome://extensions`, enable "Developer mode", click "Load unpacked", select the `ChromeExtension/` directory. Expected: the extension loads with no manifest errors shown on the extensions page, and its icon appears in the toolbar.

- [ ] **Step 6: Commit**

```bash
git add ChromeExtension/manifest.json ChromeExtension/background.js ChromeExtension/tests/background.manifest.test.js
git commit -m "Phase 4, Task 10: Chrome extension manifest.json + background.js native messaging bridge"
```

---

### Task 11: Chrome extension — `content.js` (form detection + fill + save banner)

**Files:**
- Create: `ChromeExtension/content.js`
- Test: `ChromeExtension/tests/formDetection.test.js`

**Interfaces:**
- Consumes: `chrome.runtime.sendMessage `/` chrome.runtime.onMessage` contract from Task 10 (`background.js`); messages `{type: "getCredentials", url}`, `{type: "proposeSaveLogin", url, username, password}`, and the incoming `{type: "applyFill", username, password, totp}`.
- Produces: `scoreUsernameLikeness `/` findBestUsernameInput` (pure, `module.exports`-guarded for Node testing), `findLoginForm()`, the submit-listener/save-banner UI. Consumed by Task 12's manual e2e checklist (this task's DOM logic is not consumed by other JS files — it is the terminal content-script).

- [ ] **Step 1: Create `ChromeExtension/content.js`**

```javascript
(function () {
  function scoreUsernameLikeness(input) {
    let score = 0;
    const autocomplete = (input.getAttribute('autocomplete') || '').toLowerCase();
    const name = (input.getAttribute('name') || '').toLowerCase();
    const id = (input.getAttribute('id') || '').toLowerCase();
    const type = (input.getAttribute('type') || 'text').toLowerCase();

    if (autocomplete.includes('username')) score += 5;
    if (type === 'email') score += 3;
    if (/user|login|email/.test(name)) score += 2;
    if (/user|login|email/.test(id)) score += 2;
    if (type === 'text' || type === 'email') score += 1;
    return score;
  }

  function findBestUsernameInput(candidates) {
    if (candidates.length === 0) return null;
    let best = candidates[0];
    let bestScore = scoreUsernameLikeness(best);
    for (let i = 1; i < candidates.length; i++) {
      const score = scoreUsernameLikeness(candidates[i]);
      if (score > bestScore) {
        best = candidates[i];
        bestScore = score;
      }
    }
    return best;
  }

  function findLoginForm() {
    const passwordInput = document.querySelector('input[type="password"]');
    if (!passwordInput) return null;
    const form = passwordInput.closest('form');
    if (!form) return null;
    const candidates = Array.from(
      form.querySelectorAll('input[type="text"], input[type="email"], input[autocomplete*="username"]')
    );
    const usernameInput = findBestUsernameInput(candidates);
    return { form, passwordInput, usernameInput };
  }

  function setNativeValue(input, value) {
    input.value = value;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function showSaveBanner(url, username, password, state) {
    if (state.bannerShown) return;
    state.bannerShown = true;

    const banner = document.createElement('div');
    banner.style.cssText =
      'position:fixed;bottom:16px;right:16px;z-index:2147483647;background:#1f2937;' +
      'color:#f9fafb;padding:12px 16px;border-radius:8px;font-family:sans-serif;' +
      'font-size:13px;box-shadow:0 2px 8px rgba(0,0,0,0.3);display:flex;align-items:center;gap:8px;';
    banner.textContent = "Save password to MyPass?";

    const saveButton = document.createElement('button');
    saveButton.textContent = "Save";
    saveButton.style.cssText = 'margin-left:8px;cursor:pointer;';
    saveButton.addEventListener('click', () => {
      chrome.runtime.sendMessage({ type: 'proposeSaveLogin', url, username, password });
      banner.remove();
      state.bannerShown = false;
    });

    const closeButton = document.createElement('button');
    closeButton.textContent = '×';
    closeButton.style.cssText = 'margin-left:8px;cursor:pointer;background:none;border:none;color:inherit;';
    closeButton.addEventListener('click', () => {
      banner.remove();
      state.bannerShown = false;
    });

    banner.appendChild(saveButton);
    banner.appendChild(closeButton);
    document.body.appendChild(banner);
  }

  if (typeof chrome !== 'undefined' && typeof document !== 'undefined') {
    const state = { lastCredentialList: [], bannerShown: false };

    function requestCredentials() {
      chrome.runtime.sendMessage({ type: 'getCredentials', url: location.href }, (response) => {
        state.lastCredentialList = (response && response.type === 'credentialList') ? response.credentials : [];
      });
    }

    function attachSubmitListener(loginForm) {
      loginForm.form.addEventListener('submit', () => {
        if (state.lastCredentialList.length === 0) {
          const username = loginForm.usernameInput ? loginForm.usernameInput.value : '';
          const password = loginForm.passwordInput.value;
          if (password) {
            showSaveBanner(location.href, username, password, state);
          }
        }
      });
    }

    chrome.runtime.onMessage.addListener((message) => {
      if (message.type === 'applyFill') {
        const loginForm = findLoginForm();
        if (!loginForm) return;
        if (loginForm.usernameInput && message.username) {
          setNativeValue(loginForm.usernameInput, message.username);
        }
        setNativeValue(loginForm.passwordInput, message.password);
      }
    });

    // Detect the form and request the current domain's credential list on
    // load, but NEVER auto-fill here — filling only happens in response to
    // an explicit "applyFill" message triggered by a popup click (Task 12).
    const loginForm = findLoginForm();
    if (loginForm) {
      requestCredentials();
      attachSubmitListener(loginForm);
    }
  }

  if (typeof module !== 'undefined') {
    module.exports = { scoreUsernameLikeness, findBestUsernameInput };
  }
})();
```

- [ ] **Step 2: Write the Node-runnable heuristic test**

Create `ChromeExtension/tests/formDetection.test.js`:

```javascript
const assert = require('node:assert');
const path = require('node:path');
const { scoreUsernameLikeness, findBestUsernameInput } = require(path.join(__dirname, '..', 'content.js'));

function fakeInput(attrs) {
  return {
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null;
    }
  };
}

const usernameField = fakeInput({ type: 'text', autocomplete: 'username', name: 'user' });
const genericTextField = fakeInput({ type: 'text', name: 'promo-code' });
assert.ok(
  scoreUsernameLikeness(usernameField) > scoreUsernameLikeness(genericTextField),
  'autocomplete=username field should score higher than an unrelated text field'
);

const emailField = fakeInput({ type: 'email', name: 'email' });
assert.ok(
  scoreUsernameLikeness(emailField) > scoreUsernameLikeness(genericTextField),
  'email field should score higher than an unrelated text field'
);

const best = findBestUsernameInput([genericTextField, usernameField, emailField]);
assert.strictEqual(best, usernameField, 'expected the autocomplete=username field to win');

assert.strictEqual(findBestUsernameInput([]), null, 'empty candidate list must return null, not throw');

console.log('content.js form-detection heuristics OK');
```

This covers only the DOM-independent scoring heuristic. Real `document.querySelector`-based form-finding (`findLoginForm`) is NOT covered by an automated test here — adding that coverage would require a DOM shim (e.g. jsdom), which this repo's minimal-dependency convention doesn't currently include for JS. Real form-finding is verified by the manual browser checklist in Task 12.

- [ ] **Step 3: Run test to verify it fails, then passes**

Before Step 1: `node ChromeExtension/tests/formDetection.test.js` → FAIL (`content.js` does not exist).
After Step 1: `node ChromeExtension/tests/formDetection.test.js` → PASS, prints `content.js form-detection heuristics OK `.

- [ ] **Step 4: Manual verification**

Reload the unpacked extension in `chrome://extensions` (the refresh icon on the MyPass card), open any page with a login form, open DevTools console for that page, confirm no errors are logged by `content.js` on load.

- [ ] **Step 5: Commit**

```bash
git add ChromeExtension/content.js ChromeExtension/tests/formDetection.test.js
git commit -m "Phase 4, Task 11: content.js form detection, click-triggered fill, save banner"
```

---

### Task 12: Chrome extension — `popup.html `/` popup.js` + end-to-end manual checklist

**Files:**
- Create: `ChromeExtension/popup.html`
- Create: `ChromeExtension/popup.js`
- Create: `ChromeExtension/tests/fixtures/login.html`

**Interfaces:**
- Consumes: `chrome.tabs.query`, `chrome.runtime.sendMessage({type: "getCredentials", url})` / `{type: "fillCredential", id, url}` contract from Task 10's `background.js`, and the exact response shapes from Task 2 (`locked` / `credentialList` / `error`).
- Produces: nothing consumed by other files — this is the last UI surface. Its correctness is verified by the manual checklist below, which is this task's real deliverable alongside the code.

- [ ] **Step 1: Create `ChromeExtension/popup.html`**

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>MyPass</title>
  <style>
    body { font-family: sans-serif; width: 280px; padding: 8px; margin: 0; }
    #status { font-size: 13px; color: #444; margin-bottom: 8px; }
    ul { list-style: none; margin: 0; padding: 0; }
    li { padding: 6px 4px; cursor: pointer; border-radius: 4px; }
    li:hover { background: #eee; }
    .title { font-weight: 600; }
    .username { font-size: 12px; color: #666; }
  </style>
</head>
<body>
  <div id="status"></div>
  <ul id="list"></ul>
  <script src="popup.js"></script>
</body>
</html>
```

- [ ] **Step 2: Create `ChromeExtension/popup.js`**

```javascript
const statusEl = document.getElementById('status');
const listEl = document.getElementById('list');

function setStatus(text) {
  statusEl.textContent = text;
}

function renderCredentials(credentials, url) {
  listEl.innerHTML = '';
  credentials.forEach((credential) => {
    const item = document.createElement('li');

    const title = document.createElement('div');
    title.className = 'title';
    title.textContent = credential.title;

    const username = document.createElement('div');
    username.className = 'username';
    username.textContent = credential.username;

    item.appendChild(title);
    item.appendChild(username);
    item.addEventListener('click', () => {
      chrome.runtime.sendMessage({ type: 'fillCredential', id: credential.id, url }, () => {
        window.close();
      });
    });
    listEl.appendChild(item);
  });
}

chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
  const activeTab = tabs[0];
  if (!activeTab || !activeTab.url) {
    setStatus("MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).");
    return;
  }
  const url = activeTab.url;

  chrome.runtime.sendMessage({ type: 'getCredentials', url }, (response) => {
    if (!response || response.type === 'error') {
      setStatus("MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).");
      return;
    }
    if (response.type === 'locked') {
      setStatus("Open MyPass and unlock the vault");
      return;
    }
    if (response.type === 'credentialList') {
      if (response.credentials.length === 0) {
        setStatus("No saved logins for this site");
        return;
      }
      setStatus("Select an entry to autofill:");
      renderCredentials(response.credentials, url);
    }
  });
});
```

- [ ] **Step 3: Create the local test fixture**

Create `ChromeExtension/tests/fixtures/login.html`:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>MyPass test login fixture</title></head>
<body>
  <h1>Test Login</h1>
  <form id="login-form" action="#" method="post"
        onsubmit="event.preventDefault(); document.getElementById('result').textContent='submitted';">
    <label>Username <input type="text" name="username" autocomplete="username"></label>
    <br>
    <label>Password <input type="password" name="password" autocomplete="current-password"></label>
    <br>
    <button type="submit">Sign in</button>
  </form>
  <div id="result"></div>
</body>
</html>
```

- [ ] **Step 4: Manual verification (loads without errors)**

Reload the unpacked extension in `chrome://extensions`, click the MyPass toolbar icon on any page. Expected: popup opens with no console errors (inspect via right-click → "Inspect popup"), and shows one of "MyPass not found...", "Open MyPass and unlock the vault", "No saved logins for this site...", or a rendered list, depending on app/vault state.

- [ ] **Step 5: End-to-end manual checklist — Phase 4 (Chrome) completion gate**

Run through this checklist in order. This is the real final deliverable of Task 12 and of Phase 4 as a whole.

1. Build and run `ChromeHost`: `xcodebuild -project MyPass.xcodeproj -scheme ChromeHost build `.
2. In `chrome://extensions`, load `ChromeExtension/` unpacked (if not already loaded) and copy its ID from the card (a 32-character string).
3. Update the native messaging manifest with the real extension ID: temporarily call `NativeMessagingHostInstaller.installIfNeeded(hostBinaryPath: NativeMessagingHostInstaller.debugChromeHostBinaryPath, extensionID: "<the real ID from step 2>")` in place of the placeholder call in `MyPassApp.init()` (or run it once from a scratch Swift script/REPL against the same directory) — this is the acknowledged dev-workflow rough edge from Task 8; there is no automated step that discovers the real ID and feeds it back in.
4. Fully quit and relaunch `MyPass.app` so it re-registers `LoopbackServer` and re-reads the (now correctly targeted) native messaging manifest is picked up by Chrome.
5. Serve the local test fixture: `cd ChromeExtension/tests/fixtures && python3 -m http.server 8765`, then open `http://localhost:8765/login.html` in Chrome. Do NOT test against any real third-party website.
6. With the vault locked, click the MyPass toolbar icon. Expected: popup shows "Open MyPass and unlock the vault".
7. In `MyPass.app`, unlock the vault and create one entry with URL `http://localhost:8765` (or `localhost`), username `demo-user`, password `demo-pass `.
8. Reload `http://localhost:8765/login.html`, click the MyPass toolbar icon. Expected: popup lists the `demo-user` entry (no password shown in the popup).
9. Click the listed entry. Expected: the popup closes and the page's username/password fields are filled with `demo-user `/` demo-pass` (open DevTools and confirm both `input` and `change` events fired if a framework is involved — plain fixture doesn't need this, but note it for real-site testing later).
10. On the fixture page, clear both fields, type a different username/password, and submit the form (button "Sign in"). Since the domain already has a matching entry (step 7), expect NO save banner to appear (there's a match, so `content.js`'s `lastCredentialList` is non-empty at submit time — to properly exercise the banner, first delete the entry created in step 7 in `MyPass.app`, then repeat this step for a fresh submit).
11. After deleting the entry and reloading the page, submit the form again with test values. Expected: a "Save password to MyPass?" banner appears bottom-right on the page.
12. Click "Save" on the banner. Expected: the banner disappears and `MyPass.app`'s `onSaveProposal` closure fires, sending the `proposeSaveLogin` request through to `ExtensionBridgeService.handle(_:)`. This step only verifies that the message reaches `MyPass.app` and the banner clears — see Task 13's checklist for verifying that the app window activates and the pre-filled create-entry form appears, which is the rest of this flow.
13. Quit `MyPass.app` entirely, reload the fixture page, click the MyPass toolbar icon. Expected: popup shows "MyPass not found..." (since `ChromeHost`'s TCP connection now fails).

This checklist covers the autofill flow (getCredentials/fillCredential) and confirms the save-proposal message reaches `MyPass.app `. Proceed to Task 13 to build and verify the save-proposal UI itself (window activation + pre-filled create-entry form) — Phase 4 (Chrome) is not complete until Task 13's checklist also passes.

- [ ] **Step 6: Commit**

```bash
git add ChromeExtension/popup.html ChromeExtension/popup.js ChromeExtension/tests/fixtures/login.html
git commit -m "Phase 4, Task 12: popup.html/popup.js + end-to-end manual checklist (autofill flow)"
```

---

### Task 13: Saving the proposed login - UI activation of the window and pre-filled form

**Files:**
- Modify: `MyPass/State/NavigationState.swift`
- Modify: `MyPass/ContentView.swift`
- Modify: `MyPass/MyPassApp.swift`
- Test: `MyPassTests/NavigationStatePendingSaveProposalTests.swift`

**Interfaces:**
- Consumes: `ExtensionBridgeService.onSaveProposal` (Task 5), `ExtensionEntryMatcher.registrableDomain(from:)` (Task 4), `EntryEditView(existingEntry:onSave:)` (existing UI, `MyPass/UI/EntryDetail/EntryEditView.swift` — unmodified), `VaultSession.mutate(_:)` (existing), `NSApp` (AppKit).
- Produces:
```swift
struct PendingSaveProposal: Identifiable {
    let id = UUID()
    let url: String
    let username: String
    let password: String
    var registrableDomain: String { get }
}

final class NavigationState: ObservableObject {
    // ...existing published properties...
    @Published var pendingSaveProposal: PendingSaveProposal?
}
```
This is the payoff task for the `onSaveProposal` extension point Task 5 defined and Task 6/7 wired transport for: when the user confirms the "Save password to MyPass?" banner in Chrome, `MyPass.app` activates and shows a pre-filled create-entry form via the existing `EntryEditView`, reusing its "draft entry as `existingEntry`" mechanism rather than adding any new UI surface. Nothing in this plan consumes `PendingSaveProposal` further — it is the terminal UI hop that closes the save-new-login-via-extension MVP flow described in `docs/superpowers/specs/2026-07-25-mypass-phase4-chrome-extension-design.md `.

- [ ] **Step 1: Write the failing test**

Create `MyPassTests/NavigationStatePendingSaveProposalTests.swift`:

```swift
import XCTest
@testable import MyPass

final class NavigationStatePendingSaveProposalTests: XCTestCase {
    func testRegistrableDomainUsesParsedDomainForValidURL() {
        let proposal = PendingSaveProposal(url: "https://login.example.com/signup", username: "alice", password: "pw")
        XCTAssertEqual(proposal.registrableDomain, "example.com")
    }

    func testRegistrableDomainFallsBackToRawURLWhenUnparseable() {
        let proposal = PendingSaveProposal(url: "not a url $$$", username: "alice", password: "pw")
        XCTAssertEqual(proposal.registrableDomain, "not a url $$$")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/NavigationStatePendingSaveProposalTests`
Expected: FAIL — `PendingSaveProposal` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Modify `MyPass/State/NavigationState.swift` — current full content is 8 lines (`selectedGroupID `/` selectedEntryID `/` searchText` only); replace it with:

```swift
import Foundation

/// A save-login proposal relayed from `ExtensionBridgeService.onSaveProposal`
/// (Phase 4, Task 5/13), waiting to be shown as a pre-filled create-entry sheet
/// by `ContentView`. `Identifiable` so it can drive `.sheet(item:)` directly.
struct PendingSaveProposal: Identifiable {
    let id = UUID()
    let url: String
    let username: String
    let password: String

    /// Best-effort registrable domain for use as the draft entry's title —
    /// falls back to the raw URL when `ExtensionEntryMatcher` can't parse a
    /// host out of it (e.g. malformed or non-HTTP input from the extension).
    var registrableDomain: String {
        ExtensionEntryMatcher.registrableDomain(from: url) ?? url
    }
}

final class NavigationState: ObservableObject {
    @Published var selectedGroupID: UUID?
    @Published var selectedEntryID: UUID?
    @Published var searchText: String = ""
    @Published var pendingSaveProposal: PendingSaveProposal?
}
```

`ExtensionEntryMatcher` (Task 4) lives in the same `MyPass` target under `MyPass/State/ExtensionBridge/`, so no import is needed beyond `Foundation `.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/NavigationStatePendingSaveProposalTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Wire the sheet into `ContentView`**

This step is SwiftUI view-layer wiring, not independently unit-testable (same honest constraint already applied to `MyPassApp.init()` in Task 7) — it is verified manually in Step 7 below.

Modify `MyPass/ContentView.swift` — current content is 31 lines (`.locked `/`.unlocked` switch, `NavigationSplitView` with an existing `.alert(...)` modifier). Add a `.sheet(item:)` modifier immediately after the existing `.alert(...)`, and add a private `draftEntry(from:)` helper:

```swift
            NavigationSplitView {
                GroupSidebarView(rootGroup: database.rootGroup, recycleBinGroupUUID: database.recycleBinGroupUUID)
            } content: {
                EntryListView(rootGroup: database.rootGroup)
            } detail: {
                EntryDetailView()
            }
            .alert( /* lastSaveError alert — unchanged */ )
            .sheet(item: $navigationState.pendingSaveProposal) { proposal in
                EntryEditView(existingEntry: draftEntry(from: proposal)) { entry in
                    vaultSession.mutate { database in
                        database.rootGroup.entries.append(entry)
                    }
                    navigationState.pendingSaveProposal = nil
                }
            }
```

And add this private method to `ContentView`:

```swift
    private func draftEntry(from proposal: PendingSaveProposal) -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(), iconID: 0, fields: [],
            creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now,
            history: []
        )
        entry.title = proposal.registrableDomain
        entry.login = proposal.username
        entry.password = proposal.password
        entry.url = proposal.url
        return entry
    }
```

`EntryEditView` itself needs no changes: passing this freshly-`UUID()`'d, pre-populated `KdbxEntry` as `existingEntry` makes `EntryEditView`'s `init` seed its `@State` title/login/password/url from it (exactly like the existing "create entry" sheet in `EntryListView` passes `existingEntry: nil` — here we pass a non-nil draft instead), and `save()` uses that same draft as the base it mutates and hands to `onSave`, without checking whether the entry already exists in the vault tree.

One-line note on dismissal: only the `onSave` path above needs the explicit `navigationState.pendingSaveProposal = nil` — `.sheet(item:)`'s built-in dismiss-via-item-binding already sets `pendingSaveProposal` back to `nil` on Cancel or swipe-away, so no explicit handling is needed for those paths.

- [ ] **Step 6: Wire the real `onSaveProposal` closure in `MyPassApp.init()`**

Also not independently unit-testable — `NSApp` window activation requires a live app/window, verified manually in Step 7.

Task 7 already inserts the `extensionBridgeService `/` extensionBridgeServer` construction between `_vaultSession = StateObject(wrappedValue: session)` and `_navigationState = StateObject(wrappedValue: NavigationState())` in `MyPass/MyPassApp.swift `. Task 13 needs a named `navigationState` local so the closure below can capture it weakly (the existing `[weak session]` capture used for `backgroundSyncTimer` a few lines down is the same pattern already in this file) — replace:

```swift
_navigationState = StateObject(wrappedValue: NavigationState())
```

with:

```swift
let navigationState = NavigationState()
_navigationState = StateObject(wrappedValue: navigationState)

// Phase 4, Task 13: real UI for ExtensionBridgeService.onSaveProposal (Task 5's
// extension point). The dispatch to main is technically redundant here since
// LoopbackServer (Task 6) already dispatches onto the main thread before
// invoking the handler that eventually calls this closure — but the window
// activation calls below specifically need to run after SwiftUI has had a
// chance to process the `@Published pendingSaveProposal` change (so the sheet
// exists before we bring the window forward), so the async hop stays as
// defense-in-depth rather than being removed.
extensionBridgeService.onSaveProposal = { [weak navigationState] url, username, password in
    DispatchQueue.main.async {
        navigationState?.pendingSaveProposal = PendingSaveProposal(url: url, username: username, password: password)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.isVisible || $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 7: Manual verification (build + save-proposal smoke test)**

```bash
xcodegen generate
xcodebuild -project MyPass.xcodeproj -scheme MyPass build
```

Expected: build succeeds.

This flow can be exercised without a full Chrome round-trip by calling `ExtensionBridgeService.handle(_:)` directly with a `proposeSaveLogin` request — either from a throwaway XCTest or from the Xcode debugger while the app is running and stopped at a breakpoint:

1. Run `MyPass.app` from Xcode, unlock the vault, and let it run (don't stop at a breakpoint yet — the app needs to be live so `NSApp `/its window exist).
2. Pause execution (Xcode's pause button) and, in the debugger console, run:
   ```
   po AppDelegate.extensionBridgeServer
   ```
   to confirm the server (and therefore the wired `ExtensionBridgeService`) is alive. Since `ExtensionBridgeService` itself isn't retained on `AppDelegate`, the more direct check is behavioral: resume execution and drive the flow from the extension side.
3. Resume execution, then in Chrome (with the extension loaded per Task 12's checklist) submit a login form on the local test fixture (`ChromeExtension/tests/fixtures/login.html`, served per Task 12 Step 5) for a domain with no existing matching entry, exactly as in Task 12 checklist steps 10-11, and click "Save" on the banner (Task 12 checklist step 12).
4. Expected (this is what Task 12 checklist step 12 left unverified): `MyPass.app`'s window comes to the foreground (even if it was not the frontmost app, or was minimized/behind other windows), and a sheet appears on top of it showing `EntryEditView` with the title field pre-filled to the fixture's registrable domain (`localhost` when testing via the fixture, since `registrableDomain` falls back to the raw host when there's no real public suffix to strip), the login field pre-filled with the username typed into the form, the password field pre-filled with the password typed into the form, and the URL field pre-filled with the page's URL.
5. Click "Save" in `EntryEditView `. Expected: the sheet dismisses, and the new entry appears in the vault's entry list with the fields from step 4.
6. Repeat steps 3-4 but click "Cancel" (Cancel) in `EntryEditView` instead. Expected: the sheet dismisses, no new entry is created, and `navigationState.pendingSaveProposal` is `nil` again (confirmable via a temporary breakpoint on the `.sheet(item:)` closure, or simply by re-triggering the save-proposal flow and observing the form is blank/fresh rather than showing stale data).

- [ ] **Step 8: Commit**

```bash
git add MyPass/State/NavigationState.swift MyPass/ContentView.swift MyPass/MyPassApp.swift MyPassTests/NavigationStatePendingSaveProposalTests.swift
git commit -m "Phase 4, Task 13: save proposed login — window activation + pre-filled create-entry form"
```

Phase 4 (Chrome) completely closes the agreed MVP scope (autofilling existing logins + saving a new login through the extension) after passing this checklist.
