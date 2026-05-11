import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../controllers/user_management_controller.dart';
import '../dialogs/delete_user_dialog.dart';
import '../view_models/user_management_row_vm.dart';
import '../widgets/user_detail_sheet.dart';

/// Manage Users screen — replaces the Phase 1 stub. Lists every enrolled
/// user with the four "facts" required by architecture §G8: enrollment
/// status, last-verify time, template count, and verifications-today.
class UserManagementScreen extends ConsumerWidget {
  const UserManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(userManagementRowsProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Enrolled Users'),
      ),
      body: rows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Failed to load users:\n$e',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.error),
            ),
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return _EmptyState(
              onEnroll: () => context.push('/enroll'),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (_, i) => _UserRow(vm: list[i]),
          );
        },
      ),
    );
  }
}

class _UserRow extends ConsumerWidget {
  const _UserRow({required this.vm});

  final UserManagementRowVm vm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final user = vm.user;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openSheet(context, ref),
        onLongPress: () => _confirmDelete(context, ref),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      user.userId,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                    ),
                  ),
                  // Amber re-enrol pill — only present when the user's
                  // stored templates were produced by a different face-
                  // recognition model than the bundled one. Tap the row
                  // to open the detail sheet, which surfaces the
                  // explanation + primary Re-enroll CTA.
                  if (user.requiresReEnroll) ...[
                    const _ReEnrollPill(),
                    const SizedBox(width: 6),
                  ],
                  _StatusPill(active: user.isActive),
                  Switch.adaptive(
                    value: user.isActive,
                    onChanged: (_) => ref
                        .read(userManagementControllerProvider.notifier)
                        .toggleActive(user),
                  ),
                  IconButton(
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => _confirmDelete(context, ref),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                user.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              _MetaLine(
                children: [
                  _meta('Enrolled', _fmtDate(user.enrolledAt)),
                  _meta('Templates', '${user.faceTemplates.length}'),
                ],
              ),
              const SizedBox(height: 4),
              _MetaLine(
                children: [
                  _meta('Last verified', _fmtDateTime(user.lastVerifiedAt)),
                ],
              ),
              const SizedBox(height: 4),
              _MetaLine(
                children: [
                  _meta('Verifications today', '${vm.verificationsToday}'),
                  _meta('Last result', _fmtOutcome(vm.lastOutcome)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSheet(BuildContext context, WidgetRef ref) async {
    final user = vm.user;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (sheetCtx) => UserDetailSheet(
        user: user,
        onSaveName: (newName) async {
          try {
            await ref
                .read(userManagementControllerProvider.notifier)
                .renameUser(user, newName);
          } finally {
            if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
          }
        },
        onReEnroll: () {
          Navigator.of(sheetCtx).pop();
          context.push('/enroll');
        },
        onDelete: () {
          Navigator.of(sheetCtx).pop();
          _confirmDelete(context, ref);
        },
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    final user = vm.user;
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => DeleteUserDialog(
        userName: user.name,
        onConfirm: () async {
          Navigator.of(dialogCtx).pop();
          await ref
              .read(userManagementControllerProvider.notifier)
              .deleteUser(user);
        },
      ),
    );
  }

  static MapEntry<String, String> _meta(String label, String value) =>
      MapEntry(label, value);

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmtDate(DateTime? d) {
    if (d == null) return 'Unknown';
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  static String _fmtDateTime(DateTime? d) {
    if (d == null) return 'Never';
    return '${d.year}-${_two(d.month)}-${_two(d.day)} '
        '${_two(d.hour)}:${_two(d.minute)}';
  }

  static String _fmtOutcome(String? o) {
    if (o == null) return '—';
    return switch (o) {
      'granted' => '✓ Granted',
      'denied' => '✗ Denied',
      'spoof' => '✗ Spoof',
      'rateLimited' => '⏸ Rate limited',
      'error' => '⚠ Error',
      'timeout' => '⏱ Timeout',
      _ => o,
    };
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = active ? const Color(0xFF2E7D32) : scheme.error;
    final bg = active ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        active ? 'Active' : 'Inactive',
        style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}

/// Amber "Re-enroll" badge. Rendered next to [_StatusPill] when a user's
/// stored templates were produced by a model other than the one currently
/// bundled (see `User.requiresReEnroll`). Tapping the row opens the
/// detail sheet, which carries the explanation and the primary CTA.
class _ReEnrollPill extends StatelessWidget {
  const _ReEnrollPill();

  static const _bg = Color(0xFFFFF3E0); // amber-50
  static const _fg = Color(0xFFB7570B); // amber-900-ish

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Re-enrolment required',
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 14, color: _fg),
            SizedBox(width: 4),
            Text(
              'Re-enroll',
              style: TextStyle(
                color: _fg,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.children});

  final List<MapEntry<String, String>> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final e in children)
          RichText(
            text: TextSpan(
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
              children: [
                TextSpan(text: '${e.key}: '),
                TextSpan(
                  text: e.value,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onEnroll});

  final VoidCallback onEnroll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_off_outlined,
              size: 72,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No users enrolled',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Enroll your first user to get started.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onEnroll,
              icon: const Icon(Icons.person_add_rounded),
              label: const Text('Enroll your first user'),
            ),
          ],
        ),
      ),
    );
  }
}
