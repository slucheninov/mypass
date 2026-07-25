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
    do {
        let frames = try reader.feed(chunk)
        for frame in frames {
            // Scaffolding only: echo the raw frame back framed, unchanged, so the
            // stdio loop itself can be smoke-tested before Task 9 replaces this
            // body with the real stdio<->TCP relay.
            stdout.write(NativeMessagingCodec.encode(frame))
        }
    } catch {
        // Scaffolding only: a claimed frame length exceeded the reader's cap,
        // which means the byte stream can no longer be trusted to be
        // frame-aligned (per NativeMessagingFrameReader.feed's documented
        // contract). Rather than silently continuing on desynced bytes, stop
        // the loop here; Task 9's real relay will need proper error reporting
        // back to Chrome/MyPass.app instead of just exiting.
        FileHandle.standardError.write(Data("ChromeHost: frame read error: \(error)\n".utf8))
        break
    }
}
