import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/entities/user.dart';
import '../controllers/user_management_controller.dart';

/// Bottom sheet shown when a row in Manage Users is tapped. Lets the user
/// edit their name, see their template count, kick off re-enrolment, or
/// delete the user.
///
/// Architecture: see `docs/verification/architecture_recommendations.md`
/// §4.1 / §4.4.
class UserDetailSheet extends StatefulWidget {
  const UserDetailSheet({
    super.key,
    required this.user,
    required this.onSaveName,
    required this.onReEnroll,
    required this.onDelete,
  });

  final User user;

  /// Called with the validated, trimmed new name when the user taps Save.
  /// The parent is expected to call `UserManagementController.renameUser`.
  final ValueChanged<String> onSaveName;

  /// "Re-enroll" CTA — typically pushes the enrolment route with this
  /// user's id pre-filled.
  final VoidCallback onReEnroll;

  /// Confirmed delete — the parent shows the confirmation dialog and only
  /// invokes this when the user confirms.
  final VoidCallback onDelete;

  @override
  State<UserDetailSheet> createState() => _UserDetailSheetState();
}

class _UserDetailSheetState extends State<UserDetailSheet> {
  late final TextEditingController _nameController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.user.name);
    _nameController.addListener(_validate);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _validate() {
    final trimmed = _nameController.text.trim();
    String? next;
    if (trimmed.length < UserManagementController.minNameLength) {
      next = 'Name cannot be empty';
    } else if (trimmed.length > UserManagementController.maxNameLength) {
      next = 'Name must be ${UserManagementController.maxNameLength} '
          'characters or fewer';
    }
    if (next != _error) {
      setState(() => _error = next);
    }
  }

  bool get _canSave => _error == null &&
      _nameController.text.trim() != widget.user.name &&
      _nameController.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final templateCount = widget.user.faceTemplates.length;
    final requiresReEnroll = widget.user.requiresReEnroll;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          16,
          24,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              widget.user.userId,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            // Explanation banner shown only when this user's templates
            // belong to a previous face-recognition model. The matcher
            // already excludes them, so the user cannot verify until they
            // re-enrol — surface that here so the action below is the
            // obvious next step instead of looking like a routine option.
            if (requiresReEnroll) ...[
              const SizedBox(height: 12),
              const _ReEnrollBanner(),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              maxLength: UserManagementController.maxNameLength,
              decoration: InputDecoration(
                labelText: 'Display name',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              inputFormatters: [
                LengthLimitingTextInputFormatter(
                  UserManagementController.maxNameLength,
                ),
              ],
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 8),
            Text(
              'Templates on file: $templateCount',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            // When this user requires re-enrolment, promote that CTA to
            // a full-width FilledButton (the primary action). In the
            // normal case keep the two outlined buttons side-by-side.
            if (requiresReEnroll)
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: widget.onReEnroll,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Re-enroll now'),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: widget.onReEnroll,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Re-enroll'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: widget.onDelete,
                      icon: Icon(Icons.delete_outline, color: scheme.error),
                      label: Text(
                        'Delete',
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            // Stale-version users still need a Delete affordance, but it
            // moves to a less-prominent text button so re-enrol stays
            // the primary action.
            if (requiresReEnroll)
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: widget.onDelete,
                  icon: Icon(Icons.delete_outline, color: scheme.error),
                  label: Text(
                    'Delete instead',
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              ),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: _canSave
                    ? () => widget.onSaveName(_nameController.text.trim())
                    : null,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Amber explanation banner shown at the top of [UserDetailSheet] when
/// the user's stored templates were produced by a previous face-
/// recognition model. The matcher already excludes them, so a verify
/// attempt would always fail until the user is re-enrolled — this banner
/// makes that the obvious next action.
class _ReEnrollBanner extends StatelessWidget {
  const _ReEnrollBanner();

  static const _bg = Color(0xFFFFF3E0);
  static const _border = Color(0xFFFFCC80);
  static const _fg = Color(0xFF7A4100);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _bg,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: _fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'This user was enrolled with a previous face model. '
              'They cannot verify until you re-enroll them.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _fg,
                    height: 1.3,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
