import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/models/album_model.dart';
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
import 'package:keepsy/ui/widgets/print_card.dart';
import 'package:keepsy/ui/widgets/upload_pill.dart';

class ShelfScreen extends StatefulWidget {
  final VoidCallback? onOpenProfile;
  final Future<void> Function(AlbumModel album)? onOpenAlbum;
  final Future<void> Function(AlbumModel album)? onOpenPeople;
  final VoidCallback? onCreateAlbum;
  final VoidCallback? onOpenActivity;

  const ShelfScreen({
    super.key,
    this.onOpenProfile,
    this.onOpenAlbum,
    this.onOpenPeople,
    this.onCreateAlbum,
    this.onOpenActivity,
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

  Future<void> _open(AlbumModel album, {bool people = false}) async {
    await _seen?.markSeen(album.id, album.mediaGeneration);
    if (!mounted) return;
    await (people ? widget.onOpenPeople : widget.onOpenAlbum)?.call(album);
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
              onOpenPeople: (a) => _open(a, people: true),
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
  final void Function(AlbumModel) onOpenPeople;
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
    required this.onOpenPeople,
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
              onOpenPeople: onOpenPeople,
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

    return Padding(
      // Keep the 48px target centred on the previous 38px header row
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 21, Warm.pagePad, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: onOpenProfile,
            child: Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: Warm.stoneFill,
                shape: BoxShape.circle,
                boxShadow: Warm.avatarShadow,
              ),
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
    with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  // Created eagerly: a lazy controller would first be built inside dispose()
  late final AnimationController _anim;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 150),
    );
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _toggle() => _open ? _close() : _show();

  void _show() {
    setState(() => _open = true);
    _portal.show();
    _anim.forward();
  }

  Future<void> _close() async {
    if (!_open) return;
    setState(() => _open = false);
    await _anim.reverse();
    if (mounted && !_open) _portal.hide();
  }

  void _choose(ShelfView v) {
    widget.onSelect(v);
    _close();
  }

  @override
  Widget build(BuildContext context) {
    // The menu is an overlay, not a route, so back would otherwise pop the
    // shelf itself (on the root route: leave the app)
    return PopScope(
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (_) => Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 2),
              child: AnimatedBuilder(
                animation: _anim,
                builder: (_, child) {
                  final t = Curves.easeOutCubic.transform(_anim.value);
                  return Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, -6 * (1 - t)),
                      child: Transform.scale(
                        scale: 0.97 + 0.03 * t,
                        alignment: Alignment.topRight,
                        child: child,
                      ),
                    ),
                  );
                },
                child: _ViewMenu(view: widget.view, onSelect: _choose),
              ),
            ),
          ],
        ),
        child: Semantics(
          button: true,
          expanded: _open,
          label: 'Shelf view: '
              '${widget.view == ShelfView.stacked ? 'Stacked' : 'Compact'}',
          excludeSemantics: true,
          child: GestureDetector(
            key: const ValueKey('view-trigger'),
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            // Preserve a 48px target around the 34px visual pill
            child: SizedBox(
              height: 48,
              child: Center(
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.fromLTRB(11, 0, 9, 0),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(17),
                    gradient: Warm.acStoneFill,
                    boxShadow: [
                      BoxShadow(
                          color: Warm.shadow(0.05),
                          blurRadius: 2,
                          offset: const Offset(0, 1)),
                      BoxShadow(
                          color: Warm.shadow(0.045),
                          blurRadius: 8,
                          offset: const Offset(0, 3)),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('View', style: Warm.viewLabel),
                      const SizedBox(width: 5),
                      AnimatedRotation(
                        turns: _open ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const Icon(Icons.keyboard_arrow_down_rounded,
                            size: 15, color: Warm.inkFaint),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewMenu extends StatelessWidget {
  final ShelfView view;
  final ValueChanged<ShelfView> onSelect;

  const _ViewMenu({required this.view, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 158,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        gradient: Warm.stoneFill,
        boxShadow: [
          BoxShadow(
              color: Warm.shadow(0.07),
              blurRadius: 4,
              offset: const Offset(0, 2)),
          BoxShadow(
              color: Warm.shadow(0.12),
              blurRadius: 30,
              offset: const Offset(0, 12)),
          BoxShadow(
              color: Warm.shadow(0.08),
              blurRadius: 56,
              offset: const Offset(0, 28)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ViewOption(
            id: 'stacked',
            title: 'Stacked',
            selected: view == ShelfView.stacked,
            onTap: () => onSelect(ShelfView.stacked),
          ),
          _ViewOption(
            id: 'compact',
            title: 'Compact',
            selected: view == ShelfView.compact,
            onTap: () => onSelect(ShelfView.compact),
          ),
        ],
      ),
    );
  }
}

class _ViewOption extends StatelessWidget {
  final String id;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _ViewOption({
    required this.id,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        key: ValueKey('view-option-$id'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 48,
          padding: const EdgeInsets.fromLTRB(11, 0, 8, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            color: selected ? const Color(0x0D1C1917) : null,
          ),
          child: Row(
            children: [
              Expanded(child: Text(title, style: Warm.viewOption)),
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0x0D1C1917),
                ),
                child: selected
                    ? Icon(Icons.check_rounded,
                        key: ValueKey('view-check-$id'),
                        size: 13,
                        color: Warm.inkSoft)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
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
  final void Function(AlbumModel) onOpenPeople;

  const _Grid({
    required this.plan,
    required this.view,
    required this.unseenFor,
    required this.develop,
    required this.entered,
    required this.onOpenAlbum,
    required this.onOpenPeople,
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
      onPeople: () => onOpenPeople(a),
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
  final VoidCallback onPeople;

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
    required this.onPeople,
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
    final action = await Navigator.of(context, rootNavigator: true).push(route);
    switch (action) {
      case ShelfPeekAction.open:
        widget.onTap();
      case ShelfPeekAction.people:
        widget.onPeople();
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
