# BeaconQ - offline BLE attendance and queues

BeaconQ is a Flutter app that runs a session (a class, DnD session, lab or 
office hours) entirely over Bluetooth Low Energy. No internet and no server
are needed.

## Roles
- **Host** - their device advertises the session, stores the only database,
  tracks who is present, runs an optional queue and exports an attendance CSV.
  
- **Attendee** - their phone finds nearby sessions, joins with one tap,
  checks in every ~30 seconds and can join, pick or leave a queue slot.

## Planned features
- Session discovery and one-tap join over BLE
- Signed messages (Ed25519): a user's id is their public key
- Queue with host-assigned arrival order, pinned slots and overflow
- Presence tracking and random attendance checks
- Per-person timers and CSV export of the session register

## Tech stack
Flutter / Dart, SQLite (sqflite), flutter_blue_plus (central),
ble_peripheral_plus (peripheral), cryptography (Ed25519).

## Status
In development. Planning and documentation are in the course Kreo PM project.