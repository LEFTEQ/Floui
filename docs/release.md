# Release Workflow

Floui currently develops as a Swift Package, but release distribution is prepared as a notarized `.app` bundle built around the release executable.

## Why This Flow Exists

- `swift run FlouiApp` is correct for local development.
- Distribution requires a real app bundle with `Info.plist`, bundle identifier, Apple Events usage description, signing, and notarization.
- Ghostty is loaded dynamically, so the release entitlements intentionally disable library validation in hardened runtime.

## Files

- `config/release/release.env.example`: release configuration template
- `config/release/Floui.entitlements`: hardened runtime entitlements
- `scripts/build-release-bundle`: builds `.app` from the release executable
- `scripts/sign-release-bundle`: applies Developer ID signing
- `scripts/package-release`: creates zip and optional DMG artifacts
- `scripts/notarize-release`: submits artifacts through `notarytool` and staples
- `scripts/generate-appcast`: runs Sparkle's `generate_appcast` if available
- `scripts/release`: orchestrates the full flow
- `scripts/test-release-tooling`: smoke-tests bundle generation and metadata

## Config

Copy the example config:

```bash
cp config/release/release.env.example config/release/release.env
```

Then provide real values for:

- `FLOUI_RELEASE_VERSION`
- `FLOUI_BUILD_NUMBER`
- `FLOUI_BUNDLE_ID`
- `FLOUI_CODESIGN_IDENTITY`
- `FLOUI_NOTARY_PROFILE`
- `FLOUI_APPCAST_URL`
- `FLOUI_SUPUBLIC_ED_KEY`

## Smoke Test

```bash
./scripts/test-release-tooling
```

This builds a release executable, wraps it into `Floui.app`, creates a zip artifact, and validates the generated `Info.plist`.

## Typical Release

```bash
./scripts/build-release-bundle --config config/release/release.env
./scripts/sign-release-bundle --config config/release/release.env
./scripts/package-release --config config/release/release.env --with-dmg
./scripts/notarize-release --config config/release/release.env
./scripts/generate-appcast --config config/release/release.env
```

Or, if all credentials and Sparkle tooling are ready:

```bash
./scripts/release --config config/release/release.env --with-dmg
```

## Current Constraints

- Sparkle-compatible metadata is written into the bundle, but the in-app updater UI is not embedded yet.
- `generate_appcast` must come from a local Sparkle installation or an explicitly configured path.
- Real signing and notarization still require Apple Developer credentials on the machine performing the release.
