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
- [ ] Produce and verify the release ZIP SHA-256 checksum.
- [ ] Sign and notarize the distribution artifact with the release credentials outside this repository.

## Publication

- [ ] Create the GitHub Release manually.
- [ ] Attach the release ZIP and its SHA-256 checksum.
- [ ] Publish concise release notes describing user-visible changes and known limitations.
