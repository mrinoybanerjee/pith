# Building Pith

Pith builds with the Command Line Tools (Swift 6) on an Apple Silicon Mac with macOS 15 or
later. Xcode is not needed.

## Build the app

```bash
./scripts/build-app.sh
```

The script builds the release binary and assembles `dist/Pith.app`. The bundle holds the
binary, `Info.plist`, `AppIcon.icns`, `guide.json`, `LICENSE.txt` and
`THIRD_PARTY_NOTICES.md`. Then the script signs the bundle and runs
`codesign --verify --deep --strict`. The last line it prints is the app's path.

The app reads `guide.json` from `Contents/Resources`. The guide is not a SwiftPM resource:
`Bundle.module` would look for its bundle at the app's root, where code signing rejects it
("unsealed contents"), and it would compile the absolute `.build` path of the building Mac
into the app. Tests read the same file from `Sources/PithCore/Resources/`.

Signing:

- With the `Pith Local Development` identity in the login keychain, the script signs with it.
- Without it, the script signs ad-hoc.
- `CODESIGN_IDENTITY` overrides both. `CODESIGN_IDENTITY=-` signs ad-hoc.

The script always prints its choice to stderr, as `signing with: <identity>` (`-` is ad-hoc).
When it falls back to ad-hoc, it also prints why.

## Test

```bash
./scripts/ci-local.sh
```

This runs the lint, a release build with warnings as errors, and every test, including the
`install.sh` checks in `Tests/Scripts/`.

## Install and open

```bash
./scripts/install.sh local                       # build, install on this Mac, open
./scripts/install.sh local air pro               # build once, then this Mac and two SSH hosts
./scripts/install.sh --app /path/to/Pith.app pro # install a built app, no build
./scripts/install.sh --dry-run local pro         # print the commands only
```

A remote target needs key-based SSH (the script uses `BatchMode=yes`, so it never asks for a
password) and a logged-in desktop session, so that `open` can start Pith there.

Before it changes anything, the script checks that the app exists and passes
`codesign --verify --deep --strict`. The `--app` path must end in `Pith.app`, with no trailing
slash. Bad arguments or a broken app stop the script with exit status 2.

Then, for each target (`local`, or an SSH host), the script:

1. Quits Pith with `pkill -x Pith` and waits up to 5 s for it to exit. If Pith still runs,
   that target fails with "Pith did not quit on <target>".
2. Copies the app with `rsync -a --delete <app> <host>:/Applications/` (a plain local `rsync`
   for `local`).
3. Opens it with `open /Applications/Pith.app`.

A failed target does not stop the others. At the end the script prints `installed:` and
`failed:` with the targets, and exits 1 if any target failed. SSH connections time out after
5 s.

Launch Pith only from `/Applications`, never from a `.build` binary. On its first launch Pith
adds itself as a login item.

## Stable local signing (one time, optional)

An ad-hoc signature changes with each build, so macOS can treat each build as a new app. Pith
asks for no privacy permissions, so ad-hoc builds work. A stable identity keeps one code
identity across builds. It is free and needs no Apple Developer Program membership. It puts a
private key in the login keychain, so do it separately on each Mac that builds Pith, and never
export or commit that key. Apple documents the flow in [Create self-signed certificates in
Keychain Access][apple-self-signed].

1. Open Keychain Access.
2. Choose Keychain Access > Certificate Assistant > Create a Certificate.
3. Set the name to `Pith Local Development`.
4. Choose `Self Signed Root` as the identity type and `Code Signing` as the certificate type.
5. Create the certificate in the login keychain.
6. Check it from the repository:

   ```bash
   security find-identity -v -p codesigning
   ```

   The identity must appear exactly as `Pith Local Development`.

The first build after this can ask for access to the private key. Choose `Always Allow` for
`/usr/bin/codesign`. Build in a Terminal on the Mac itself: over SSH the login keychain can be
locked for that session, and then `codesign` cannot use the key. Use `CODESIGN_IDENTITY=-` for
builds over SSH.

The certificate has an expiry date. After it expires, `security find-identity -v` no longer
lists it, so the build signs ad-hoc and says so. Create a new certificate to sign with a stable
identity again.

[apple-self-signed]: https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac

## App icon

`swift scripts/make-app-icon.swift` draws `Resources/AppIcon.icns` from code: the calm dot on
a soft neutral squircle. Run it from the repository root, then commit the `.icns`. An `.icns`
file cannot hold separate light and dark variants, so Pith ships one light icon.
