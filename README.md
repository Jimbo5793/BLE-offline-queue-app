# BeaconQ — offline BLE attendance and queues

BeaconQ is a Flutter app that runs a session (a class, lab, office hours or
tabletop game) entirely over Bluetooth Low Energy. No internet and no server
are needed: one device hosts, everyone nearby joins with a tap, and the host
always knows who is in the room and in what order people should be seen.

## Roles
- **Host** — their device advertises the session, stores the only database,
  tracks who is present, runs an optional queue, times each person being
  served, runs random attendance checks and exports the register as CSV.
- **Attendee** — their phone finds nearby sessions, joins with one tap,
  checks in about every 30 seconds and can join, pick, pin or leave a queue
  slot. Nothing is stored permanently on an attendee's phone.

## Features
- One-tap join over BLE, with no codes or QR scanning
- Signed messages (Ed25519): a user's ID is their public key, so nobody can
  act on someone else's behalf
- Queue with host-assigned arrival order, pinned slots, host overrides and
  overflow; retried requests never create duplicate entries
- Presence tracking from signal strength and check-ins (in range, weak
  signal, out of range)
- Random and on-demand attendance checks
- Per-person count-up and countdown timers with warning pings
- Session history and CSV export of the register
- Keeps working with the screen locked (Android foreground service, iOS
  Bluetooth background modes)

## Tech stack
Flutter / Dart 3, SQLite (`sqflite`), `flutter_blue_plus` (attendee, BLE
central), `ble_peripheral_plus` (host, BLE peripheral and GATT server),
`cryptography` (Ed25519), `flutter_secure_storage`, `permission_handler`,
`flutter_foreground_task`, `share_plus`, `audioplayers`.

Platforms: Android, iOS and macOS.

## Project structure
```
lib/
  main.dart     app entry, account gate, role picker
  account/      account creation and details screens
  identity/     key pair, signing, secure storage, name policy
  domain/       plain data: session, attendance, queue, proximity
  logic/        rules: queue changes, positions, presence, checks, timers
  data/         host database (schema v6), history, CSV export
  transport/    envelopes, chunking, BLE host and attendee, test loopback
  host/         host service and screens
  attendee/     attendee service and screens
  common/       live session registry, permissions, theme, helpers
test/           unit and widget tests
```
Dependencies only point downwards: screens call services, services use the
logic, data, identity and transport layers, and everything rests on the plain
domain classes.

## Getting started
```
git clone https://github.com/Jimbo5793/BLE-offline-queue-app.git
cd BLE-offline-queue-app
git switch develop
flutter pub get
flutter analyze
flutter test
flutter run -d <device>
```
BLE needs real hardware: run the host and attendees on physical devices.
On macOS the app needs a development certificate for the keychain
entitlement.

## Branching
- `main` holds checked releases only.
- `develop` integrates finished work for the next release.
- Each task gets a `feature/HAMZA-N-short-name` branch created from `develop`
  and merged back into `develop` when its checks pass.
- `develop` is merged into `main` only after the release checks.

Every push runs `flutter analyze` and `flutter test` in GitHub Actions.

## Status
Version 1.0: all modules are in place and pass analysis and the automated
tests in CI. Planning and documentation are in the course Kreo PM project.
