import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/data/storage/own_avatar_store.dart';
import 'package:keepsy/domain/avatar/avatar_publisher.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/shelf/album_print.dart';
import 'package:keepsy/ui/shelf/develop_store.dart';
import 'package:keepsy/ui/shelf/print_style.dart';
import 'package:keepsy/ui/shelf/shelf_copy.dart';
import 'package:keepsy/ui/shelf/shelf_data.dart';
import 'package:keepsy/ui/shelf/shelf_layout.dart';
import 'package:keepsy/ui/shelf/shelf_peek.dart';
import 'package:keepsy/ui/shelf/shelf_view_preference.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/foot_bar.dart';
import 'package:keepsy/ui/widgets/member_face.dart';
import 'package:keepsy/ui/widgets/print_card.dart';
import 'package:keepsy/ui/widgets/upload_pill.dart';

class ShelfScreen extends StatefulWidget {
  final VoidCallback? onOpenProfile;
  final Future<void> Function(AlbumModel album)? onOpenAlbum;
  final VoidCallback? onCreateAlbum;
  final VoidCallback? onOpenActivity;
  final Future<void> Function(AlbumModel album)? onOpenPeople;

  const ShelfScreen({
    super.key,
    this.onOpenProfile,
    this.onOpenAlbum,
    this.onCreateAlbum,
    this.onOpenActivity,
    this.onOpenPeople,
  });

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen>
    with TickerProviderStateMixin {
  // Used only when no saved preference is provided, as in widget tests
  ShelfView _localView = ShelfView.stacked;

  ShelfViewPreference? get _viewPref {
    try {
      return context.read<ShelfViewPreference>();
    } catch (_) {
      return null;
    }
  }

  void _setView(ShelfView v) {
    final pref = _viewPref;
    if (pref != null) {
      unawaited(pref.set(v));
    } else {
      setState(() => _localView = v);
    }
  }

  late final DevelopStore _develop =
      DevelopStore(vsync: this, duration: Warm.develop);

  // Prevents entry animation replay after layout remounts
  final Set<String> _entered = {};

  @override
  void dispose() {
    _develop.dispose();
    super.dispose();
  }

  void _watch<T>(BuildContext context) {
    try {
      context.watch<T>();
    } catch (_) {}
  }

  SeenStore? get _seen {
    try {
      return context.read<SeenStore>();
    } catch (_) {
      return null;
    }
  }

  int _unseenFor(AlbumModel a) {
    final store = _seen;
    // Missing summary means unknown rather than zero
    if (store == null || !a.hasSummary) return 0;
    return unseenCount(
      generation: a.mediaGeneration,
      lastSeen: store.lastSeen(a.id),
      mediaCount: a.mediaCount,
    );
  }

  Future<void> _open(AlbumModel album) async {
    await _seen?.markSeen(album.id, album.mediaGeneration);
    if (!mounted) return;
    await widget.onOpenAlbum?.call(album);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _watch<SeenStore>(context);
    _watch<ShelfViewPreference>(context);
    final view = _viewPref?.view ?? _localView;
    final albums = state.albums;

    final entries = <ShelfEntry>[];
    for (final a in albums) {
      final unseen = _unseenFor(a);
      _develop.sync(a.id, unseen);
      entries.add(ShelfEntry(
        id: a.id,
        title: state.albumDisplayName(a.id),
        unseen: unseen,
        lastActivity: a.latestActivityAt,
      ));
    }
    _develop.retain({for (final a in albums) a.id});
    final headline = headlineFor(entries);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: Stack(
          children: [
            const _Ground(),
            _Scroll(
              view: view,
              albums: albums,
              headline: headline,
              unseenFor: _unseenFor,
              develop: _develop,
              entered: _entered,
              onSetView: _setView,
              onOpenProfile: widget.onOpenProfile,
              onOpenAlbum: _open,
              onCreateAlbum: widget.onCreateAlbum,
            ),
            const _BarScrim(),
            _Bar(
              unread: state.hasUnreadNotifications,
              onCreate: widget.onCreateAlbum,
              onActivity: widget.onOpenActivity,
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 132,
              child: Center(child: UploadPill()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Ground extends StatelessWidget {
  const _Ground();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          color: Warm.ground,
          gradient: RadialGradient(
            center: Alignment(0, -1.4),
            radius: 1.4,
            colors: [Warm.groundLift, Warm.ground],
          ),
        ),
        child: SizedBox.expand(),
      );
}

class _Scroll extends StatelessWidget {
  final ShelfView view;
  final List<AlbumModel> albums;
  final Headline headline;
  final int Function(AlbumModel) unseenFor;
  final DevelopStore develop;
  final Set<String> entered;
  final ValueChanged<ShelfView> onSetView;
  final VoidCallback? onOpenProfile;
  final void Function(AlbumModel) onOpenAlbum;
  final VoidCallback? onCreateAlbum;

  const _Scroll({
    required this.view,
    required this.albums,
    required this.headline,
    required this.unseenFor,
    required this.develop,
    required this.entered,
    required this.onSetView,
    required this.onOpenProfile,
    required this.onOpenAlbum,
    required this.onCreateAlbum,
  });

  @override
  Widget build(BuildContext context) {
    final plan = planFor(albums, view);

    return SafeArea(
      bottom: false,
      // Slivers prevent offscreen cards from requesting covers
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          SliverToBoxAdapter(
            child: _Header(
              view: view,
              onSetView: onSetView,
              onOpenProfile: onOpenProfile,
            ),
          ),
          SliverToBoxAdapter(child: _Say(headline: headline)),
          if (albums.isEmpty)
            SliverToBoxAdapter(child: _Blank(onTap: onCreateAlbum))
          else ...[
            _Grid(
              plan: plan,
              view: view,
              unseenFor: unseenFor,
              develop: develop,
              entered: entered,
              onOpenAlbum: onOpenAlbum,
            ),
            const SliverToBoxAdapter(child: _FootMark()),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 148)),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final ShelfView view;
  final ValueChanged<ShelfView> onSetView;
  final VoidCallback? onOpenProfile;

  const _Header(
      {required this.view,
      required this.onSetView,
      required this.onOpenProfile});

  @override
  Widget build(BuildContext context) {
    final name = context.select((AppState s) => s.profileName);
    final initial = name.trim().isEmpty ? '' : name.trim()[0].toUpperCase();
    final photo = context.select<OwnAvatarStore?, Uint8List?>(
        (o) => o?.state == OwnAvatarState.set ? o?.jpeg : null);

    return Padding(
      // Keep the 48px target centred on the previous 38px header row
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 21, Warm.pagePad, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: onOpenProfile,
            child: FaceCircle(
              size: 34,
              color: photo == null ? Warm.orbPeach : Colors.transparent,
              photo: photo,
              child: Text(initial, style: Warm.avatarInitial),
            ),
          ),
          _ViewPicker(view: view, onSelect: onSetView),
        ],
      ),
    );
  }
}

class _ViewPicker extends StatefulWidget {
  final ShelfView view;
  final ValueChanged<ShelfView> onSelect;

  const _ViewPicker({required this.view, required this.onSelect});

  @override
  State<_ViewPicker> createState() => _ViewPickerState();
}

class _ViewPickerState extends State<_ViewPicker>
    with TickerProviderStateMixin {
  late final AnimationController _split = AnimationController(
    vsync: this,
    duration: Warm.springSoft,
    value: _compact ? 1 : 0,
  );
  late final AnimationController _said = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  // Fades in, holds, fades out
  late final Animation<double> _saidOpacity = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 15),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 55),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
  ]).animate(_said);
  bool _pressed = false;

  bool get _compact => widget.view == ShelfView.compact;

  @override
  void didUpdateWidget(covariant _ViewPicker old) {
    super.didUpdateWidget(old);
    if (old.view != widget.view) {
      _split.animateTo(_compact ? 1 : 0, curve: Warm.easeSoft);
    }
  }

  @override
  void dispose() {
    _split.dispose();
    _said.dispose();
    super.dispose();
  }

  void _toggle() {
    widget.onSelect(_compact ? ShelfView.stacked : ShelfView.compact);
    _said.forward(from: 0);
  }

  void _press(bool down) => setState(() => _pressed = down);

  @override
  Widget build(BuildContext context) {
    final name = _compact ? 'Compact' : 'Stacked';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _said,
          builder: (_, child) => Opacity(
            opacity: _saidOpacity.value,
            child: Transform.translate(
              offset: Offset(6 * (1 - (_said.value / 0.15).clamp(0.0, 1.0)), 0),
              child: child,
            ),
          ),
          child: Text(name,
              key: const ValueKey('view-said'), style: Warm.viewSaid),
        ),
        Semantics(
          button: true,
          label: 'Shelf view: $name',
          excludeSemantics: true,
          child: GestureDetector(
            key: const ValueKey('view-trigger'),
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            onTapDown: (_) => _press(true),
            onTapUp: (_) => _press(false),
            onTapCancel: () => _press(false),
            // 48 to tap around the avatar sized 38
            child: SizedBox(
              width: 48,
              height: 48,
              child: Align(
                alignment: Alignment.centerRight,
                child: AnimatedScale(
                  scale: _pressed ? 0.94 : 1,
                  duration: Warm.quick,
                  curve: Warm.easeOut,
                  child: CustomPaint(
                    size: const Size.square(18),
                    painter: _LayoutGlyph(_split),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// The shelf in miniature: Compact splits the lower print in two
class _LayoutGlyph extends CustomPainter {
  final Animation<double> split;

  _LayoutGlyph(this.split) : super(repaint: split);

  @override
  void paint(Canvas canvas, Size size) {
    final t = split.value;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = Warm.ink;
    RRect r(double x, double y, double w) => RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, w, 5.6), const Radius.circular(1.5));
    final w = 12 - 6.8 * t;

    canvas.drawRRect(r(3, 2.6, 12), paint);
    canvas.drawRRect(r(3, 10, w), paint);
    canvas.drawRRect(
      r(3 + 6.8 * t, 10, w),
      paint..color = Warm.ink.withValues(alpha: t),
    );
  }

  @override
  bool shouldRepaint(_LayoutGlyph old) => old.split != split;
}

class _Say extends StatelessWidget {
  final Headline headline;

  const _Say({required this.headline});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 27, Warm.pagePad, 0),
      child: AnimatedSwitcher(
        duration: Warm.crossfade,
        switchInCurve: Warm.easeSoft,
        switchOutCurve: const FlippedCurve(Warm.easeSoft),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [...previous, if (current != null) current],
        ),
        child: Column(
          key: ValueKey('${headline.title}|${headline.sub}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(headline.title, style: Warm.h1),
            if (headline.sub.isNotEmpty) ...[
              const SizedBox(height: 9),
              Text(headline.sub, style: Warm.sub),
            ],
          ],
        ),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  final List<ShelfSlot<AlbumModel>> plan;
  final ShelfView view;
  final int Function(AlbumModel) unseenFor;
  final DevelopStore develop;
  final Set<String> entered;
  final void Function(AlbumModel) onOpenAlbum;

  const _Grid({
    required this.plan,
    required this.view,
    required this.unseenFor,
    required this.develop,
    required this.entered,
    required this.onOpenAlbum,
  });

  List<List<ShelfSlot<AlbumModel>>> _rows() {
    final rows = <List<ShelfSlot<AlbumModel>>>[];
    for (var i = 0; i < plan.length; i++) {
      final slot = plan[i];
      if (slot.size == PrintSize.large) {
        rows.add([slot]);
        continue;
      }
      final next = i + 1 < plan.length ? plan[i + 1] : null;
      if (next != null && next.size == PrintSize.small) {
        rows.add([slot, next]);
        i++;
      } else {
        rows.add([slot]);
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rowGap = view == ShelfView.compact ? 16.0 : 30.0;
    final rows = _rows();
    var seen = 0;
    final starts = [for (final r in rows) (seen += r.length) - r.length];

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 32, Warm.pagePad, 0),
      sliver: SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, r) {
          final row = rows[r];
          final gap = r > 0 ? rowGap : 0.0;
          final Widget content = row.first.size == PrintSize.large
              ? _card(row.first, starts[r])
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _card(row.first, starts[r])),
                    const SizedBox(width: 12),
                    Expanded(
                      child: row.length > 1
                          ? _card(row[1], starts[r] + 1)
                          : const SizedBox.shrink(),
                    ),
                  ],
                );
          return Padding(
            padding: EdgeInsets.only(top: gap),
            child: content,
          );
        },
      ),
    );
  }

  Widget _card(ShelfSlot<AlbumModel> slot, int index) {
    final a = slot.album;
    return _ShelfCard(
      key: ValueKey(a.id),
      album: a,
      size: slot.size,
      index: index,
      unseen: unseenFor(a),
      develop: develop.sync(a.id, unseenFor(a)),
      hasEntered: entered.contains(a.id),
      onEntered: () => entered.add(a.id),
      onTap: () => onOpenAlbum(a),
    );
  }
}

class _ShelfCard extends StatefulWidget {
  final AlbumModel album;
  final PrintSize size;
  final int index;
  final int unseen;
  final Animation<double> develop;
  final bool hasEntered;
  final VoidCallback onEntered;
  final VoidCallback onTap;

  const _ShelfCard({
    super.key,
    required this.album,
    required this.size,
    required this.index,
    required this.unseen,
    required this.develop,
    required this.hasEntered,
    required this.onEntered,
    required this.onTap,
  });

  @override
  State<_ShelfCard> createState() => _ShelfCardState();
}

class _ShelfCardState extends State<_ShelfCard> {
  late bool _entered = widget.hasEntered;
  Timer? _enter;
  bool _lifted = false;

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
    if (!_entered) {
      final delay =
          Warm.cardStaggerOffset + Warm.cardStagger * (widget.index % 6);
      _enter = Timer(delay, () {
        if (!mounted) return;
        widget.onEntered();
        setState(() => _entered = true);
      });
    }
    _requestCover();
  }

  @override
  void didUpdateWidget(covariant _ShelfCard old) {
    super.didUpdateWidget(old);
    if (old.album.previewMedia.length != widget.album.previewMedia.length ||
        _firstPreviewId(old.album) != _firstPreviewId(widget.album)) {
      _requestCover();
    }
  }

  static String? _firstPreviewId(AlbumModel a) =>
      a.previewMedia.isEmpty ? null : a.previewMedia.first.mediaId;

  void _requestCover() {
    if (widget.album.previewMedia.isEmpty) return;
    _covers?.ensureCover(widget.album.id, widget.album.previewMedia);
  }

  @override
  void dispose() {
    _enter?.cancel();
    super.dispose();
  }

  Widget? _image(int slot) {
    final bytes = _covers?.bytes(widget.album.id, slot);
    if (bytes == null) return null;
    return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
  }

  Widget _print({
    required PrintSize size,
    bool fanned = false,
    bool tilted = true,
    VoidCallback? onHold,
    VoidCallback? onTap,
    void Function(Rect)? onPeek,
  }) {
    final state = context.read<AppState>();
    return AlbumPrint(
      albumId: widget.album.id,
      title: state.albumDisplayName(widget.album.id),
      mediaCount: widget.album.mediaCount,
      unseen: widget.unseen,
      lastActivity: widget.album.latestActivityAt,
      members: widget.album.memberPreviews,
      totalMembers: widget.album.activeMemberCount,
      nameOf: (m) => state.memberDisplayName(widget.album.id, m.memberToken),
      develop: widget.develop,
      size: size,
      cover: _image(0),
      behind: [_image(1), _image(2)].nonNulls.toList(),
      fanned: fanned,
      tilted: tilted,
      onHold: onHold,
      onTap: onTap,
      onPeek: onPeek,
    );
  }

  Future<void> _peek(Rect from) async {
    HapticFeedback.selectionClick();
    final route = ShelfPeek.route(
      album: widget.album,
      from: from,
      tilt: tiltFor(widget.album.id, small: widget.size == PrintSize.small),
      print: ({required fanned}) {
        Widget print() =>
            _print(size: PrintSize.large, fanned: fanned, tilted: false);
        final covers = _covers;
        // Riffle images may still be decrypting when the peek opens
        return covers == null
            ? print()
            : ListenableBuilder(
                listenable: covers, builder: (_, __) => print());
      },
    );
    setState(() => _lifted = true);
    // Stay hidden until the print has flown back or tucked away
    unawaited(route.completed.then((_) {
      if (mounted) setState(() => _lifted = false);
    }));
    final action =
        await Navigator.of(context, rootNavigator: true).push(route);
    if (!mounted) return;
    switch (action) {
      case ShelfPeekAction.open:
        widget.onTap();
      case ShelfPeekAction.people:
        final people =
            context.findAncestorWidgetOfExactType<ShelfScreen>()?.onOpenPeople;
        await people?.call(widget.album);
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final covers = _covers;
    if (covers != null) context.watch<ShelfCovers>();
    context.watch<AppState>();

    return AnimatedSlide(
      offset: _entered ? Offset.zero : const Offset(0, 0.07),
      duration: Warm.springSoft,
      curve: Warm.easeSoft,
      child: AnimatedOpacity(
        opacity: _entered ? 1 : 0,
        duration: Warm.springSoft,
        curve: Warm.easeSoft,
        child: Opacity(
          opacity: _lifted ? 0 : 1,
          child: _print(
            size: widget.size,
            onHold: () => covers?.ensureRiffle(
                widget.album.id, widget.album.previewMedia),
            onTap: widget.onTap,
            onPeek: _peek,
          ),
        ),
      ),
    );
  }
}

class _Blank extends StatelessWidget {
  final VoidCallback? onTap;

  const _Blank({this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 32, Warm.pagePad, 0),
      child: GestureDetector(
        onTap: onTap,
        child: Transform.rotate(
          angle: -1.4 * 3.141592653589793 / 180,
          child: PrintCard(
            frame: true,
            blank: true,
            chin: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Your first album', style: Warm.cardTitle),
                  const SizedBox(height: 5),
                  Text('Tap to make it', style: Warm.meta),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FootMark extends StatelessWidget {
  const _FootMark();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 38),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock_outline_rounded,
              size: 11, color: Warm.inkFaint),
          const SizedBox(width: 5),
          Text('END-TO-END ENCRYPTED', style: Warm.sectionLabel),
        ],
      ),
    );
  }
}

class _BarScrim extends StatelessWidget {
  const _BarScrim();

  @override
  Widget build(BuildContext context) => const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: FootScrim(height: 190),
      );
}

class _Bar extends StatelessWidget {
  final bool unread;
  final VoidCallback? onCreate;
  final VoidCallback? onActivity;

  const _Bar(
      {required this.unread, required this.onCreate, required this.onActivity});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: 96 + bottom,
      child: Padding(
        padding: EdgeInsets.only(left: 44, right: 44, bottom: 18 + bottom),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Albums', style: Warm.tab.copyWith(color: Warm.ink)),
            MakeButton(onTap: onCreate),
            GestureDetector(
              onTap: onActivity,
              behavior: HitTestBehavior.opaque,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Text('Activity', style: Warm.tab),
                  if (unread)
                    const Positioned(
                      top: 4,
                      right: -7,
                      child: SizedBox(
                        width: 5,
                        height: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Warm.warn,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
