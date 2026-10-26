## Install

This is an unsigned, un-notarized development-grade build for Apple Silicon (macOS 14 or later). Read the warning in `INSTALL.txt` inside the disk image before using it with a real vault.

1. Download `MyPass-{{VERSION}}-macos-arm64.dmg` and `MyPass-chrome-extension-{{VERSION}}.zip`.
2. Clear the quarantine flag on the disk image before opening it: `xattr -d com.apple.quarantine ~/Downloads/MyPass-{{VERSION}}-macos-arm64.dmg`
3. Open it, drag `MyPass.app` onto `Applications`, then follow `INSTALL.txt` for the browser host (`dev.sh install-host`) and the extension (load the zip unpacked).

Check the downloads against `SHA256SUMS.txt` with `shasum -a 256 -c SHA256SUMS.txt`.

## What changed

