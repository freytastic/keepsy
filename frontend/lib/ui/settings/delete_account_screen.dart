import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/models/album_summary.dart';
import 'package:keepsy/domain/account/account_deletion.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/screens/account_deletion_screen.dart';
import 'package:keepsy/ui/settings/settings_page.dart';
import 'package:keepsy/ui/shelf/album_print.dart';
import 'package:keepsy/ui/shelf/shelf_data.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/warm_button.dart';
import 'package:provider/provider.dart';

const _holdFor = Duration(milliseconds: 1800);

// Albums this account administers go for everyone, so each is ticked on its own
class DeleteAccountScreen extends StatefulWidget {
  final AccountDeletion deletion;

  const DeleteAccountScreen({super.key, required this.deletion});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  DeletionPlan? _plan;
  bool _failed = false;
  bool _changed = false;
  bool _deleting = false;
  final Set<String> _ticked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final plan = await widget.deletion.plan();
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _ticked.clear();
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  bool get _ready {
    final plan = _plan;
    if (plan == null || _deleting) return false;
    return plan.shared.every((a) => _ticked.contains(a.albumId));
  }

  Future<void> _delete() async {
    final plan = _plan;
    if (plan == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final rootNav = Navigator.of(context, rootNavigator: true);
    setState(() => _deleting = true);
    // The deletion screen owns the outcome from here, including a lost response
    final result = await rootNav.push<DeletionResult>(MaterialPageRoute(
      builder: (_) =>
          AccountDeletionScreen(deletion: widget.deletion, plan: plan),
    ));
    if (!mounted) return;
    setState(() => _deleting = false);
    // Successful deletion replaces the route stack and returns null
    if (result == null) return;
    if (result == DeletionResult.planChanged) {
      setState(() {
        _changed = true;
        _plan = null;
      });
      await _load();
      return;
    }
    messenger.showSnackBar(const SnackBar(
      content: Text('Your account was not deleted. Try again.'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final state = context.watch<AppState>();
    return SettingsPage(
      title: 'Delete account',
      children: [
        const SettingsFacts([
          (
            Icons.photo_album_outlined,
            'Albums you made are deleted for everyone in them.'
          ),
          (Icons.logout_rounded, 'You leave every album someone else made.'),
          (
            Icons.smartphone_outlined,
            'Photos people already saved stay on their phones.'
          ),
          (Icons.lock_outline_rounded, "This can't be undone."),
        ]),
        if (_failed)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text("Couldn't reach Keepsy.", style: Warm.pageSoft),
                ),
                WarmTextButton(label: 'Try again', onTap: _load),
              ],
            ),
          )
        else if (plan == null)
          const Padding(
            padding: EdgeInsets.only(top: 20),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: Warm.ink),
              ),
            ),
          )
        else if (plan.shared.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 10),
            child: Text(
              _changed
                  ? 'Your albums changed. Tick them again'
                  : 'These will be deleted for everyone',
              style: Warm.pageSubhead,
            ),
          ),
          for (final a in plan.shared)
            _AlbumTick(
              album: state.albums.where((m) => m.id == a.albumId).firstOrNull,
              name: state.albumDisplayName(a.albumId) ?? 'Untitled album',
              nameOf: (m) => state.memberDisplayName(a.albumId, m.memberToken),
              people: a.activeMemberCount,
              on: _ticked.contains(a.albumId),
              onTap: () => setState(() {
                if (!_ticked.remove(a.albumId)) _ticked.add(a.albumId);
              }),
            ),
        ],
        const SizedBox(height: 36),
        _HoldToDelete(
          enabled: _ready,
          busy: _deleting,
          onDone: _delete,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Center(
            child: Text(
              plan != null && !_ready && !_deleting
                  ? 'Tick each album to continue'
                  : 'Press and hold to delete',
              style: Warm.pageSoft,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: WarmTextButton(
            label: 'Keep my account',
            color: Warm.ink,
            onTap: _deleting ? null : () => Navigator.of(context).maybePop(),
          ),
        ),
      ],
    );
  }
}

class _AlbumTick extends StatelessWidget {
  final AlbumModel? album;
  final String name;
  final String? Function(MemberPreview) nameOf;
  final int people;
  final bool on;
  final VoidCallback onTap;

  const _AlbumTick({
    required this.album,
    required this.name,
    required this.nameOf,
    required this.people,
    required this.on,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final a = album;
    return Semantics(
      checked: on,
      label: name,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              _Cover(album: a),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: Warm.rowTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 5),
                    a == null || a.memberPreviews.isEmpty
                        ? Text('$people ${people == 1 ? 'person' : 'people'}',
                            style: Warm.pageSoft)
                        : PrintFaces(
                            albumId: a.id,
                            members: a.memberPreviews,
                            total: people,
                            nameOf: nameOf,
                            ring: Warm.ground,
                          ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              AnimatedContainer(
                duration: Warm.quick,
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? Warm.warn : Colors.transparent,
                  border:
                      on ? null : Border.all(color: Warm.inkGhost, width: 1.6),
                ),
                child: on
                    ? const Icon(Icons.check_rounded,
                        size: 15, color: Warm.ground)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// The same cover the shelf print shows, decrypted from this phone's cache
class _Cover extends StatefulWidget {
  final AlbumModel? album;

  const _Cover({required this.album});

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> {
  ShelfCovers? get _covers {
    try {
      return context.read<ShelfCovers>();
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    final a = widget.album;
    if (a != null && a.previewMedia.isNotEmpty) {
      _covers?.ensureCover(a.id, a.previewMedia);
    }
  }

  @override
  Widget build(BuildContext context) {
    final covers = _covers;
    final a = widget.album;
    return ListenableBuilder(
      listenable: covers ?? const AlwaysStoppedAnimation(0),
      builder: (_, __) {
        final bytes = a == null ? null : covers?.bytes(a.id, 0);
        return Container(
          width: 46,
          height: 46,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Warm.wellEmpty,
            borderRadius: BorderRadius.circular(7),
            boxShadow: [
              BoxShadow(
                  color: Warm.shadow(0.16),
                  blurRadius: 3,
                  offset: const Offset(0, 1)),
            ],
          ),
          child: bytes == null
              ? const Icon(Icons.photo_outlined, size: 18, color: Warm.inkGhost)
              : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
        );
      },
    );
  }
}

// Only completes while the finger stays down, so it can't be done by accident
class _HoldToDelete extends StatefulWidget {
  final bool enabled;
  final bool busy;
  final VoidCallback onDone;

  const _HoldToDelete({
    required this.enabled,
    required this.busy,
    required this.onDone,
  });

  @override
  State<_HoldToDelete> createState() => _HoldToDeleteState();
}

class _HoldToDeleteState extends State<_HoldToDelete>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fill =
      AnimationController(vsync: this, duration: _holdFor)
        ..addStatusListener((s) {
          if (s != AnimationStatus.completed) return;
          HapticFeedback.heavyImpact();
          _fill.value = 0;
          widget.onDone();
        });

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  void _start() {
    if (!widget.enabled || widget.busy) return;
    HapticFeedback.selectionClick();
    _fill.forward();
  }

  void _stop() {
    if (_fill.isCompleted) return;
    _fill.animateBack(0, duration: Warm.quick, curve: Warm.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !widget.busy;
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Delete account',
      hint: 'Press and hold',
      onLongPress: enabled ? widget.onDone : null,
      excludeSemantics: true,
      child: GestureDetector(
        onTapDown: (_) => _start(),
        onTapUp: (_) => _stop(),
        onTapCancel: _stop,
        child: AnimatedOpacity(
          opacity: enabled || widget.busy ? 1 : 0.4,
          duration: Warm.quick,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(27),
            child: SizedBox(
              height: 54,
              child: AnimatedBuilder(
                animation: _fill,
                builder: (_, __) => Stack(
                  children: [
                    Positioned.fill(
                      child:
                          ColoredBox(color: Warm.warn.withValues(alpha: 0.1)),
                    ),
                    Positioned.fill(
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: _fill.value,
                        child: const ColoredBox(color: Warm.warn),
                      ),
                    ),
                    Center(
                      child: widget.busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Warm.warn),
                            )
                          : Text(
                              'Delete account',
                              style: Warm.holdLabel.copyWith(
                                color: Color.lerp(Warm.warn, Warm.ground,
                                    (_fill.value * 2 - 0.6).clamp(0.0, 1.0)),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
