# Roostr iOS

The iPhone and iPad app. The app itself is Rust: the GPUI app from the
sibling `RoostrWebsite` repository (`gpui/`, crate `roostr-ios`) - the same
views as the desktop app and roostr.space, over this device's own replica
(the shared Odin engine from `glonOdin`, a SQLite change store, Nostr relays).
This repository is only the Xcode host: the XcodeGen spec, the app icon,
launch colour, privacy manifest, and a one-line C `main` that hands the
process to `roostr_main`.

## Layout

```
project.yml              XcodeGen spec: target Roostr, Info.plist properties, link flags
App/main.c               calls roostr_main() (libroostr_ios.a); never returns
App/Assets.xcassets      AppIcon, LaunchBackground (the window colour before the first frame)
App/PrivacyInfo.xcprivacy required-reason APIs (UserDefaults, file timestamps)
Scripts/build-rust.sh    Xcode pre-build step: cargo build -p roostr-ios for the platform being built
Scripts/archive.sh       archive, export and upload to App Store Connect
```

`Scripts/build-rust.sh` builds `../RoostrWebsite/gpui` (`ROOSTR_GPUI_DIR`
overrides) for `aarch64-apple-ios-sim` or `aarch64-apple-ios` - Debug with
cargo's dev profile (line tables only, no incremental cache), Release with
`--release` - and copies `libroostr_ios.a` into the target's derived files,
where the link step finds it. It clears Xcode's environment for cargo, so
host build scripts (and the Odin engine build: `odin` on `PATH` or `ODIN`,
`../glonOdin` or `GLON_ODIN_DIR`) are not built against the iOS SDK.

## Build and run

```sh
rustup target add aarch64-apple-ios-sim aarch64-apple-ios
brew install xcodegen && xcodegen                      # Roostr.xcodeproj
xcodebuild -project Roostr.xcodeproj -scheme Roostr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/roostr_dd build
xcrun simctl install booted /tmp/roostr_dd/Build/Products/Debug-iphonesimulator/Roostr.app
SIMCTL_CHILD_ROOSTR_RELAYS=ws://127.0.0.1:7799 xcrun simctl launch --console booted app.roostr.Roostr
```

A device build: `-destination 'generic/platform=iOS'` (add
`CODE_SIGNING_ALLOWED=NO` to only compile and link).

| Variable | Default | Meaning |
|---|---|---|
| `ROOSTR_RELAYS` | the replica's default relay | `wss://a,wss://b` for a device whose relay list was never set |
| `ROOSTR_DB` | `Application Support/Roostr/roostr.sqlite` | the change store (its directory also holds `local.json`) |
| `RUST_LOG` | `warn` | log filter (stderr: `simctl launch --console`, the Xcode console) |

## What lives where

Same places as the Swift app before it, so an installed app updated to this
one keeps its identity and vault:

- Identity: Keychain generic password `app.roostr.identity` / `nostr-secret`
  (the 32 secret bytes), this-device-only, readable after first unlock.
- Space keys: Keychain `app.roostr.space-keys` / `channel-keys` (the key
  file's JSON).
- Relay list: `UserDefaults["roostr-relays"]`; it survives logout.
- Change store: `Application Support/Roostr/roostr.sqlite`. The Rust store
  migrates the Swift app's schema in place; replay-cache rows of the Swift
  engine are ignored and rebuilt. Invite and join-request bookkeeping the
  Swift app kept in the store's meta rows is not carried over (it lives in
  `local.json` now) and starts empty.

Logging out (Settings → "Log out on this device") is refused while changes
are unpublished; it then erases the replica and forgets the identity and
space keys.

## Behaviour

- iPhone portrait (≤720pt wide) gets the mobile shell; iPhone landscape and
  iPad lay out like the desktop. The window content sits inside the safe
  area and above the on-screen keyboard.
- The keyboard comes up as in the iOS web view: for a tap on a field, not for
  a field the app focuses by itself (the chat composer when a page opens
  stays focused, keyboard down, until tapped). Return acts as Enter (splits a
  block, sends a message, confirms a field). Dismissing the keyboard ends
  editing, so a block edited on another device then shows the change. No
  hover state or tooltip outlives a tap. See the gpui README's iOS section.
- Sync reconnects without a relaunch: returning from the background, a
  network path change (Wi-Fi ⇄ cellular, back online), pulling the mobile
  page down and tapping the mobile sync dot all call `ReplicaBackend::resume`.
- Reminders: the phone runs no scheduler and no agents. After each burst of
  commits it mirrors every recurring object's next occurrence
  (`repeat.next`) into pending local notifications - the soonest 64 - and
  asks for permission the first time there is something to remind about.
  Tapping one opens the object. Agent-owned objects say they run on the
  machine serving their space.
- `roostr://app/<web path>` opens that page (`roostr://app/app/object/<id>`).
- Files, images, avatars and custom icons come from the document picker;
  files are encrypted and uploaded to the relays' Blossom server.
- Emoji draw in the bundled Twemoji (the font the web build uses).

## TestFlight / App Store

```sh
# once: Xcode > Settings > Accounts > sign in with the developer Apple ID
Scripts/archive.sh --upload                # archive (Release, generic iOS), export, upload to App Store Connect
```

Bundle id `app.roostr.Roostr`; version from `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` in `project.yml` (bump the build number for every
upload). `App/PrivacyInfo.xcprivacy` declares the required-reason APIs; no
tracking, no collected data. Export compliance is answered per build in App
Store Connect (NIP-44 is standard encryption: "uses encryption / standard
algorithms").
