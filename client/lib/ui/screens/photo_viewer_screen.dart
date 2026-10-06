import 'dart:async';

import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/photo_peek.dart';
import 'package:miuchio/ui/album/photo_sheets.dart';
import 'package:miuchio/ui/widgets/encrypted_image.dart';
import 'package:miuchio/ui/widgets/encrypted_thumbnail.dart';

class PhotoViewerScreen extends StatefulWidget {
  final List<MediaRecord> records;
  final int initialIndex;
  final MediaCacheManager cache;
  final String? Function(String token) nameOf;
  final Widget Function(String token, double size) faceOf;
  final bool Function(MediaRecord record) isOwner;
  // Return true only after deletion succeeds
  final Future<bool> Function(MediaRecord record) onDelete;
  final Widget Function(MediaRecord record, int cacheWidth)? imageBuilder;

  const PhotoViewerScreen({
    super.key,
    required this.records,
    required this.initialIndex,
    required this.cache,
    required this.nameOf,
    required this.faceOf,
    required this.isOwner,
    required this.onDelete,
    this.imageBuilder,
  });

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  static const _swipe = 70.0;
  static const _flick = 520.0;

  late final List<MediaRecord> _records = [...widget.records];
  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _chrome = false;
  bool _zoomed = false;
  bool _deleting = false;
  double _dragY = 0;
  String? _note;
  Timer? _noteTimer;

  MediaRecord get _current => _records[_index];

  @override
  void dispose() {
    _noteTimer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  void _say(String note) {
    _noteTimer?.cancel();
    setState(() => _note = note);
    _noteTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _note = null);
    });
  }

  String? _nameOf(MediaRecord r) =>
      widget.isOwner(r) ? AlbumCopy.you : widget.nameOf(r.uploaderToken);

  Future<void> _details() => showPhotoDetails(
        context,
        record: _current,
        face: widget.faceOf(_current.uploaderToken, 40),
        name: _nameOf(_current),
        mine: widget.isOwner(_current),
      );

  void _onVerticalEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final dy = _dragY;
    _dragY = 0;
    if (dy < -_swipe || v < -_flick) {
      _details();
    } else if (dy > _swipe * 1.3 || v > _flick) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _delete() async {
    if (_deleting || !await confirmPhotoDelete(context)) return;
    final record = _current;
    setState(() => _deleting = true);
    final gone = await widget.onDelete(record);
    if (!mounted) return;
    setState(() {
      _deleting = false;
      if (!gone) return;
      _records.removeWhere((r) => r.id == record.id);
      if (_index > _records.length - 1) _index = _records.length - 1;
    });
    if (!gone) return;
    if (_records.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    if (_pages.hasClients) _pages.jumpToPage(_index);
  }

  @override
  Widget build(BuildContext context) {
    // Bound decoded image memory by the display resolution
    final media = MediaQuery.of(context);
    final cap = (media.size.longestSide * media.devicePixelRatio).round();
    if (_records.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    final record = _current;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        // The default theme uses dark status bar icons
        systemOverlayStyle: Warm.overlayOnPeek,
        automaticallyImplyLeading: false,
        toolbarHeight: 0,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onVerticalDragUpdate: _zoomed ? null : (d) => _dragY += d.delta.dy,
            onVerticalDragEnd: _zoomed ? null : _onVerticalEnd,
            child: PageView.builder(
              key: const Key('photo-viewer-pages'),
              controller: _pages,
              // Let zoomed photos pan without changing pages
              physics: _zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: _records.length,
              onPageChanged: (i) => setState(() {
                _index = i;
                _zoomed = false;
              }),
              itemBuilder: (context, i) => _ZoomPage(
                key: ValueKey(_records[i].id),
                onTap: () => setState(() => _chrome = !_chrome),
                onZoom: (zoomed) {
                  if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
                },
                child: widget.imageBuilder?.call(_records[i], cap) ??
                    _FullPhoto(
                      record: _records[i],
                      cache: widget.cache,
                      cacheWidth: cap,
                    ),
              ),
            ),
          ),
          _Chrome(
            visible: _chrome,
            top: _TopBar(
              face: widget.faceOf(record.uploaderToken, 28),
              name: _nameOf(record) ?? AlbumCopy.unknownMember,
              day: formatPhotoDay(record.createdAt),
            ),
            bottom: _BottomBar(
              owner: widget.isOwner(record),
              onHeart: () => _say(AlbumCopy.heartSoon),
              onSave: () => _say(AlbumCopy.saveSoon),
              onDelete: _delete,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: media.padding.top + 64,
            child: IgnorePointer(
              child: Center(
                child: AnimatedOpacity(
                  opacity: _note == null ? 0 : 1,
                  duration: Warm.quick,
                  child: PeekNote(text: _note ?? ''),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FullPhoto extends StatefulWidget {
  final MediaRecord record;
  final MediaCacheManager cache;
  final int cacheWidth;

  const _FullPhoto({
    required this.record,
    required this.cache,
    required this.cacheWidth,
  });

  @override
  State<_FullPhoto> createState() => _FullPhotoState();
}

class _FullPhotoState extends State<_FullPhoto> {
  bool _ready = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.record.hasThumb)
          EncryptedThumbnail(
            record: widget.record,
            cache: widget.cache,
            fit: BoxFit.contain,
          ),
        AnimatedOpacity(
          opacity: _ready || !widget.record.hasThumb ? 1 : 0,
          duration: const Duration(milliseconds: 140),
          curve: Warm.easeOut,
          child: EncryptedImage(
            record: widget.record,
            cache: widget.cache,
            fit: BoxFit.contain,
            cacheWidth: widget.cacheWidth,
            onFirstFrame: () {
              if (mounted) setState(() => _ready = true);
            },
          ),
        ),
      ],
    );
  }
}

class _ZoomPage extends StatefulWidget {
  final VoidCallback onTap;
  final ValueChanged<bool> onZoom;
  final Widget child;

  const _ZoomPage({
    super.key,
    required this.onTap,
    required this.onZoom,
    required this.child,
  });

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage>
    with SingleTickerProviderStateMixin {
  static const _doubleTapScale = 2.5;

  final TransformationController _zoom = TransformationController();
  late final AnimationController _anim;
  late final CurvedAnimation _curve;
  Matrix4Tween? _tween;
  Offset _tapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        final tween = _tween;
        if (tween != null) _zoom.value = tween.evaluate(_curve);
      });
    _curve = CurvedAnimation(parent: _anim, curve: Warm.easeOut);
  }

  bool get _isZoomed => _zoom.value.getMaxScaleOnAxis() > 1.01;

  @override
  void dispose() {
    _curve.dispose();
    _anim.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _animateTo(Matrix4 target) {
    _tween = Matrix4Tween(begin: _zoom.value, end: target);
    _anim.forward(from: 0).whenComplete(() => widget.onZoom(_isZoomed));
  }

  void _onDoubleTap() {
    if (_isZoomed) {
      _animateTo(Matrix4.identity());
      return;
    }
    // Anchor the zoom at the tapped point
    const s = _doubleTapScale;
    _animateTo(Matrix4.identity()
      ..translateByDouble(-_tapAt.dx * (s - 1), -_tapAt.dy * (s - 1), 0, 1)
      ..scaleByDouble(s, s, 1, 1));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _tapAt = d.localPosition,
      onDoubleTap: _onDoubleTap,
      child: InteractiveViewer(
        transformationController: _zoom,
        minScale: 1,
        maxScale: 4,
        onInteractionEnd: (_) => widget.onZoom(_isZoomed),
        child: SizedBox.expand(child: widget.child),
      ),
    );
  }
}

class _Chrome extends StatelessWidget {
  final bool visible;
  final Widget top;
  final Widget bottom;

  const _Chrome({
    required this.visible,
    required this.top,
    required this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        key: const Key('photo-viewer-chrome'),
        opacity: visible ? 1 : 0,
        duration: Warm.quick,
        curve: Warm.easeOut,
        child: Column(
          children: [
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
              child: SafeArea(bottom: false, child: top),
            ),
            const Spacer(),
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
              child: SafeArea(top: false, child: bottom),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final Widget face;
  final String name;
  final String day;

  const _TopBar({required this.face, required this.name, required this.day});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 16, 18),
      child: Row(
        children: [
          IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          ),
          face,
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          Container(
            width: 2.5,
            height: 2.5,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: const BoxDecoration(
              color: Color(0x80FFFFFF),
              shape: BoxShape.circle,
            ),
          ),
          Text(
            day,
            style: const TextStyle(fontSize: 13, color: Color(0xB3FFFFFF)),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final bool owner;
  final VoidCallback onHeart;
  final VoidCallback onSave;
  final VoidCallback onDelete;

  const _BottomBar({
    required this.owner,
    required this.onHeart,
    required this.onSave,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
      child: Center(
        child: PeekDock(
          owner: owner,
          onHeart: onHeart,
          onSave: onSave,
          onDelete: onDelete,
        ),
      ),
    );
  }
}
