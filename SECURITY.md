# Security policy

CipherNest is a zero-knowledge storage app. A security bug here can expose files that people were promised nobody else could read, so reports are taken seriously and handled quickly.

## Reporting a vulnerability

Please do not open a public issue for anything security related.

- Email **security@ciphernest.io**, or
- use **Report a vulnerability** on this repository's Security tab (GitHub private vulnerability reporting).

Include what you found, where it is (file and line, or the screen and the steps), what an attacker gains from it, and a proof of concept if you have one. Encrypted mail is not required. If you want to send something sensitive, say so first and a one-time channel will be arranged.

Machine-readable contact details: https://ciphernest.io/.well-known/security.txt

## What to expect

| Step | Target |
|---|---|
| Acknowledgement | within 72 hours |
| First assessment and severity | within 7 days |
| Fix for a confirmed issue | within 90 days, sooner for anything that exposes plaintext or key material |
| Credit | on https://ciphernest.io/security, unless you prefer not to be named |

You will hear back at each step. If a fix needs longer than 90 days, you will be told why and given a new date rather than left waiting.

## Coordinated disclosure

Please give the window above before publishing. Once a fix has shipped on Google Play, you are free to publish, and the release notes and the security page will describe the issue and credit you.

Good-faith research within these rules will not be met with legal action. Good faith means: do not access, modify or delete data that is not yours, do not degrade the service for other people, and do not keep anything you were not meant to see beyond what is needed to demonstrate the issue.

## Scope

In scope:

- the Android app in `frontend/`
- the share-link web viewer in `web-viewer/`
- the Cloudflare Worker in `worker.js` that serves the viewer and relays ciphertext
- the website at https://ciphernest.io, where it affects the app's security claims

Of particular interest: anything that exposes plaintext or key material to the cloud provider, to the share relay, to another app on the device, or to someone holding a share link beyond its stated expiry; anything that lets a crafted file, share link or cloud object make the app misbehave; and anything where the code does not do what [THREAT_MODEL.md](THREAT_MODEL.md) says it does.

Out of scope:

- Google Drive, OneDrive, Google Play Billing and RevenueCat themselves. Report those to their owners.
- attacks that need a rooted or already compromised device, unless the finding is that the app makes such an attack materially easier than the threat model admits
- denial of service against the share relay
- findings already listed as open in [docs/MASVS_REPORT.md](docs/MASVS_REPORT.md), unless you have a practical exploit the report does not anticipate

## Supported versions

Only the latest version published on Google Play receives security fixes. There is no long-term support branch. Fixes ship as a new release and are noted in [CHANGELOG.md](CHANGELOG.md).

| Version | Supported |
|---|---|
| latest on Google Play | yes |
| anything older | no, please update |

## Verifying what you run

Release builds on GitHub are signed with a key whose certificate fingerprint is published at https://ciphernest.io/security. The README explains how to check a download against it.
