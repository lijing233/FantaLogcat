# Release Checklist

Complete every item from a clean checkout of the intended release commit.

## Validation

- [ ] Run `make generate` and confirm the generated project is current.
- [ ] Run `make test`, including the unit and UI test suites.
- [ ] Test a real Android device over USB, including the authorization flow.
- [ ] Test a real Android device using Wireless debugging, including reconnect behavior.
- [ ] Verify selected-process capture for Unity exception and ANR scenarios.
- [ ] Run a long capture session and inspect memory behavior.
- [ ] Inspect filtered and all-captured exports with redaction on and off; confirm the redaction warning remains accurate and manually inspect the output for sensitive data.

## Public artifact hygiene

- [ ] Confirm `Config/TeamConfig.json` is absent from the checkout, generated project, build output, and release artifact.
- [ ] Scan public artifacts for private configuration, credentials, logs, and unintended files.
- [ ] Run `make release`.
- [ ] Verify the packaged app is arm64 and that code-signature structure verifies.
- [ ] Run `make test-launch` against the packaged app and confirm it remains alive through startup.
- [ ] Open the DMG and verify that it contains `FantaLogcat.app` and an `Applications` shortcut.
- [ ] Produce and verify the release ZIP and DMG SHA-256 checksums.
- [ ] Run `make appcast`, verify the appcast version and EdDSA signature, and confirm the private key is not tracked.
- [ ] Test an installed previous Sparkle-enabled version updating to the release candidate.
- [ ] Sign and notarize the distribution artifact with the release credentials outside this repository.

## Publication

- [ ] Create the GitHub Release manually.
- [ ] Attach the release DMG and its SHA-256 checksum as the recommended download.
- [ ] Attach the release ZIP and its SHA-256 checksum as the portable alternative.
- [ ] Publish `docs/appcast.xml` and verify its enclosure URL resolves to the uploaded ZIP.
- [ ] Publish concise release notes describing user-visible changes and known limitations.
