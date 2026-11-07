import 'package:flutter/material.dart';

import '../identity/identity.dart';
import '../identity/identity_store.dart';
import '../identity/name_policy.dart';

/// First-run account creation.
///
/// The name is what a host sees, so it is asked for plainly and with the
/// consequence stated up front rather than buried. The keypair generated here
/// is the permanent identity: it is what makes the name unspoofable, because
/// acting as somebody else would need their private key.
class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key, required this.store, this.onCreated});

  final IdentityStore store;
  final ValueChanged<LocalIdentity>? onCreated;

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final problem = NameValidator.validate(_name.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final identity = await widget.store.create(displayName: _name.text);
      widget.onCreated?.call(identity);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not create your account: $e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final policy = widget.store.policy;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Icon(Icons.badge_outlined, size: 56, color: scheme.primary),
                const SizedBox(height: 20),
                Text('What should we call you?',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Text(
                  'Use your real name. This is how your host identifies you '
                  'in the room, so a nickname may mean they cannot find you.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _create(),
                  decoration: const InputDecoration(
                    labelText: 'Your name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.lock_clock,
                            size: 20, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'You can fix a typo for the next '
                            '${policy.grace.inMinutes} minutes. After that '
                            'your name is fixed for '
                            '${policy.lock.inDays} days — though a host can '
                            'always correct it in their own session.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error)),
                ],
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: _busy ? null : _create,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: Text(_busy ? 'Creating…' : 'Create my account'),
                ),
                const SizedBox(height: 14),
                Text(
                  'Your device generates a private key that never leaves it. '
                  'That key is what proves a queue slot is yours.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the account, and allows a rename when the policy permits one.
class AccountDetailsScreen extends StatefulWidget {
  const AccountDetailsScreen({
    super.key,
    required this.store,
    required this.identity,
    required this.onChanged,
  });

  final IdentityStore store;
  final LocalIdentity identity;
  final ValueChanged<LocalIdentity> onChanged;

  @override
  State<AccountDetailsScreen> createState() => _AccountDetailsScreenState();
}

class _AccountDetailsScreenState extends State<AccountDetailsScreen> {
  late final _name = TextEditingController(text: widget.identity.displayName);
  String? _error;
  String? _note;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _rename() async {
    final problem = NameValidator.validate(_name.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final updated = await widget.store.rename(widget.identity, _name.text);
    if (updated == null) {
      setState(() => _error = 'Your name is locked right now.');
      return;
    }
    widget.onChanged(updated);
    setState(() {
      _error = null;
      _note = 'Name updated.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final id = widget.identity;
    final canRename = id.canRename(policy: widget.store.policy);
    final grace = id.graceRemaining(policy: widget.store.policy);
    final unlocks = id.renameUnlocksAt(policy: widget.store.policy);

    return Scaffold(
      appBar: AppBar(title: const Text('Your account')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            TextField(
              controller: _name,
              enabled: canRename,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Your name',
                border: const OutlineInputBorder(),
                helperText: canRename
                    ? (grace != null
                        ? 'Editable for another ${grace.inMinutes + 1} min'
                        : 'You can change this now')
                    : 'Locked until ${_formatDate(unlocks!)}',
              ),
            ),
            const SizedBox(height: 14),
            if (canRename)
              FilledButton(onPressed: _rename, child: const Text('Save name')),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_note!, style: TextStyle(color: scheme.primary)),
              ),
            const SizedBox(height: 28),
            Text('Identity', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Card(
              child: ListTile(
                leading: const Icon(Icons.key),
                title: Text(id.fingerprint,
                    style: const TextStyle(
                        fontFamily: 'monospace', letterSpacing: 1.5)),
                subtitle: const Text(
                    'Your public key, shortened. Your private key stays on '
                    'this device and cannot be copied out.'),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'A host can correct your name inside their own session without '
              'changing your account.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime d) =>
      '${d.day}/${d.month}/${d.year}';
}
