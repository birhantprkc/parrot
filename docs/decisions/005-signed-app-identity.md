# ADR-005 :: Signed app identity

Last updated: `2026.09.27`

> Parrot ships as `Parrot.app` with bundle ID `com.humanitas.parrot`, signed with the team's Developer ID and notarized, and uses `SMAppService` for launch at login. A stable code identity is what makes the Microphone and Accessibility grants survive updates.

## 1. Decision

- **Bundle ID `com.humanitas.parrot`.** Local development builds are signed with the same identifier through `scripts/dev-install.sh`.
- **Developer ID signing and notarization.** Releases are signed with the team's Developer ID Application certificate and notarized with a Parrot-only App Store Connect API key (`parrot-notary`), separate from other projects' keys.
- **`SMAppService` for launch at login**, replacing the hand-written LaunchAgent (label `com.digimata.parrot`), which is removed on upgrade.
- **One binary, two roles.** The executable inside the bundle runs the dictation loop when launched with no subcommand and serves the CLI through a symlink.

## 2. Rationale

macOS keys TCC grants to the code identity. Parrot was distributed ad-hoc signed, so every build was a new identity: after an update, Accessibility silently stopped applying and dictation typed nothing. The installer also had to strip the quarantine attribute to get past Gatekeeper, which notarization makes unnecessary.

`com.digimata.parrot`, the LaunchAgent's label, was rejected in favour of the current organisation's name. Changing a bundle ID after users grant permissions forces every user to grant them again, so the change was made before the first signed release. A shared notarization key across projects was rejected so a leak from this public repo's CI can be revoked without affecting other apps.

## 3. Design Implications

- Changing the bundle ID or signing team resets every user's permission grants; treat it as a breaking change.
- Updates are Sparkle archives signed with the Parrot EdDSA key (`SPARKLE_PRIVATE_KEY`), and Sparkle also requires the update's code signature to match the installed app. Rotating the EdDSA key or the Developer ID team breaks auto-update for existing installs.
- Release builds need the Developer ID certificate and notarization credentials in CI; local builds use the `parrot-notary` keychain profile.
- The running app asks for its own grants on first start and waits for them; it never exits over a missing Accessibility grant.

## 4. When to Revisit

- Mac App Store distribution (sandboxing, a different signing identity).
- A change of the owning organisation or developer team.
