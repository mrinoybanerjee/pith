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

The app reads `guide.json` from `Contents/Resources`. It does not use SwiftPM's
`Pith_PithCore.bundle`: `Bundle.module` looks for that bundle at the app's root, where code
signing rejects it ("unsealed contents"), and then at the `.build` path of the Mac that built
the app.

Signing:

- With the `Pith Local Development` identity in the login keychain, the script signs with it.
- Without it, the script signs ad-hoc.
- `CODESIGN_IDENTITY` overrides both. `CODESIGN_IDENTITY=-` signs ad-hoc.

## Install and open

```bash
./scripts/install.sh local                       # build, install on this Mac, open
./scripts/install.sh local air pro               # build once, then this Mac and two SSH hosts
./scripts/install.sh --app /path/to/Pith.app pro # install a built app, no build
./scripts/install.sh --dry-run local pro         # print the commands only
```

For each target (`local`, or an SSH host), the script:

1. Quits a running Pith with `osascript -e 'tell application id "com.mrinoy.pith" to quit'`
   and waits until it exits. A Mac where Pith does not run skips this step.
2. Copies the app with `rsync -a --delete <app> <host>:/Applications/` (a plain local
   `rsync` for `local`). The `--app` path must end in `Pith.app`, with no trailing slash.
3. Opens it with `open /Applications/Pith.app`.

Launch Pith only from `/Applications`, never from a `.build` binary. On its first launch Pith
adds itself as a login item.

## Stable local signing (one time, optional)

An ad-hoc signature changes with each build, so macOS can treat each build as a new app. Pith
asks for no privacy permissions, so ad-hoc builds work. A stable identity keeps one code
identity across builds. It is free and needs no Apple Developer Program membership. It puts a private key in the login keychain, so do it separately on each Mac that
builds Pith, and never export or commit that key. Apple documents the flow in
[Create self-signed certificates in Keychain Access](https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac).

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

## App icon

`swift scripts/make-app-icon.swift` draws `Resources/AppIcon.icns` from code: the calm dot on
a soft neutral squircle. Run it from the repository root, then commit the `.icns`. An `.icns`
file cannot hold separate light and dark variants, so Pith ships one light icon.
