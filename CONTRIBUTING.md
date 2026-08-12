# Contributing to FantaLogcat

Thanks for improving FantaLogcat. Please open an issue before large changes so the maintainers and contributors can agree on scope.

## Development environment

- Xcode 26.6
- Mint 0.18.0
- XcodeGen 2.46.0
- Swift 6 language mode
- macOS 13+ on Apple silicon

Install the pinned tooling, then generate and test the project:

```sh
make generate
make test
```

Use `make build` for a Release build and `make release` to package the local arm64 release artifact.

## Changes and tests

Use test-driven development for behavioral changes: add a focused failing test, make the smallest change that passes it, then refactor while the test suite remains green. Run `make test` before opening a pull request. Include or update unit and UI tests when the change affects them.

Keep pull requests focused. Explain the user-facing behavior, privacy implications, and how you tested the change. Attach screenshots for visible UI changes.

## Private configuration

Never commit `Config/TeamConfig.json`. It is private team configuration and must not appear in source, build outputs, release artifacts, issues, pull requests, or screenshots.

## Conduct and security

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security vulnerabilities through the process in [SECURITY.md](SECURITY.md), not in public issues.
