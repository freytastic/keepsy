# Contributing to Miuchio

Thank you for wanting to help. Miuchio is built by one person, so this page explains what is easiest for me to review and what needs a conversation first.

I am open to changes to the design, theme, UI and UX, and to ideas for new features. New features can take a while, because I spend most of my time on the protocol.

Start with the [website](https://www.miuchio.com) for the design and reasoning behind Miuchio, and ask if anything is unclear.

## Before you start

- **Bugs and small fixes:** open a pull request directly. A short description of the problem and how you checked the fix is enough.
- **Anything bigger:** open an issue first so we can agree on the approach before you spend time on code. This includes new features, new dependencies and changes to how an existing screen behaves.
- **Protocol and cryptography changes:** always open an issue first. Anything that changes key handling, signatures, wire formats, what the server stores or what it checks needs the design agreed before any code. The [protocol pages](https://www.miuchio.com/protocol/overview) describe the current design.
- **Serious security or protocol bugs:** reach out to me first. [SECURITY.md](SECURITY.md) lists how.
- **Questions:** Signal (`freya.47`) or Discord (`freytastic`) are the fastest ways to reach me. Email ([uExistentialist@proton.me](mailto:uExistentialist@proton.me)) can take a while.

## Setting up

Follow [Running locally](README.md#running-locally) in the README to start the server and the app.

## Checking your change

There is no CI yet, so please run these yourself before opening a pull request:

```bash
cd server
go vet ./...
go test ./...

cd ../client
flutter analyze
flutter test
```

`flutter test` must run from `client/`, because the cross-language tests read `../test_vectors/crypto_kat.json`.

Some server tests need a real Postgres and Redis and skip themselves without them. They cover locking, races and replay, so run them if you touch the server's repositories, epochs, invites or prekeys. See [Tests](README.md#tests) for how.

## Rules for the code

- **Known answer test vectors are frozen.** `test_vectors/crypto_kat.json` and `server/test_vectors/` pin the exact bytes that the Dart app and the Go server must both produce. Never regenerate or edit a vector to make a test pass. A vector that disagrees with your change means the change broke compatibility.
- **Fail closed.** When a check about keys, signatures, epochs or photo metadata cannot be completed, refuse instead of continuing with less protection.
- **Add tests** for new behaviour, especially security checks, failure paths and races.
- **Comments** explain why, not what. Keep them short, and only where the code is not obvious.
- **Match the surrounding code** in naming and structure rather than introducing a new style.

## Commits and pull requests

Commit messages follow `type(scope): short description` with a one word scope, for example:

```
fix(onboarding): choose a lighter animation on slower phones
feat(viewer): add swipe navigation, zoom and shared photo sheets
```

Common types are `feat`, `fix`, `perf`, `refactor`, `test` and `chore`. Keep one change per pull request where you can.

## License

Miuchio is licensed under the [GNU AGPL v3](LICENSE). By contributing, you agree that your contribution is licensed under the same terms.
