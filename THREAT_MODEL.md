# Threat model

This document says what CipherNest protects, from whom, and what it does not protect. Every claim is about code in this repository. Where a protection is missing or partial, it is listed here and in the [MASVS self-assessment](docs/MASVS_REPORT.md) rather than left implied.

## What CipherNest is

An Android app that encrypts files on the device and stores the ciphertext in the user's own Google Drive or OneDrive. CipherNest runs no file server. The only CipherNest-operated service is a Cloudflare Worker that serves the share-link web viewer and relays ciphertext for shared files.

## Assets

1. **File contents.** Photos, videos and documents.
2. **File metadata.** Names, types, sizes, folder and album structure, timestamps.
3. **Key material.** The BIP-39 recovery phrase, the seed derived from it, the vault's X25519 keypair, per-file keys, and the local password where one is set.
4. **Shared files.** The content and key of any file the user has made a share link for.
5. **The relationship between a user and their files.** Which cloud account holds which vault.

## Adversaries

**The cloud provider.** Honest but curious: it follows the protocol, keeps everything it stores, and may inspect all of it. It can also be compelled to hand data over, or breached.

**Someone who obtains the cloud account.** Credential theft, a shared family account, a provider-side mistake. They have the same view as the provider plus the ability to delete or replace objects.

**The share relay operator, which is us.** The Worker sees ciphertext in transit and the request metadata. It must not be able to read shared files.

**A recipient of a share link.** Legitimately holds the key to one file. Must not be able to reach anything else.

**Another app on the same device.** Ordinary, unprivileged, with whatever the user granted it.

**Someone with brief physical access to the device.** Locked or unlocked, without root.

**A network observer.** On the path between the device and the provider or relay.

## What is protected, and how

**File contents against the provider, the account thief, the relay and the network.** Every file is encrypted on the device before upload with AES-256-GCM in 512 KiB chunks under a fresh random per-file key. Each chunk's tag binds it to a random content id, its index and the total chunk count, so reordering, truncation, duplication or splicing between files fails authentication instead of decrypting to something plausible. Transport is TLS on top of that.

**Per-file keys.** Sealed to the vault's long-term X25519 public key with HPKE (RFC 9180), suite DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-128-GCM, checked against the RFC's Appendix A.1 test vectors. Only the public key is needed to seal, which is how background upload can encrypt while the vault is locked with no secret in memory.

**Filenames and types in the cloud.** Sealed with HPKE inside the cloud object's metadata. The provider stores an opaque blob where a name would be. Folders and albums live in the vault's encrypted index, not in the provider's folder tree.

**Key material.** The recovery phrase is generated on the device and never transmitted. Keys derive from the seed with HKDF-SHA256 under fixed, domain-separated labels. The seed is stored one of three ways, chosen by the user:

- wrapped under a local password with Argon2id (64 MiB, two passes) and AES-256-GCM;
- additionally wrapped under a hardware-backed Keystore key that requires biometric authentication and is invalidated when enrolment changes;
- for a vault with no password, in the platform secure store backed by the Keystore, where the device lock is the only barrier.

In every mode the phrase is the root of trust. Losing it loses the vault; nothing server-side can restore it.

**Shared files against the relay.** The file key travels in the URL fragment, which browsers do not send to servers. The viewer decrypts in the recipient's browser. The relay sees ciphertext only.

**Scope at the provider.** The app requests Google's `drive.file` scope and the OneDrive equivalent, so it can see only what it created.

**The recovery phrase on screen.** The phrase and share-key screens set `FLAG_SECURE`, so they are excluded from screenshots, screen recording and the recents snapshot. Other screens are not, by design: users may screenshot their own gallery.

**Billing identity.** The app contacts RevenueCat to check the Plus entitlement. It identifies itself with an ID derived from the seed with HKDF under a fixed label, not with a cloud account, email or device identifier. The derivation is one-way; the ID reveals nothing about the seed.

## What is not protected

Stated plainly, because a vault that oversells itself is worse than one that does not.

**A compromised device.** Malware with root, or a forensic extraction of a powered-on device that has been unlocked since boot, defeats encryption at rest. In that scenario the local metadata database is readable: filenames, folder and album names, timestamps and a timeline of activity. File contents stay encrypted on disk but anything decrypted into the cache since the last lock may be present.

**Traffic analysis.** The provider and a network observer see that you use CipherNest, how many objects you store, their sizes, and when they change. Object names do not reveal filenames, but size and timing are not padded.

**Share links are bearer tokens.** Anyone holding a link can decrypt that file for as long as the link is valid. Expiry is enforced by the viewer and the relay, but a recipient who downloaded within the window keeps their copy, and a link that is forwarded works for whoever receives it.

**A forgotten recovery phrase.** There is no reset. This is the cost of a server that holds no keys.

**Deletion by the account holder or provider.** Encryption protects confidentiality, not availability. Anyone who can delete objects in the cloud account can destroy the vault. Keep the provider's own trash and versioning enabled.

**Screenshots of your own gallery.** The app does not stop you, or an app you granted screen capture to, from capturing screens other than the phrase and share-key screens.

**The device lock on a passwordless vault.** If you chose no app password, anyone who can unlock the phone can open the vault. That is the trade the option offers.

## Assumptions

- The device is trusted while unlocked.
- The platform Keystore does what Android documents.
- Google Play, or the GitHub release and its published signing fingerprint, delivers the build we signed.
- The cloud provider follows the protocol even though it may inspect what it stores.

## Known gaps

The current self-assessment, with each open finding and its disposition, is [docs/MASVS_REPORT.md](docs/MASVS_REPORT.md). The two gaps most worth knowing about:

- the local metadata database is not encrypted at rest, so the compromised-device case above exposes metadata;
- the app has not yet had an independent audit. The assessment is self-performed, and the app is not described as audited anywhere.

## Reporting

If you find that the code does not do what this document says, that is a security bug. See [SECURITY.md](SECURITY.md).
