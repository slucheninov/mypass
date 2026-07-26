# Decision: KeePassKit vs Custom KDBX4 Parser

Date: 2026-07-21

## Reference Files

Location: `/tmp/mypass-spike/reference-kdbx/` (temporary, not committed; if
"custom-parser" is chosen, the final set is copied to
`Packages/MyPassKit/Tests/MyPassKitTests/Fixtures/` in Task 16).

5 files generated via `pykeepass` (Python, installed via
`pip3 install --user pycryptodome argon2-cffi pykeepass`, because
`keepassxc-cli`/KeePassXC GUI were not available in the environment and `brew install --cask
keepassxc` requires installation permission that was not granted —
see "Deviations from Plan" below). Password for all generated files:
`TestMasterPass123`. 1 file — real reference from the KeePassXC
repository (`tests/data/Format400.kdbx`, password `t`).

Regeneration script (if fixtures are needed again):
```bash
pip3 install --user pycryptodome argon2-cffi pykeepass
python3 - <<'PYEOF'
from pykeepass import create_database, PyKeePass
from pykeepass.kdbx_parsing import kdf_uuids
from construct import Container
import os

PASSWORD = "TestMasterPass123"
OUT = "/tmp/mypass-spike/reference-kdbx"
os.makedirs(OUT, exist_ok=True)

def make(name, cipher=None, kdf_uuid=None, compression=None, edits=0, delete=False):
    path = f"{OUT}/{name}"
    kp = create_database(path, password=PASSWORD)
    dh = kp.kdbx.header.value.dynamic_header
    mutated = False
    if cipher:
        dh.cipher_id.data = cipher
        dh.encryption_iv.data = os.urandom(12 if cipher == "chacha20" else 16)
        mutated = True
    if kdf_uuid:
        d = dh.kdf_parameters.data.dict
        d['$UUID'].value = kdf_uuids[kdf_uuid]
        if kdf_uuid == "aeskdf":
            d['V'].next_byte = 5  # fix linked-list chain to new last item
            d['R'] = Container(type=5, key='R', value=60000, next_byte=0)
        mutated = True
    if compression is not None:
        dh.compression_flags.data.compression = compression
        mutated = True
    if mutated:
        del kp.kdbx.header['data']  # force RawCopy to rebuild header bytes from mutated tree
    entry = kp.add_entry(kp.root_group, "Test Entry", "testuser", "hunter2")
    if edits:
        for i in range(edits):
            entry.password = f"hunter2-rev{i+1}"
            entry.save_history()
    if delete:
        kp.delete_entry(entry)
    kp.save()

make("argon2id-aes256-gzip.kdbx", cipher="aes256", kdf_uuid="argon2id", compression=True)
make("chacha20-argon2id-gzip.kdbx", cipher="chacha20", kdf_uuid="argon2id", compression=True)
make("aeskdf-aes256-none.kdbx", cipher="aes256", kdf_uuid="aeskdf", compression=False)
make("argon2d-aes256-gzip-history.kdbx", edits=2)
make("argon2d-aes256-gzip-deleted.kdbx", delete=True)
PYEOF
```
(The second file, `argon2d-aes256-gzip-deleted.kdbx`, additionally requires manual
insertion of `<DeletedObject>` in XML via lxml, because `pykeepass.delete_entry()` does not
write a deletion record to `<DeletedObjects>` — see the
"Deviations from Plan" section.)

Also copied a real file:
```bash
cp /tmp/mypass-spike/keepassxc-src/tests/data/Format400.kdbx \
   /tmp/mypass-spike/reference-kdbx/keepassxc-format400-twofish-argon2d-gzip.kdbx
```

## Results per Reference File

Each file opened via `KPKTree(data:key:)` (KeePassKit, Swift executable,
built with `swiftc` directly against built `KeePassKit.framework`
+ `KissXML.framework`).

| File | KDF | Cipher | Compression | KeePassKit | Comment |
|---|---|---|---|---|---|
| `argon2id-aes256-gzip.kdbx` | Argon2id | AES256 | GZip | ✅ opened | 1 entry, 0 history, 0 deleted |
| `chacha20-argon2id-gzip.kdbx` | Argon2id | ChaCha20 | GZip | ✅ opened | 1 entry, 0 history, 0 deleted |
| `aeskdf-aes256-none.kdbx` | AES-KDF | AES256 | None | ✅ opened | 1 entry, 0 history, 0 deleted |
| `argon2d-aes256-gzip-history.kdbx` | Argon2d | AES256 | GZip | ✅ opened | 1 entry, **2 history entries** read correctly (`tree.allHistoryEntries.count == 2`) |
| `argon2d-aes256-gzip-deleted.kdbx` | Argon2d | AES256 | GZip | ✅ opened | 0 entries (deleted), **1 DeletedObject** read correctly (`tree.deletedObjects.count == 1`) |
| `keepassxc-format400-twofish-argon2d-gzip.kdbx` (real KeePassXC file, password `t`) | Argon2d | TwoFish | GZip | ✅ opened | 1 entry; `deletedObjects.count == 10` (internal test artifacts from the KeePassXC file itself) |

Summary: **KeePassKit successfully opened and decrypted all 6 reference files**,
including all required KDF/cipher/compression combinations, History and DeletedObjects.
Technically, integration fully succeeded.

## Decision

**custom-parser**

## Rationale

KeePassKit works technically: it builds under current Xcode 26.6 (after
adding the missing KissXML dependency — fork `MacPass/KissXML`, which has
Package.swift, but KeePassKit itself has no native SPM
support, only Carthage/CocoaPods) and correctly decrypts all 6 reference
files, including Argon2id/ChaCha20/AES-KDF, History and DeletedObjects.

However, **KeePassKit is distributed under GPLv3** (`LICENSE`, `KeePassKit.podspec:
s.license = "GPLv3"`), with no linking exception and no alternative
(LGPL/MIT/commercial) license. For a closed commercial macOS product
MyPass this means the obligation to license the entire linked
binary under GPLv3 when distributing — an unacceptable constraint for
the project if MyPass is not intended as an open-source GPL product. This is a
blocking factor unrelated to the library's technical quality, and it
outweighs the successful technical integration result.

Additionally: lack of native SPM support (requires bridging via
XCFramework/Carthage/CocoaPods plus an additional transitive GPL/BSD
KissXML dependency) adds ongoing build infrastructure overhead
even without considering the license.

## If custom-parser:
Continue executing tasks 2+ of the plan
`docs/superpowers/plans/2026-07-21-mypass-mypasskit-core.md` as-is.

## If keepasskit-wrapper:
Not applicable — not chosen. (Technically KeePassKit passed verification successfully;
the only reason for rejection — GPLv3 license, incompatible with closed
commercial distribution of MyPass. If this constraint is revisited in the future
— e.g. MyPass becomes open-source, or a commercial license/exception is purchased from HicknHack Software
— this plan item can be revisited, relying on the integration results above.)

## Deviations from Plan / Spike Technical Details

- **`brew install --cask keepassxc` not run**: the command was blocked by
  environment execution policy (permission denied for installation via
  Homebrew cask). Instead of KeePassXC GUI/CLI for generating reference files,
  `pykeepass` was used (Python library, `pip3 install --user`), which
  parses/builds KDBX4 via its own construct-based codec — a valid
  alternative for obtaining real, correctly encrypted `.kdbx4` files.
- **Real fixtures from the KeePassXC repository** (`tests/data/*.kdbx`,
  sparse-checkout cloned `tests/` from
  `https://github.com/keepassxreboot/keepassxc.git`) yielded only one
  usable file in KDBX4 format without keyfile/YubiKey requirements:
  `Format400.kdbx` (TwoFish + Argon2d + GZip, password `t`). Other
  KDBX4 files in the repository (`KeyFileProtected.kdbx`,
  `KeyFileProtectedNoPassword.kdbx`, `YubiKeyProtectedPasswords.kdbx`,
  `NewDatabaseBrowser.kdbx`) require keyfile/YubiKey challenge-response and do not
  cover the needed KDF/cipher combinations with password only.
- **Bug in `pykeepass` when generating custom KDF/cipher combinations**: when
  mutating `dh.kdf_parameters.data.dict['$UUID'].value` (changing KDF to
  Argon2id/AES-KDF) without additional steps, the saved file
  decrypted with a key computed from **old** parameters (mismatch
  with what was actually written to the file header) — because the top-level
  `header` field in `pykeepass.kdbx_parsing.kdbx.KDBX` is wrapped in `construct.RawCopy`,
  which on build uses cached raw `data` bytes if the
  `data` key is present in the object, completely ignoring changes to `value`.
  Fix: `del kp.kdbx.header['data']` before `.save()` — then `RawCopy`
  is forced to rebuild bytes from the mutated `.value` tree.
- **Second bug**: when adding a new key to the variant dictionary (field `R`
  for AES-KDF) all elements of that dictionary are built via
  `construct.RepeatUntil`, using the same predicate
  (`item.next_byte == 0x00`) for both parsing and building. If ALL
  elements have `next_byte=0`, build stops after the first element.
  The list must be explicitly relinked: the element that was last before
  adding the new one must have `next_byte` pointing to the new last element's `type` byte, and the new last — `next_byte=0`.
- **`pykeepass.delete_entry()` does not write `<DeletedObjects>`**: for file
  `argon2d-aes256-gzip-deleted.kdbx` the deletion record was added manually —
  direct manipulation of the `lxml` tree (`kp.tree.getroot()`) inserting
  `<DeletedObject><UUID>...</UUID><DeletionTime>...</DeletionTime></DeletedObject>`
  before `kp.save()`.
- **KeePassKit build**: built `xcodebuild -scheme "KeePassKit macOS"` from
  a clean clone (`git clone --depth 1 --recurse-submodules
  https://github.com/MacPass/KeePassKit.git`, commit from 2026-11-13, i.e.
  the library is actively maintained). First build attempt failed
  (`'KissXML/KissXML.h' file not found`) — missing KissXML dependency not
  vendored in the repository and not listed as a submodule, only via
  Cartfile/Podfile. Built separately (`git clone
  https://github.com/MacPass/KissXML.git`, `xcodebuild -scheme "KissXML
  (macOS)"`) and linked via `FRAMEWORK_SEARCH_PATHS`. After that,
  `KeePassKit macOS` build succeeded (`** BUILD SUCCEEDED **`).
- **Spike tool**: `/tmp/mypass-spike/KeePassKitSpike/SpikeTool/main.swift`
  — one-off Swift executable, built directly with `swiftc -F
  <DerivedData>/Build/Products/Debug` (without a full Xcode project),
  using `import KeePassKit` (framework module) and
  `KPKTree(data:key:)` / `KPKCompositeKey(keys: [KPKPasswordKey(password:)])`.
  Directories `/tmp/mypass-spike/KeePassKitSpike/` (KeePassKit, KissXML clones,
  DerivedData, spike tool) — one-off, not committed and subject to
  deletion.
