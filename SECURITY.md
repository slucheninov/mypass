# Security policy

## Reporting a vulnerability

Please do not open a public issue, pull request or discussion for a security
vulnerability, and do not post exploit details anywhere public.

Use the repository's private reporting page: open the **Security** tab and choose
**Report a vulnerability** (direct link:
<https://github.com/slucheninov/mypass/security/advisories/new>). That creates a
private advisory visible only to you and the maintainers.

If the **Report a vulnerability** button is not offered, open a public issue that says
only that you have a security report and asks for a private way to send it. Put no
technical details, proof of concept or affected component in that issue. No other
contact address is offered.

Please include:

- which component is affected (macOS app, `ChromeHost`, browser extension, sync
  backend) and the version or commit;
- how you built or installed it (locally built and signed, or an unsigned development
  artifact);
- steps to reproduce, and what an attacker gains;
- any proof of concept, using a throwaway vault with fake data. Never send real
  passwords, real vault files or key material.

For anything that is not a vulnerability (questions, ideas, ordinary bugs), use the
public [issue templates](https://github.com/slucheninov/mypass/issues/new/choose).

## Supported versions

MyPass is pre-release software. Only the latest tagged release and the current
`master` branch are supported; fixes are made on `master` and are not backported to
older releases.

## Scope and known limitations

In scope: the macOS app, the `ChromeHost` native messaging host, the browser
extension, the loopback bridge between them, the pairing flow, KDBX4 handling and the
sync backends.

No independent third-party security audit of MyPass is published or claimed. Review and
testing by the maintainers and their tooling, including AI-assisted code review, is not
an independent audit, and nothing in this repository should be read as a security
guarantee.

The macOS app disk images published on GitHub Releases so far and the development
artifacts built by `scripts/dev.sh package` and CI are unsigned, ad-hoc-sealed and not
notarized (`.github/workflows/release.yml` builds releases the same way as CI). They
carry no signing identity and none of the app's entitlements, so Touch ID unlock and the
Keychain-backed token exchange between the app and `ChromeHost` are expected to be
limited or non-functional (this has not been tested). They are not a supported way to
run a real vault. Reports that only describe those expected limitations are not
vulnerabilities; reports of a way to read vault contents or tokens from a correctly
signed local build are.

Vulnerabilities in third-party dependencies (listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)) should be reported upstream as
well; tell us if MyPass is affected in a way the upstream project would not expect.

## Disclosure

Please give us a reasonable chance to fix a reported issue before you disclose it.
Once a fix is available we will publish a GitHub security advisory that credits you,
unless you prefer to stay anonymous. No response-time guarantee is made.
