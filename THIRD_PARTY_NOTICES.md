# Third-party notices

MyPass itself is licensed under the Apache License 2.0 (see `LICENSE`). This file
lists the third-party code that the MyPass build artifacts contain, in source
or object form, together with the license notices those components require.

It is shipped next to `LICENSE` inside both development artifacts (the macOS
zip and the Chrome extension zip) and is part of the repository root.

**Scope.** The list covers what the artifacts actually contain:

- the macOS app `MyPass.app` and the `ChromeHost` helper: the code vendored in
  this repository, every Swift package that is linked into the app, and the
  Swift back-deployment runtime library that is copied into the app bundle;
- the Chrome extension: the single vendored script `vendor/jsQR.js`.

**How it was built.** Checked on 2026-10-26 against the pinned revisions in
`Packages/MyPassKit/Package.resolved` and `Packages/SyncKit/Package.resolved`
(`Packages/ExtensionBridgeKit` has no external dependency), against the
checkouts of exactly those revisions, and against the modules that a build of
`MyPass.app` really links. Test-only fixtures, build tooling and sources that
are resolved but not linked are not part of the artifacts and are listed
separately at the end. Texts below are copied verbatim from the upstream
files (only trailing whitespace is stripped); the checkouts were clean and
matched their pinned revisions.

**Maintenance.** Add or update an entry here in the same change that adds,
removes or bumps a dependency, or re-vendors a file (see `CONTRIBUTING.md`).
This file is a reviewed list, not machine-generated from `Package.resolved`.

## Summary

| Component | Version / revision | License | Goes into |
|---|---|---|---|
| jsQR | 1.4.0, `34d8eec` | Apache-2.0 | Chrome extension |
| phc-winner-argon2 (reference C code) | `62358ba`, tag `20190702` | Apache-2.0 (CC0-1.0 alternative, Apache-2.0 elected) | macOS app |
| Public Suffix List | `e8c9a2b`, list version 2026-08-19_19-18-48_UTC | MPL-2.0 | macOS app |
| Apple password-manager-resources (`quirks/password-rules.json`) | `6073487` | MIT | macOS app |
| swift-sodium | 0.11.0, `cfd195c` | ISC | macOS app |
| libsodium (bundled in swift-sodium) | 1.0.22 | ISC | macOS app |
| Citadel | 0.12.1, `ae8562f` | MIT | macOS app |
| Citadel `CCitadelBcrypt` (OpenBSD bcrypt / Blowfish) | bundled in Citadel 0.12.1 | ISC and BSD-style (with advertising clause) | macOS app |
| BigInt | 5.7.0, `e07e00f` | MIT | macOS app |
| swift-nio-ssh (Wellz26 fork) | 0.3.7, `d88989f` | Apache-2.0 | macOS app |
| swift-nio | 2.104.0, `6db9d9a` | Apache-2.0 (plus MIT and Apache-2.0 sub-components, see below) | macOS app |
| swift-crypto | 3.15.1, `95ba031` | Apache-2.0 | macOS app |
| BoringSSL (bundled in swift-crypto) | `0226f30` | Apache-2.0 | macOS app |
| fiat-crypto (inside BoringSSL) | as bundled by BoringSSL `0226f30` | Apache-2.0 | macOS app |
| swift-asn1 | 1.7.1, `a9a5efd` | Apache-2.0 | macOS app |
| swift-atomics | 1.3.1, `0442cb5` | Apache-2.0 with Runtime Library Exception | macOS app |
| swift-collections | 1.6.0, `a0cb095` | Apache-2.0 with Runtime Library Exception | macOS app |
| swift-log | 1.14.0, `a878e7f` | Apache-2.0 | macOS app |
| `libswiftCompatibilitySpan.dylib` (Swift back-deployment runtime, from the Xcode toolchain) | Swift runtime version 6.4.0 as recorded in the dylib | Apache-2.0 with Runtime Library Exception | macOS app (`MyPass.app/Contents/Frameworks/`) |

`MyPass.app` links, from swift-collections, only `ContainersPreview`,
`DequeModule` and `InternalCollectionsUtilities`; from swift-nio only the
`NIO`, `NIOCore`, `NIOPosix`, `NIOEmbedded`, `NIOConcurrencyHelpers`,
`NIOFoundationCompat`, `NIOFoundationEssentialsCompat`, `_NIOBase64`,
`_NIODataStructures` and `CNIO*` shim targets. Whole-package notices are
reproduced anyway because the license obligations attach to the package.

Apache-2.0 requires that recipients get a copy of the license and the content
of upstream `NOTICE` files. The Apache License 2.0 text appears once, in
[Appendix A](#appendix-a-apache-license-20), and applies to every component
marked Apache-2.0 above. The `LICENSE.txt` files of swift-crypto, swift-log,
swift-nio and swift-nio-ssh are byte-identical to that text; the one of
swift-asn1 differs only by one trailing newline; those of swift-atomics,
swift-collections and swift-system differ only in whitespace and append the
Runtime Library Exception (also the license of the Swift runtime library
listed in the table) reproduced in
[Appendix B](#appendix-b-swift-runtime-library-exception).

---

## Vendored in this repository

### jsQR 1.4.0

- Where: `ChromeExtension/vendor/jsQR.js` (Chrome extension).
- Upstream: https://github.com/cozmo/jsQR, commit
  `34d8eec1ec5d85496f3948ff02fcfe6406f89d81` ("1.4.0"). Also published on npm
  as `jsqr@1.4.0`.
- License: Apache License 2.0 (text in Appendix A). The bundle header reads
  "jsQR v1.4.0 — (c) Cosmo Wolfe, Apache License 2.0".
- Modification: none to the script. Its content is byte-identical to upstream
  `dist/jsQR.js` at the commit above, with one banner comment line prepended
  as the first line.
- Upstream has no `NOTICE` file. Its `LICENSE` is the unmodified Apache-2.0
  text with the appendix template left unfilled.

### phc-winner-argon2 (reference Argon2 implementation)

- Where: `Packages/MyPassKit/Sources/CArgon2/` (macOS app).
- Upstream: https://github.com/P-H-C/phc-winner-argon2, commit
  `62358ba2123abd17fccf2a108a301d4b52c01a7c` (tag `20190702`). Which files
  were taken is recorded in `Packages/MyPassKit/Sources/CArgon2/VENDORING.md`.
- License: dual CC0-1.0 / Apache License 2.0 at the user's option. MyPass uses
  the Apache-2.0 option (text in Appendix A). Upstream's own statement of
  this choice, copied from its `LICENSE` file:

~~~~text
Argon2 reference source code package - reference C implementations

Copyright 2015
Daniel Dinu, Dmitry Khovratovich, Jean-Philippe Aumasson, and Samuel Neves

You may use this work under the terms of a Creative Commons CC0 1.0
License/Waiver or the Apache Public License 2.0, at your option. The terms of
these licenses can be found at:

- CC0 1.0 Universal : http://creativecommons.org/publicdomain/zero/1.0
- Apache 2.0        : http://www.apache.org/licenses/LICENSE-2.0

~~~~

  The CC0 1.0 Universal text and Apache text as published by upstream are
  also kept verbatim in `Packages/MyPassKit/Sources/CArgon2/VENDORING.md`.
- Modification: none to the vendored `.c`/`.h` files (each is byte-identical
  to upstream at the commit above). Seven `blake2b*` symbols are renamed at
  compile time only, through `-D` defines in `Packages/MyPassKit/Package.swift`.
- Upstream has no `NOTICE` file.

### Public Suffix List

- Where: `Packages/MyPassKit/Sources/MyPassKit/Resources/public_suffix_list.dat`
  (macOS app resource bundle).
- Source form: https://publicsuffix.org/list/public_suffix_list.dat, built
  from https://github.com/publicsuffix/list at commit
  `e8c9a2b2b2856b6449999dd0ec0d118f364ed0cd`; list version
  `2026-08-19_19-18-48_UTC` (as stated in the file header).
- License: Mozilla Public License 2.0, reproduced in Appendix C. The file is
  shipped unmodified, as served by publicsuffix.org: it differs from the
  repository file at the commit above only by the three `VERSION`/`COMMIT`
  header lines that the publishing endpoint inserts. The source form of the
  covered file is the file itself, available at the links above.

### Apple password-manager-resources

- Where: `Packages/MyPassKit/Sources/MyPassKit/Resources/password-rules.json`
  (macOS app resource bundle). Provenance and regeneration:
  `Packages/MyPassKit/Sources/MyPassKit/Resources/PASSWORD_RULES_PROVENANCE.md`
  and `scripts/update-password-rules.sh`.
- Upstream: https://github.com/apple/password-manager-resources, file
  `quirks/password-rules.json`, commit
  `6073487115b722596d3e1826d1b71b524b73bac5`. The vendored file is
  byte-identical to upstream at that commit.
- License: MIT. Upstream `LICENSE.md` at that commit:

~~~~text
Copyright 2020 - 2026 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
~~~~

---

## Swift packages linked into the macOS app

All package sources were read at the pinned revisions. None of them is
modified by this project.

### swift-sodium 0.11.0 and libsodium 1.0.22

- swift-sodium: https://github.com/jedisct1/swift-sodium, tag `0.11.0`, commit
  `cfd195c76882aa9b997560ca7cb95d72fbf5db00`. License ISC; upstream `LICENSE`:

~~~~text
ISC License

Copyright (c) 2014-2026, Frank Denis <j at pureftpd dot org>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

~~~~

- libsodium is bundled in swift-sodium as a prebuilt static library
  (`Clibsodium.xcframework`); its header reports `SODIUM_VERSION_STRING`
  `"1.0.22"`. Upstream: https://github.com/jedisct1/libsodium, tag
  `1.0.22-RELEASE` (commit `77e1ce5d6dee871c49ef211222ba18ef0c486bda`). License
  ISC; upstream `LICENSE` at that tag:

~~~~text
/*
 * ISC License
 *
 * Copyright (c) 2013-2026
 * Frank Denis <j at pureftpd dot org>
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */
~~~~

- Neither swift-sodium nor libsodium ships a `NOTICE` file.

### Citadel 0.12.1

- Upstream: https://github.com/orlandos-nl/Citadel, tag `0.12.1`, commit
  `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`. License MIT; upstream `LICENSE`:

~~~~text
MIT License

Copyright (c) 2022 Orlandos

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
~~~~

- Citadel's `CCitadelBcrypt` target embeds OpenBSD code, each file under its
  own notice, reproduced here verbatim from the file headers:
  `bcrypt.c` (ISC), and `blf.c` / `blf.h` (BSD-style license that includes an
  advertising clause). `bcrypt-kdf.c` carries no license header of its own;
  it is part of the same target and is listed here for completeness.

`Sources/CCitadelBcrypt/bcrypt.c`:

~~~~text
/*    $OpenBSD: bcrypt.c,v 1.55 2015/09/13 15:33:48 guenther Exp $    */

/*
 * Copyright (c) 2014 Ted Unangst <tedu@openbsd.org>
 * Copyright (c) 1997 Niels Provos <provos@umich.edu>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */
~~~~

`Sources/CCitadelBcrypt/blf.c` (`blf.h` carries the same copyright holder and license terms, with a different one-line description and without the "Implementation advice" line):

~~~~text
/*    $OpenBSD: blf.c,v 1.7 2007/11/26 09:28:34 martynas Exp $    */

/*
 * Blowfish block cipher for OpenBSD
 * Copyright 1997 Niels Provos <provos@physnet.uni-hamburg.de>
 * All rights reserved.
 *
 * Implementation advice by David Mazieres <dm@lcs.mit.edu>.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. All advertising materials mentioning features or use of this software
 *    must display the following acknowledgement:
 *      This product includes software developed by Niels Provos.
 * 4. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * This code is derived from section 14.3 and the given source
 * in section V of Applied Cryptography, second edition.
 * Blowfish is an unpatented fast block cipher designed by
 * Bruce Schneier.
 */
~~~~

Acknowledgement required by clause 3 of that notice: *This product includes
software developed by Niels Provos.*

### BigInt 5.7.0

- Upstream: https://github.com/attaswift/BigInt, tag `v5.7.0`, commit
  `e07e00fa1fd435143a2dcf8b7eec9a7710b2fdfe`. License MIT; upstream
  `LICENSE.md`:

~~~~text

Copyright (c) 2016-2017 Károly Lőrentey

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
~~~~

### swift-nio-ssh 0.3.7 (Wellz26 fork)

- Dependency URL: https://github.com/Wellz26/swift-nio-ssh, tag `0.3.7`, commit
  `d88989f3d3bb1dfb2a38ce4af598afbf7fc3095c`. License Apache-2.0 (text in
  Appendix A; upstream `LICENSE.txt` is byte-identical to it). Source files
  carry "Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors".
  The repository has no `NOTICE` file.
- This is a fork, not Apple's `apple/swift-nio-ssh`. The fork describes itself
  as "A fork of Apple's NIOSSH, to be archived once Apple reviews and merges 2
  year old PRs". It is a fork of `Joannis/swift-nio-ssh` (default branch
  `citadel2`). Citadel 0.12.1, which SFTP sync needs, declares this same URL
  with the same `"0.3.4"..<"0.4.0"` range, so `Packages/SyncKit/Package.swift`
  names the same URL for SwiftPM to resolve a single `swift-nio-ssh`.
  Replacing the dependency is out of scope for this project today.

### swift-nio 2.104.0

- Upstream: https://github.com/apple/swift-nio, tag `2.104.0`, commit
  `6db9d9abd92ad7399b8a564cafbb87d3507245fa`. License Apache-2.0 (text in
  Appendix A; upstream `LICENSE.txt` is byte-identical to it).
- Upstream `NOTICE.txt`, required to be carried along by Apache-2.0 §4(d):

~~~~text

                            The SwiftNIO Project
                            ====================

Please visit the SwiftNIO web site for more information:

  * https://github.com/apple/swift-nio

Copyright 2017, 2018 The SwiftNIO Project

The SwiftNIO Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

-------------------------------------------------------------------------------

This product is heavily influenced by Netty.

  * LICENSE (Apache License 2.0):
    * https://github.com/netty/netty/blob/4.1/LICENSE.txt
  * HOMEPAGE:
    * https://netty.io

---

This product contains NodeJS's llhttp.

  * LICENSE (MIT):
    * https://github.com/nodejs/llhttp/blob/1e1c5b43326494e97cf8244ff57475eb72a1b62c/LICENSE-MIT
  * HOMEPAGE:
    * https://github.com/nodejs/llhttp

---

This product contains "cpp_magic.h" from Thomas Nixon & Jonathan Heathcote's uSHET

  * LICENSE (MIT):
    * https://github.com/18sg/uSHET/blob/c09e0acafd86720efe42dc15c63e0cc228244c32/lib/cpp_magic.h
  * HOMEPAGE:
    * https://github.com/18sg/uSHET

---

This product contains "sha1.c" and "sha1.h" from FreeBSD (Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project)

  * LICENSE (BSD-3):
    * https://opensource.org/licenses/BSD-3-Clause
  * HOMEPAGE:
    * https://github.com/freebsd/freebsd-src

---

This product contains a derivation of Fabian Fett's 'Base64.swift'.

  * LICENSE (Apache License 2.0):
    * https://github.com/swift-extras/swift-extras-base64/blob/b8af49699d59ad065b801715a5009619100245ca/LICENSE
  * HOMEPAGE:
    * https://github.com/fabianfett/swift-base64-kit

---

This product contains a derivation of "XCTest+AsyncAwait.swift" & "StructuredConcurrencyHelpers" from AsyncHTTPClient.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/swift-server/async-http-client

---

This product contains a derivation of "_TinyArray.swift" from SwiftCertificates.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-certificates

---

This product contains a derivation of the mocking infrastructure from Swift System.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-system

---

This product contains a derivation of "TokenBucket.swift" from Swift Package Manager.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/swiftlang/swift-package-manager
~~~~

Which of those components `MyPass.app` contains: the derivation of Fabian
Fett's `Base64.swift` (`_NIOBase64`) and `cpp_magic.h` (inside `CNIOAtomics`)
are linked. The llhttp sources (`CNIOLLHTTP`, used by `NIOHTTP1`) and the
FreeBSD `sha1.c` derivative (`CNIOSHA1`, used by `NIOWebSocket`) are not linked
into the app, and their licenses are not needed for it; they are described
under "Resolved but not linked". The other entries are Apache-2.0 derivations
covered by Appendix A.

`cpp_magic.h` is the MIT-licensed work of Thomas Nixon and Jonathan Heathcote
(uSHET, https://github.com/18sg/uSHET, commit
`c09e0acafd86720efe42dc15c63e0cc228244c32`, as named in the file header). Its
upstream license text:

~~~~text
uSHET Library
=============

Copyright (c) 2014 Thomas Nixon, Jonathan Heathcote

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
~~~~

### swift-crypto 3.15.1, with BoringSSL and fiat-crypto

- Upstream: https://github.com/apple/swift-crypto, tag `3.15.1`, commit
  `95ba0316a9b733e92bb6b071255ff46263bbe7dc`. License Apache-2.0 (text in
  Appendix A; upstream `LICENSE.txt` is byte-identical to it). The module
  `CCryptoBoringSSL` is linked into the app (it backs `Crypto` and `_CryptoExtras`, the latter used by Citadel).
- Upstream `NOTICE.txt`, required to be carried along by Apache-2.0 §4(d):

~~~~text
                            The SwiftCrypto Project
                            =======================

Please visit the SwiftCrypto web site for more information:

  * https://github.com/apple/swift-crypto

Copyright 2019 The SwiftCrypto Project

The SwiftCrypto Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

-------------------------------------------------------------------------------

This product contains test vectors from Google's wycheproof project.

  * LICENSE (Apache License 2.0):
    * https://github.com/C2SP/wycheproof/blob/31387e2cd596587c859c611027b6a44d2e2b65ff/LICENSE
  * HOMEPAGE:
    * https://github.com/google/wycheproof

---

This product contains a derivation of various files from SwiftNIO.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-nio
~~~~

  (The Wycheproof test vectors named there are used by swift-crypto's tests only
  and are not part of the linked product.)
- BoringSSL: `Sources/CCryptoBoringSSL` is derived from
  https://boringssl.googlesource.com/boringssl at revision
  `0226f30467f540a3f62ef48d453f93927da199b6` (recorded in swift-crypto's
  `Sources/CCryptoBoringSSL/hash.txt`). BoringSSL's top-level `LICENSE` at that
  revision is the Apache License 2.0 (text in Appendix A) followed by the
  Go-license text it says applies to TLS test-suite code that "is not included
  in BoringSSL (i.e. libcrypto and libssl) when compiled", so it does not
  apply to this product. BoringSSL has no `NOTICE` file at that revision. A few
  files in the bundled tree are marked public domain by their authors (for
  example parts of `curve25519`, `chacha`, `poly1305`, `p224-64`).
- fiat-crypto: BoringSSL's `third_party/fiat` is also bundled
  (`Sources/CCryptoBoringSSL/third_party/fiat`). Its upstream license file at
  the BoringSSL revision above is:

~~~~text
The Apache License, Version 2.0 (Apache-2.0)

Copyright 2015-2020 the fiat-crypto authors (see the AUTHORS file)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
~~~~

### swift-asn1 1.7.1

- Upstream: https://github.com/apple/swift-asn1, tag `1.7.1`, commit
  `a9a5efd40eaf558a2bcd48d64b1d1646be686008`. License Apache-2.0 (text in
  Appendix A; upstream `LICENSE.txt` differs from it by one trailing newline).
- Upstream `NOTICE.txt`:

~~~~text

                            The SwiftASN1 Project
                            =====================

Please visit the SwiftASN1 web site for more information:

  * https://github.com/apple/swift-asn1

Copyright 2022 The SwiftASN1 Project

The SwiftASN1 Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

---

This product contains derivations of various scripts from SwiftNIO.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-nio

---

This product contains derivations of various scripts from Swift OpenAPI Generator.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-openapi-generator
~~~~

### swift-atomics 1.3.1

- Upstream: https://github.com/apple/swift-atomics, tag `1.3.1`, commit
  `0442cb5a3f98ab802acb777929fdb446bda11a34`. License Apache-2.0 with the
  Runtime Library Exception (Appendix A and Appendix B). The repository has no
  `NOTICE` file.

### swift-collections 1.6.0

- Upstream: https://github.com/apple/swift-collections, tag `1.6.0`, commit
  `a0cb0954ecb21e4e31b0070e6ed5674e8556685a`. License Apache-2.0 with the
  Runtime Library Exception (Appendix A and Appendix B). The repository has no
  `NOTICE` file.

### swift-log 1.14.0

- Upstream: https://github.com/apple/swift-log, tag `1.14.0`, commit
  `a878e7f8f46cfc0e1125e565b5c08e7d5272dc9a`. License Apache-2.0 (text in
  Appendix A; upstream `LICENSE.txt` is byte-identical to it).
- Upstream `NOTICE.txt`:

~~~~text

                            The SwiftLog Project
                            ========================

Please visit the SwiftLog web site for more information:

  * https://github.com/apple/swift-log

Copyright 2018, 2019 The SwiftLog Project

The SwiftLog Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

-------------------------------------------------------------------------------

This product contains a derivation of the lock implementation and various
scripts from SwiftNIO.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-nio
~~~~

---

## Swift runtime library embedded in the macOS app

### libswiftCompatibilitySpan.dylib

- Where: `MyPass.app/Contents/Frameworks/libswiftCompatibilitySpan.dylib`, copied
  into the bundle by the Xcode build (the Swift standard library back-deployment
  step) from the installed Xcode toolchain, at
  `Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx/`. The `swift-6.2`
  directory name is the toolchain's back-deployment directory. The dylib itself
  records install name `/usr/lib/swift/libswiftCompatibilitySpan.dylib`, compatibility
  version 1.0.0 and current version 6.4.0, matching the Swift 6.4 compiler in the
  Xcode 27.0 toolchain used for the build. It carries Apple's code signature with
  identifier `com.apple.dt.runtime.swiftCompatibilitySpan`; it is not rebuilt or
  modified by MyPass.
- What it is: the back-deployment implementation of the Swift standard library
  `Span`, `RawSpan`, `MutableSpan`, `MutableRawSpan`, `OutputSpan` and
  `OutputRawSpan` types for macOS versions whose system Swift runtime lacks them.
  The app targets macOS 14.0, so the Swift build embeds it.
- Upstream source: https://github.com/swiftlang/swift, directory
  `stdlib/toolchain/CompatibilitySpan` (the dylib's debug strings name
  `CompatibilitySpan/FakeStdlib.swift`). Exact source revision: not recorded in
  the binary, so none is claimed here.
- License: Apache License 2.0 with the Runtime Library Exception, as published in
  the upstream repository's `LICENSE.txt`: Apache-2.0 text in Appendix A and the
  exception in Appendix B (the upstream exception wording is identical to the copy
  in Appendix B). Because the exception applies, redistributing this runtime
  library inside the app does not require the attribution that Sections 4(a), 4(b)
  and 4(d) would otherwise demand; it is listed here for transparency about what
  the bundle contains. The swiftlang/swift repository has no top-level `NOTICE.txt`,
  and no separate license file for this library was found in the Xcode toolchain.
- Architectures: the copy in the toolchain, and the one in the bundle, is a
  universal binary (x86_64, arm64, arm64e). The app and `ChromeHost` are built for
  arm64 only; the extra slices come from Apple's runtime library and are not
  used by the arm64 executables.

## Resolved but not linked into the artifacts

These are pinned or present in dependency checkouts but are not compiled into
`MyPass.app`, `ChromeHost` or the extension. They are listed so the
inventory stays honest, not because the artifacts need their notices.

- **swift-system 1.7.5**, `50688cacbd41d547e9eb9f7a213542340b7c442b`
  (https://github.com/apple/swift-system): Apache-2.0 with Runtime Library
  Exception (Appendices A and B), pinned in `Packages/SyncKit/Package.resolved`
  but no module of it is linked into the app. If a later build links it,
  nothing needs to change in this file beyond moving this entry.
- **llhttp** (MIT, "Copyright Fedor Indutny, 2018", used by swift-nio's
  `CNIOLLHTTP`/`NIOHTTP1`) and the **FreeBSD `sha1.c` derivative** (BSD-3-Clause,
  "Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project", swift-nio's
  `CNIOSHA1`/`NIOWebSocket`): present in the swift-nio source tree, not linked.
  If either module is ever linked, add its full upstream license text here
  first (llhttp: `Sources/CNIOLLHTTP/LICENSE` in swift-nio; sha1: file header of
  `Sources/CNIOSHA1/c_nio_sha1.c`).
- Citadel's example server, swift-nio-ssh's example executables, and the
  `ColorizeSwift` / `swift-docc-plugin` dependencies they would need: not
  resolved into `Package.resolved` and not linked.
- Test fixtures (for example `.kdbx` files and the TOTP QR image) and the
  extension's `tests/` directory are test-only data and are excluded from the
  artifacts.

---

## Appendix A: Apache License 2.0

Canonical text from https://www.apache.org/licenses/LICENSE-2.0.txt. The
appendix template at its end ("Copyright [yyyy] [name of copyright owner]") is
part of the standard text and is intentionally left unfilled.

~~~~text

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
~~~~

## Appendix B: Swift Runtime Library Exception

Appended by swift-atomics, swift-collections and swift-system to the Apache
License 2.0, copied from the end of their `LICENSE.txt` files (identical in all
three). The `LICENSE.txt` of https://github.com/swiftlang/swift, the source of
the embedded Swift runtime library, ends with the same exception:

~~~~text
## Runtime Library Exception to the Apache 2.0 License: ##


    As an exception, if you use this Software to compile your source code and
    portions of this Software are embedded into the binary product as a result,
    you may redistribute such product without providing attribution as would
    otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.
~~~~

## Appendix C: Mozilla Public License 2.0

Applies to the Public Suffix List. Copied from the `LICENSE` file of
https://github.com/publicsuffix/list at commit
`e8c9a2b2b2856b6449999dd0ec0d118f364ed0cd`.

~~~~text
Mozilla Public License Version 2.0
==================================

1. Definitions
--------------

1.1. "Contributor"
    means each individual or legal entity that creates, contributes to
    the creation of, or owns Covered Software.

1.2. "Contributor Version"
    means the combination of the Contributions of others (if any) used
    by a Contributor and that particular Contributor's Contribution.

1.3. "Contribution"
    means Covered Software of a particular Contributor.

1.4. "Covered Software"
    means Source Code Form to which the initial Contributor has attached
    the notice in Exhibit A, the Executable Form of such Source Code
    Form, and Modifications of such Source Code Form, in each case
    including portions thereof.

1.5. "Incompatible With Secondary Licenses"
    means

    (a) that the initial Contributor has attached the notice described
        in Exhibit B to the Covered Software; or

    (b) that the Covered Software was made available under the terms of
        version 1.1 or earlier of the License, but not also under the
        terms of a Secondary License.

1.6. "Executable Form"
    means any form of the work other than Source Code Form.

1.7. "Larger Work"
    means a work that combines Covered Software with other material, in
    a separate file or files, that is not Covered Software.

1.8. "License"
    means this document.

1.9. "Licensable"
    means having the right to grant, to the maximum extent possible,
    whether at the time of the initial grant or subsequently, any and
    all of the rights conveyed by this License.

1.10. "Modifications"
    means any of the following:

    (a) any file in Source Code Form that results from an addition to,
        deletion from, or modification of the contents of Covered
        Software; or

    (b) any new file in Source Code Form that contains any Covered
        Software.

1.11. "Patent Claims" of a Contributor
    means any patent claim(s), including without limitation, method,
    process, and apparatus claims, in any patent Licensable by such
    Contributor that would be infringed, but for the grant of the
    License, by the making, using, selling, offering for sale, having
    made, import, or transfer of either its Contributions or its
    Contributor Version.

1.12. "Secondary License"
    means either the GNU General Public License, Version 2.0, the GNU
    Lesser General Public License, Version 2.1, the GNU Affero General
    Public License, Version 3.0, or any later versions of those
    licenses.

1.13. "Source Code Form"
    means the form of the work preferred for making modifications.

1.14. "You" (or "Your")
    means an individual or a legal entity exercising rights under this
    License. For legal entities, "You" includes any entity that
    controls, is controlled by, or is under common control with You. For
    purposes of this definition, "control" means (a) the power, direct
    or indirect, to cause the direction or management of such entity,
    whether by contract or otherwise, or (b) ownership of more than
    fifty percent (50%) of the outstanding shares or beneficial
    ownership of such entity.

2. License Grants and Conditions
--------------------------------

2.1. Grants

Each Contributor hereby grants You a world-wide, royalty-free,
non-exclusive license:

(a) under intellectual property rights (other than patent or trademark)
    Licensable by such Contributor to use, reproduce, make available,
    modify, display, perform, distribute, and otherwise exploit its
    Contributions, either on an unmodified basis, with Modifications, or
    as part of a Larger Work; and

(b) under Patent Claims of such Contributor to make, use, sell, offer
    for sale, have made, import, and otherwise transfer either its
    Contributions or its Contributor Version.

2.2. Effective Date

The licenses granted in Section 2.1 with respect to any Contribution
become effective for each Contribution on the date the Contributor first
distributes such Contribution.

2.3. Limitations on Grant Scope

The licenses granted in this Section 2 are the only rights granted under
this License. No additional rights or licenses will be implied from the
distribution or licensing of Covered Software under this License.
Notwithstanding Section 2.1(b) above, no patent license is granted by a
Contributor:

(a) for any code that a Contributor has removed from Covered Software;
    or

(b) for infringements caused by: (i) Your and any other third party's
    modifications of Covered Software, or (ii) the combination of its
    Contributions with other software (except as part of its Contributor
    Version); or

(c) under Patent Claims infringed by Covered Software in the absence of
    its Contributions.

This License does not grant any rights in the trademarks, service marks,
or logos of any Contributor (except as may be necessary to comply with
the notice requirements in Section 3.4).

2.4. Subsequent Licenses

No Contributor makes additional grants as a result of Your choice to
distribute the Covered Software under a subsequent version of this
License (see Section 10.2) or under the terms of a Secondary License (if
permitted under the terms of Section 3.3).

2.5. Representation

Each Contributor represents that the Contributor believes its
Contributions are its original creation(s) or it has sufficient rights
to grant the rights to its Contributions conveyed by this License.

2.6. Fair Use

This License is not intended to limit any rights You have under
applicable copyright doctrines of fair use, fair dealing, or other
equivalents.

2.7. Conditions

Sections 3.1, 3.2, 3.3, and 3.4 are conditions of the licenses granted
in Section 2.1.

3. Responsibilities
-------------------

3.1. Distribution of Source Form

All distribution of Covered Software in Source Code Form, including any
Modifications that You create or to which You contribute, must be under
the terms of this License. You must inform recipients that the Source
Code Form of the Covered Software is governed by the terms of this
License, and how they can obtain a copy of this License. You may not
attempt to alter or restrict the recipients' rights in the Source Code
Form.

3.2. Distribution of Executable Form

If You distribute Covered Software in Executable Form then:

(a) such Covered Software must also be made available in Source Code
    Form, as described in Section 3.1, and You must inform recipients of
    the Executable Form how they can obtain a copy of such Source Code
    Form by reasonable means in a timely manner, at a charge no more
    than the cost of distribution to the recipient; and

(b) You may distribute such Executable Form under the terms of this
    License, or sublicense it under different terms, provided that the
    license for the Executable Form does not attempt to limit or alter
    the recipients' rights in the Source Code Form under this License.

3.3. Distribution of a Larger Work

You may create and distribute a Larger Work under terms of Your choice,
provided that You also comply with the requirements of this License for
the Covered Software. If the Larger Work is a combination of Covered
Software with a work governed by one or more Secondary Licenses, and the
Covered Software is not Incompatible With Secondary Licenses, this
License permits You to additionally distribute such Covered Software
under the terms of such Secondary License(s), so that the recipient of
the Larger Work may, at their option, further distribute the Covered
Software under the terms of either this License or such Secondary
License(s).

3.4. Notices

You may not remove or alter the substance of any license notices
(including copyright notices, patent notices, disclaimers of warranty,
or limitations of liability) contained within the Source Code Form of
the Covered Software, except that You may alter any license notices to
the extent required to remedy known factual inaccuracies.

3.5. Application of Additional Terms

You may choose to offer, and to charge a fee for, warranty, support,
indemnity or liability obligations to one or more recipients of Covered
Software. However, You may do so only on Your own behalf, and not on
behalf of any Contributor. You must make it absolutely clear that any
such warranty, support, indemnity, or liability obligation is offered by
You alone, and You hereby agree to indemnify every Contributor for any
liability incurred by such Contributor as a result of warranty, support,
indemnity or liability terms You offer. You may include additional
disclaimers of warranty and limitations of liability specific to any
jurisdiction.

4. Inability to Comply Due to Statute or Regulation
---------------------------------------------------

If it is impossible for You to comply with any of the terms of this
License with respect to some or all of the Covered Software due to
statute, judicial order, or regulation then You must: (a) comply with
the terms of this License to the maximum extent possible; and (b)
describe the limitations and the code they affect. Such description must
be placed in a text file included with all distributions of the Covered
Software under this License. Except to the extent prohibited by statute
or regulation, such description must be sufficiently detailed for a
recipient of ordinary skill to be able to understand it.

5. Termination
--------------

5.1. The rights granted under this License will terminate automatically
if You fail to comply with any of its terms. However, if You become
compliant, then the rights granted under this License from a particular
Contributor are reinstated (a) provisionally, unless and until such
Contributor explicitly and finally terminates Your grants, and (b) on an
ongoing basis, if such Contributor fails to notify You of the
non-compliance by some reasonable means prior to 60 days after You have
come back into compliance. Moreover, Your grants from a particular
Contributor are reinstated on an ongoing basis if such Contributor
notifies You of the non-compliance by some reasonable means, this is the
first time You have received notice of non-compliance with this License
from such Contributor, and You become compliant prior to 30 days after
Your receipt of the notice.

5.2. If You initiate litigation against any entity by asserting a patent
infringement claim (excluding declaratory judgment actions,
counter-claims, and cross-claims) alleging that a Contributor Version
directly or indirectly infringes any patent, then the rights granted to
You by any and all Contributors for the Covered Software under Section
2.1 of this License shall terminate.

5.3. In the event of termination under Sections 5.1 or 5.2 above, all
end user license agreements (excluding distributors and resellers) which
have been validly granted by You or Your distributors under this License
prior to termination shall survive termination.

************************************************************************
*                                                                      *
*  6. Disclaimer of Warranty                                           *
*  -------------------------                                           *
*                                                                      *
*  Covered Software is provided under this License on an "as is"       *
*  basis, without warranty of any kind, either expressed, implied, or  *
*  statutory, including, without limitation, warranties that the       *
*  Covered Software is free of defects, merchantable, fit for a        *
*  particular purpose or non-infringing. The entire risk as to the     *
*  quality and performance of the Covered Software is with You.        *
*  Should any Covered Software prove defective in any respect, You     *
*  (not any Contributor) assume the cost of any necessary servicing,   *
*  repair, or correction. This disclaimer of warranty constitutes an   *
*  essential part of this License. No use of any Covered Software is   *
*  authorized under this License except under this disclaimer.         *
*                                                                      *
************************************************************************

************************************************************************
*                                                                      *
*  7. Limitation of Liability                                          *
*  --------------------------                                          *
*                                                                      *
*  Under no circumstances and under no legal theory, whether tort      *
*  (including negligence), contract, or otherwise, shall any           *
*  Contributor, or anyone who distributes Covered Software as          *
*  permitted above, be liable to You for any direct, indirect,         *
*  special, incidental, or consequential damages of any character      *
*  including, without limitation, damages for lost profits, loss of    *
*  goodwill, work stoppage, computer failure or malfunction, or any    *
*  and all other commercial damages or losses, even if such party      *
*  shall have been informed of the possibility of such damages. This   *
*  limitation of liability shall not apply to liability for death or   *
*  personal injury resulting from such party's negligence to the       *
*  extent applicable law prohibits such limitation. Some               *
*  jurisdictions do not allow the exclusion or limitation of           *
*  incidental or consequential damages, so this exclusion and          *
*  limitation may not apply to You.                                    *
*                                                                      *
************************************************************************

8. Litigation
-------------

Any litigation relating to this License may be brought only in the
courts of a jurisdiction where the defendant maintains its principal
place of business and such litigation shall be governed by laws of that
jurisdiction, without reference to its conflict-of-law provisions.
Nothing in this Section shall prevent a party's ability to bring
cross-claims or counter-claims.

9. Miscellaneous
----------------

This License represents the complete agreement concerning the subject
matter hereof. If any provision of this License is held to be
unenforceable, such provision shall be reformed only to the extent
necessary to make it enforceable. Any law or regulation which provides
that the language of a contract shall be construed against the drafter
shall not be used to construe this License against a Contributor.

10. Versions of the License
---------------------------

10.1. New Versions

Mozilla Foundation is the license steward. Except as provided in Section
10.3, no one other than the license steward has the right to modify or
publish new versions of this License. Each version will be given a
distinguishing version number.

10.2. Effect of New Versions

You may distribute the Covered Software under the terms of the version
of the License under which You originally received the Covered Software,
or under the terms of any subsequent version published by the license
steward.

10.3. Modified Versions

If you create software not governed by this License, and you want to
create a new license for such software, you may create and use a
modified version of this License if you rename the license and remove
any references to the name of the license steward (except to note that
such modified license differs from this License).

10.4. Distributing Source Code Form that is Incompatible With Secondary
Licenses

If You choose to distribute Source Code Form that is Incompatible With
Secondary Licenses under the terms of this version of the License, the
notice described in Exhibit B of this License must be attached.

Exhibit A - Source Code Form License Notice
-------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at https://mozilla.org/MPL/2.0/.

If it is not possible or desirable to put the notice in a particular
file, then You may include the notice in a location (such as a LICENSE
file in a relevant directory) where a recipient would be likely to look
for such a notice.

You may add additional accurate notices of copyright ownership.

Exhibit B - "Incompatible With Secondary Licenses" Notice
---------------------------------------------------------

  This Source Code Form is "Incompatible With Secondary Licenses", as
  defined by the Mozilla Public License, v. 2.0.
~~~~
