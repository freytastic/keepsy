import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:keepsy/data/models/album_model.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/shelf/album_print.dart';
import 'package:keepsy/ui/shelf/develop_store.dart';
import 'package:keepsy/ui/shelf/shelf_copy.dart';
import 'package:keepsy/ui/shelf/shelf_data.dart';
import 'package:keepsy/ui/shelf/shelf_layout.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/print_card.dart';
import 'package:keepsy/ui/widgets/upload_pill.dart';

class ShelfScreen extends StatefulWidget {
  final VoidCallback? onOpenProfile;
  final Future<void> Function(AlbumModel album)? onOpenAlbum;
  final VoidCallback? onCreateAlbum;
  final VoidCallback? onOpenActivity;

  const ShelfScreen({
    super.key,
    this.onOpenProfile,
    this.onOpenAlbum,
    this.onCreateAlbum,
    this.onOpenActivity,
  });

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen>
    with TickerProviderStateMixin {
  ShelfView _view = ShelfView.rows;

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
              view: _view,
              albums: albums,
              headline: headline,
              unseenFor: _unseenFor,
              develop: _develop,
              entered: _entered,
              onSetView: (v) => setState(() => _view = v),
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 26, Warm.pagePad, 0),
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
          Transform.translate(
            offset: const Offset(8, 0),
            child: Row(
              children: [
                _ViewButton(
                  on: view == ShelfView.rows,
                  bento: false,
                  onTap: () => onSetView(ShelfView.rows),
                ),
                _ViewButton(
                  on: view == ShelfView.bento,
                  bento: true,
                  onTap: () => onSetView(ShelfView.bento),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewButton extends StatelessWidget {
  final bool on;
  final bool bento;
  final VoidCallback onTap;

  const _ViewButton(
      {required this.on, required this.bento, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: AnimatedContainer(
          duration: Warm.quick,
          curve: Warm.easeOut,
          width: 19,
          height: 19,
          child: CustomPaint(
            painter: _ViewGlyph(
              bento: bento,
              color: on ? Warm.ink : Warm.inkFaint,
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewGlyph extends CustomPainter {
  final bool bento;
  final Color color;

  const _ViewGlyph({required this.bento, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 19;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..color = color;

    void box(double x, double y, double w, double h) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x * k, y * k, w * k, h * k),
          Radius.circular(1.5 * k),
        ),
        paint,
      );
    }

    box(2.9, 2.4, 13.2, 5.9);
    if (bento) {
      box(2.9, 10.3, 5.9, 5.9);
      box(10.2, 10.3, 5.9, 5.9);
    } else {
      box(2.9, 10.3, 13.2, 5.9);
    }
  }

  @override
  bool shouldRepaint(_ViewGlyph old) =>
      old.bento != bento || old.color != color;
}

class _Say extends StatelessWidget {
  final Headline headline;

  const _Say({required this.headline});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 32, Warm.pagePad, 0),
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
    final rowGap = view == ShelfView.bento ? 16.0 : 30.0;
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

  @override
  Widget build(BuildContext context) {
    final covers = _covers;
    if (covers != null) context.watch<ShelfCovers>();

    final behind = <Widget>[];
    for (final slot in [1, 2]) {
      final img = _image(slot);
      if (img != null) behind.add(img);
    }

    final state = context.watch<AppState>();

    return AnimatedSlide(
      offset: _entered ? Offset.zero : const Offset(0, 0.07),
      duration: Warm.springSoft,
      curve: Warm.easeSoft,
      child: AnimatedOpacity(
        opacity: _entered ? 1 : 0,
        duration: Warm.springSoft,
        curve: Warm.easeSoft,
        child: AlbumPrint(
          albumId: widget.album.id,
          title: state.albumDisplayName(widget.album.id),
          mediaCount: widget.album.mediaCount,
          unseen: widget.unseen,
          lastActivity: widget.album.latestActivityAt,
          members: widget.album.memberPreviews,
          totalMembers: widget.album.activeMemberCount,
          nameOf: (m) =>
              state.memberDisplayName(widget.album.id, m.memberToken),
          develop: widget.develop,
          size: widget.size,
          cover: _image(0),
          behind: behind,
          onHold: () =>
              covers?.ensureRiffle(widget.album.id, widget.album.previewMedia),
          onTap: widget.onTap,
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
        height: 190,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x00F6F3EE),
                  Color(0x80F6F3EE),
                  Color(0xE6F6F3EE),
                  Warm.ground,
                  Warm.ground,
                ],
                stops: [0, 0.26, 0.5, 0.66, 1],
              ),
            ),
          ),
        ),
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
            _MakeButton(onTap: onCreate),
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

class _MakeButton extends StatefulWidget {
  final VoidCallback? onTap;

  const _MakeButton({required this.onTap});

  @override
  State<_MakeButton> createState() => _MakeButtonState();
}

class _MakeButtonState extends State<_MakeButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap?.call();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1,
        duration: Warm.quick,
        curve: Warm.easeOut,
        child: SizedBox(
          width: 58,
          height: 58,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: _pressed ? 1 : 0.45,
                  duration: Warm.quick,
                  child: const _MakeGlow(),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: Warm.ctaFill,
                  shape: BoxShape.circle,
                  boxShadow: Warm.ctaShadow,
                ),
                child: const SizedBox(
                  width: 58,
                  height: 58,
                  child: Icon(Icons.add_rounded, size: 21, color: Warm.ctaInk),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MakeGlow extends StatelessWidget {
  const _MakeGlow();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _GlowPainter());
}

class _GlowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.width * 0.84;
    final paint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
      ..shader = RadialGradient(
        colors: [
          Warm.orbPeach.withValues(alpha: 0.6),
          Warm.orbBlush.withValues(alpha: 0.3),
          Warm.orbPeach.withValues(alpha: 0),
        ],
        stops: const [0, 0.45, 0.72],
      ).createShader(Rect.fromCircle(center: centre, radius: radius));
    canvas.drawCircle(centre, radius, paint);
  }

  @override
  bool shouldRepaint(_GlowPainter old) => false;
}
