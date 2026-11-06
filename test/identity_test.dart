import 'package:beaconq/identity/identity.dart';
import 'package:beaconq/identity/name_policy.dart';
import 'package:beaconq/identity/signing.dart';
import 'package:flutter_test/flutter_test.dart';

const int minute = 60 * 1000;
const int day = 24 * 60 * minute;

void main() {
  group('name policy', () {
    const policy = NamePolicy.defaults;
    const created = 1000000;

    test('free to fix a typo inside the grace window', () {
      expect(
        policy.canRename(
          anchorMs: created,
          nameSetAtMs: created,
          nowMs: created + 10 * minute,
        ),
        isTrue,
      );
      expect(
        policy.graceRemaining(anchorMs: created, nowMs: created + 10 * minute),
        const Duration(minutes: 5),
      );
    });

    test('locked once the grace window passes', () {
      const now = created + 20 * minute;
      expect(
        policy.canRename(anchorMs: created, nameSetAtMs: created, nowMs: now),
        isFalse,
      );
      expect(
        policy.unlocksAt(anchorMs: created, nameSetAtMs: created, nowMs: now),
        DateTime.fromMillisecondsSinceEpoch(created + 7 * day),
      );
    });

    test('unlocks again seven days after the last change', () {
      expect(
        policy.canRename(
          anchorMs: created,
          nameSetAtMs: created,
          nowMs: created + 7 * day,
        ),
        isTrue,
      );
    });

    test('renaming does not restart the grace window', () {
      const renamedAt = created + 14 * minute;
      expect(
        policy.canRename(
          anchorMs: created,
          nameSetAtMs: renamedAt,
          nowMs: renamedAt + 14 * minute,
        ),
        isFalse,
      );
    });
  });

  group('name validator', () {
    test('accepts a normal name', () {
      expect(NameValidator.validate('Ana Smith'), isNull);
    });

    test('rejects names that are too short, too long or have no letters', () {
      expect(NameValidator.validate(' a '), isNotNull);
      expect(NameValidator.validate('x' * 41), isNotNull);
      expect(NameValidator.validate('12345'), isNotNull);
    });

    test('collapses repeated spaces', () {
      expect(NameValidator.normalise('  Ana   Smith '), 'Ana Smith');
    });
  });

  group('local identity', () {
    test('its user id is its public key', () async {
      final identity = await LocalIdentity.generate(displayName: 'Ana');
      final publicKey = await identity.keyPair.extractPublicKey();

      expect(identity.userId, Signing.encodeUserId(publicKey.bytes));
      expect(KnownUser.looksLikeDevice(identity.userId), isTrue);
    });

    test('shows a short fingerprint in ABCD-EFGH form', () async {
      final identity = await LocalIdentity.generate(displayName: 'Ana');
      expect(
        RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(identity.fingerprint),
        isTrue,
      );
    });

    test('a rename keeps the key and the creation time', () async {
      final identity =
          await LocalIdentity.generate(displayName: 'Ana', nowMs: 1000);
      final renamed = identity.withName('Anna', nowMs: 2000);

      expect(renamed.userId, identity.userId);
      expect(renamed.accountCreatedAt, 1000);
      expect(renamed.nameSetAt, 2000);
      expect(renamed.displayName, 'Anna');
    });
  });

  group('known user', () {
    test('survives a round trip through a database map', () {
      const user = KnownUser(
        id: 'manual:42',
        displayName: 'Guest',
        kind: UserKind.manual,
        firstSeenAt: 10,
        nameSetAt: 20,
      );
      final copy = KnownUser.fromMap(user.toMap());

      expect(copy.id, user.id);
      expect(copy.displayName, user.displayName);
      expect(copy.kind, UserKind.manual);
      expect(copy.firstSeenAt, 10);
      expect(copy.nameSetAt, 20);
      expect(copy.publicKey, isNull);
    });

    test('the host can always rename someone it typed in', () {
      const user = KnownUser(
        id: 'manual:42',
        displayName: 'Guest',
        kind: UserKind.manual,
        firstSeenAt: 0,
        nameSetAt: 0,
      );
      expect(user.hostMayAcceptNewName(nowMs: 30 * minute), isTrue);
    });
  });
}
