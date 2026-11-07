import 'package:cryptography/cryptography.dart';

import 'name_policy.dart';
import 'signing.dart';

/// This device's account.
///
/// Made once on first launch and never replaced. The key pair is the identity,
/// and [userId] is the public key.
class LocalIdentity {
  const LocalIdentity({
    required this.userId,
    required this.displayName,
    required this.accountCreatedAt,
    required this.nameSetAt,
    required this.keyPair,
  });

  /// The public key as base64url text.
  final String userId;

  final String displayName;

  /// When the account was made. Used for the grace period, and never changes,
  /// so you can't keep resetting it by renaming.
  final int accountCreatedAt;

  /// When the current name was set.
  final int nameSetAt;

  /// The private key. Only in memory here; saved in secure storage.
  final SimpleKeyPair keyPair;

  /// A short version of the key to show on screen, so you can check it's
  /// really your account.
  String get fingerprint {
    final id = userId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return '${id.substring(0, 4)}-${id.substring(4, 8)}'.toUpperCase();
  }

  bool canRename({NamePolicy policy = NamePolicy.defaults, int? nowMs}) =>
      policy.canRename(
        anchorMs: accountCreatedAt,
        nameSetAtMs: nameSetAt,
        nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      );

  DateTime? renameUnlocksAt(
          {NamePolicy policy = NamePolicy.defaults, int? nowMs}) =>
      policy.unlocksAt(
        anchorMs: accountCreatedAt,
        nameSetAtMs: nameSetAt,
        nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      );

  Duration? graceRemaining(
          {NamePolicy policy = NamePolicy.defaults, int? nowMs}) =>
      policy.graceRemaining(
        anchorMs: accountCreatedAt,
        nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      );

  /// Makes an identity that is never saved.
  ///
  /// For tests. Real accounts come from [IdentityStore.create], which also
  /// writes the private key to secure storage. The key pair here is real, it
  /// just disappears when the app closes.
  static Future<LocalIdentity> generate({
    required String displayName,
    int? nowMs,
    Signing? signing,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final keyPair = await (signing ?? Signing()).newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return LocalIdentity(
      userId: Signing.encodeUserId(publicKey.bytes),
      displayName: displayName,
      accountCreatedAt: now,
      nameSetAt: now,
      keyPair: keyPair,
    );
  }

  LocalIdentity withName(String name, {required int nowMs}) => LocalIdentity(
        userId: userId,
        displayName: name,
        accountCreatedAt: accountCreatedAt,
        nameSetAt: nowMs,
        keyPair: keyPair,
      );
}

/// Where a person on the list came from.
enum UserKind {
  /// Has a phone, a key pair, and signs their own messages.
  device,

  /// Someone the host typed in by hand. No phone and no key, just a name the
  /// host controls and can edit whenever.
  manual;

  static UserKind fromName(String v) =>
      UserKind.values.firstWhere((e) => e.name == v);
}

/// A person as the host has them recorded.
class KnownUser {
  const KnownUser({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.firstSeenAt,
    required this.nameSetAt,
    this.publicKey,
  });

  final String id;
  final String displayName;
  final UserKind kind;

  /// When the host first saw this id, by the host's own clock. We never trust
  /// a time sent by a phone, the same way we don't use phone clocks to order
  /// the queue.
  final int firstSeenAt;

  final int nameSetAt;

  /// Null for people the host typed in.
  final String? publicKey;

  bool get isManual => kind == UserKind.manual;

  /// Names the host typed in can always be edited — locking those would only
  /// stop the host fixing their own typos.
  bool hostMayAcceptNewName({
    NamePolicy policy = NamePolicy.defaults,
    required int nowMs,
  }) =>
      isManual ||
      policy.canRename(
        anchorMs: firstSeenAt,
        nameSetAtMs: nameSetAt,
        nowMs: nowMs,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'display_name': displayName,
        'kind': kind.name,
        'first_seen_at': firstSeenAt,
        'name_set_at': nameSetAt,
        'public_key': publicKey,
      };

  static KnownUser fromMap(Map<String, Object?> m) => KnownUser(
        id: m['id']! as String,
        displayName: m['display_name']! as String,
        kind: UserKind.fromName(m['kind']! as String),
        firstSeenAt: m['first_seen_at']! as int,
        nameSetAt: m['name_set_at']! as int,
        publicKey: m['public_key'] as String?,
      );

  static bool looksLikeDevice(String id) => Signing.isDeviceIdentity(id);
}
