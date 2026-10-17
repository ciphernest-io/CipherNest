# Contributing

Thanks for looking. Issues and pull requests are welcome. This page covers what you need to know before opening either.

## Licence and sign-off

CipherNest is licensed under GPL-3.0-or-later. By submitting a contribution you agree that it is licensed under the same terms.

Every commit must carry a Developer Certificate of Origin sign-off, which states that you wrote the change or otherwise have the right to submit it under the project licence:

```
git commit -s
```

That adds a `Signed-off-by: Your Name <you@example.com>` line. Pull requests with unsigned commits will be asked to add it. The full text of the certificate is at https://developercertificate.org.

The CipherNest name and logo are not covered by the licence. The maintainer retains all rights in their own code, including the right to offer it under other terms.

## Before you start

**Open an issue first** for anything that changes:

- a file format, a chunk layout or an authenticated-data binding;
- a key derivation, an HKDF label or a KDF parameter;
- the layout of any stored blob, preference key or database column that holds vault state;
- the share-link URL format or the Worker's API.

These are frozen once a real vault exists. Changing one without a migration orphans user data, and a migration needs discussion before code.

**Security issues are not issues.** If you found a vulnerability, follow [SECURITY.md](SECURITY.md) and do not open a public issue or pull request for it.

## Setting up

The app is in `frontend/`. Requirements are in the [README](README.md#building-from-source).

```
cd frontend
flutter pub get
flutter analyze
flutter test
```

`flutter test` runs the whole suite. The cryptography tests live in `frontend/test/crypto/`: HPKE against the RFC 9180 Appendix A.1 vectors, the chunk format, key derivation, sealed metadata, the share path, and the password and passwordless vault flows. Run just those with:

```
flutter test test/crypto
```

A release build needs `--no-tree-shake-icons`; see the README.

## What a good pull request looks like

- One change per pull request, with a short description of what it does and why.
- Tests for anything that touches encryption, key handling, storage layout or the share path. A change there without a test will be sent back.
- `flutter analyze` clean and `flutter test` green.
- No new third-party UI packages. The interface is built from plain Flutter widgets on purpose; see the design notes in the code before adding a dependency.
- No dependency added without a line in the description saying what it is for and what licence it carries. Regenerate `THIRD_PARTY_LICENSES.md` if you add one.
- Commit messages are short and type-prefixed: `fix(share): ...`, `feat(gallery): ...`, `docs: ...`, `chore: ...`.

Early returns over deep nesting, immutable state where practical, and nothing that logs key material or writes decrypted data outside the app's private cache.

## Code of conduct

Be straightforward and civil. Disagree with the code, not the person. Anything else gets the thread locked.
