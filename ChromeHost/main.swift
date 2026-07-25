import Foundation

FileHandle.standardError.write(Data("ChromeHost started\n".utf8))

Relay.run()
