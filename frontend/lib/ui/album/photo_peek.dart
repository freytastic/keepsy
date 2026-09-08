import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:keepsy/e2ee/media_record.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/blur_scrim.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';

import 'album_copy.dart';
import 'album_stats.dart';

typedef PeekFullImageBuilder = Widget Function(
  BuildContext context,
  int cacheWidth,
  int cacheHeight,
  VoidCallback onReady,
);

class PhotoPeek extends StatefulWidget {
  final MediaRecord record;
  final Animation<double> entry;
  final String? uploaderName;
  final bool isOwner;
  final Future<void> Function() onDelete;
  final double aspectRatio;
  final WidgetBuilder previewBuilder;
  final PeekFullImageBuilder fullImageBuilder;
  final DateTime Function()? now;

  const PhotoPeek({
    super.key,
    required this.record,
    required this.uploaderName,
    required this.isOwner,
    required this.onDelete,
    required this.aspectRatio,
    required this.previewBuilder,
    required this.fullImageBuilder,
    this.entry = kAlwaysCompleteAnimation,
    this.now,
  });

  static Future<void> show(
    BuildContext context, {
    required MediaRecord record,
    required String? uploaderName,
    required bool isOwner,
    required Future<void> Function() onDelete,
    required double aspectRatio,
    required WidgetBuilder previewBuilder,
    required PeekFullImageBuilder fullImageBuilder,
  }) =>
      Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: Warm.quick,
        reverseTransitionDuration: Warm.quick,
        allowSnapshotting: false,
        pageBuilder: (_, a, __) => PhotoPeek(
          record: record,
          uploaderName: uploaderName,
          isOwner: isOwner,
          onDelete: onDelete,
          aspectRatio: aspectRatio,
          previewBuilder: previewBuilder,
          fullImageBuilder: fullImageBuilder,
          entry: a,
        ),
        transitionsBuilder: (_, __, ___, child) => child,
      ));

  @override
  State<PhotoPeek> createState() => _PhotoPeekState();
}

class _PhotoPeekState extends State<PhotoPeek> with TickerProviderStateMixin {
  static const _photoSpring = SpringDescription(
    mass: 1.1,
    stiffness: 90,
    damping: 20,
  );
  static const _controlSpring = SpringDescription(
    mass: 1,
    stiffness: 320,
    damping: 26,
  );

  late final Animation<double> _entry = CurvedAnimation(
    parent: widget.entry,
    curve: Warm.easeOut,
    reverseCurve: Warm.easeOut,
  );
  late final AnimationController _photo = AnimationController.unbounded(
    vsync: this,
  )..animateWith(SpringSimulation(_photoSpring, 0, 1, 0));
  late final AnimationController _sharpen = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..forward();
  late final Animation<double> _sharp = CurvedAnimation(
    parent: _sharpen,
    curve: Curves.easeOut,
  );
  late final AnimationController _caption = AnimationController(
    vsync: this,
    duration: Warm.quick,
  );
  late final AnimationController _controls = AnimationController.unbounded(
    vsync: this,
  );
  late final Timer _captionDelay;
  late final Timer _controlsDelay;

  @override
  void initState() {
    super.initState();
    _captionDelay = Timer(
      const Duration(milliseconds: 60),
      () => _caption.forward(),
    );
    _controlsDelay = Timer(
      const Duration(milliseconds: 40),
      () => _controls.animateWith(SpringSimulation(_controlSpring, 0, 1, 0)),
    );
  }

  @override
  void dispose() {
    _captionDelay.cancel();
    _controlsDelay.cancel();
    (_entry as CurvedAnimation).dispose();
    (_sharp as CurvedAnimation).dispose();
    _photo.dispose();
    _sharpen.dispose();
    _caption.dispose();
    _controls.dispose();
    super.dispose();
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: Warm.paper,
        title: const Text(AlbumCopy.deleteTitle,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: const Text(AlbumCopy.deleteBody,
            style: TextStyle(fontSize: 13.5, color: Warm.inkSoft)),
        actions: [
          PressableScale(
            onTap: () => Navigator.of(dialog).pop(false),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(AlbumCopy.deleteCancel,
                  style: TextStyle(color: Warm.inkSoft)),
            ),
          ),
          PressableScale(
            onTap: () => Navigator.of(dialog).pop(true),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(AlbumCopy.deleteConfirm,
                  style:
                      TextStyle(color: Warm.warn, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
    if (ok == true) await widget.onDelete();
  }

  void _keepOpen() {}

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnPeek,
      child: Stack(
        fit: StackFit.expand,
        children: [
          BlurScrim(
            progress: _entry,
            color: Warm.peekScrim,
            onTap: () => Navigator.of(context).maybePop(),
          ),
          Material(
            type: MaterialType.transparency,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => Navigator.of(context).maybePop(),
              child: FadeTransition(
                opacity: _entry,
                child: SafeArea(
                  child: LayoutBuilder(
                    builder: (context, bounds) {
                      final ratio =
                          widget.aspectRatio > 0 ? widget.aspectRatio : 1.0;
                      final maxWidth = math.max(0.0, bounds.maxWidth - 44);
                      final photoWidth = math.min(
                        maxWidth,
                        MediaQuery.sizeOf(context).height * 0.44 * ratio,
                      );
                      final photoHeight = photoWidth / ratio;
                      final dpr = MediaQuery.devicePixelRatioOf(context);
                      final cacheWidth = math.max(1, (photoWidth * dpr).ceil());
                      final cacheHeight =
                          math.max(1, (photoHeight * dpr).ceil());

                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(22, 26, 22, 26),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: math.max(0, bounds.maxHeight - 52),
                          ),
                          child: GestureDetector(
                            onTap: _keepOpen,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  key: const Key('photo-peek-frame'),
                                  width: photoWidth,
                                  height: photoHeight,
                                  child: _Photo(
                                    sharpen: _sharp,
                                    settle: _photo,
                                    child: _PeekImage(
                                      previewBuilder: widget.previewBuilder,
                                      fullImageBuilder: widget.fullImageBuilder,
                                      cacheWidth: cacheWidth,
                                      cacheHeight: cacheHeight,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                _Rise(
                                  at: _caption,
                                  from: 6,
                                  child: _Caption(
                                    uploader: widget.uploaderName,
                                    createdAt: widget.record.createdAt,
                                    bytes:
                                        AlbumStats.storedBytes(widget.record),
                                    now: widget.now,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                _Rise(
                                  at: _controls,
                                  from: 10,
                                  scaleFrom: 0.96,
                                  child: const ReactionRow(),
                                ),
                                const SizedBox(height: 14),
                                const _SayBar(),
                                const SizedBox(height: 18),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const PeekAction(
                                      icon: Icons.download_rounded,
                                      label: AlbumCopy.save,
                                      onTap: null,
                                    ),
                                    if (widget.isOwner) ...[
                                      const SizedBox(width: 22),
                                      PeekAction(
                                        icon: Icons.delete_outline_rounded,
                                        label: AlbumCopy.delete,
                                        danger: true,
                                        onTap: _confirmDelete,
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Rise extends StatelessWidget {
  final Animation<double> at;
  final double from;
  final double scaleFrom;
  final Widget child;

  const _Rise({
    required this.at,
    required this.from,
    required this.child,
    this.scaleFrom = 1,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: at,
      builder: (context, inner) {
        final t = at.value;
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, from * (1 - t)),
            child: scaleFrom == 1
                ? inner
                : Transform.scale(
                    scale: scaleFrom + (1 - scaleFrom) * t, child: inner),
          ),
        );
      },
      child: child,
    );
  }
}

class _Photo extends StatelessWidget {
  final Animation<double> sharpen;
  final Animation<double> settle;
  final Widget child;

  const _Photo({
    required this.sharpen,
    required this.settle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([sharpen, settle]),
      builder: (context, inner) {
        final t = settle.value;
        final blur = 14 * (1 - sharpen.value);
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.9 + 0.1 * t,
            child: blur < 0.05
                ? inner
                : ImageFiltered(
                    imageFilter:
                        ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                    child: inner,
                  ),
          ),
        );
      },
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Warm.wellEmpty,
            borderRadius: BorderRadius.circular(9),
            boxShadow: const [
              BoxShadow(
                color: Color(0x38000000),
                offset: Offset(0, 2),
                blurRadius: 6,
              ),
              BoxShadow(
                color: Color(0x57000000),
                offset: Offset(0, 18),
                blurRadius: 50,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(9),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _PeekImage extends StatefulWidget {
  final WidgetBuilder previewBuilder;
  final PeekFullImageBuilder fullImageBuilder;
  final int cacheWidth;
  final int cacheHeight;

  const _PeekImage({
    required this.previewBuilder,
    required this.fullImageBuilder,
    required this.cacheWidth,
    required this.cacheHeight,
  });

  @override
  State<_PeekImage> createState() => _PeekImageState();
}

class _PeekImageState extends State<_PeekImage> {
  bool _fullReady = false;

  void _showFull() {
    if (!_fullReady && mounted) setState(() => _fullReady = true);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.previewBuilder(context),
        AnimatedOpacity(
          key: const Key('photo-peek-full'),
          opacity: _fullReady ? 1 : 0,
          duration: const Duration(milliseconds: 140),
          curve: Warm.easeOut,
          child: widget.fullImageBuilder(
            context,
            widget.cacheWidth,
            widget.cacheHeight,
            _showFull,
          ),
        ),
      ],
    );
  }
}

class _Caption extends StatelessWidget {
  final String? uploader;
  final DateTime createdAt;
  final int bytes;
  final DateTime Function()? now;

  const _Caption({
    required this.uploader,
    required this.createdAt,
    required this.bytes,
    this.now,
  });

  @override
  Widget build(BuildContext context) {
    final when = formatWhen(createdAt, now: now?.call());
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          uploader ?? AlbumCopy.unknownMember,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: Color(0xF0FFFFFF),
          ),
        ),
        const _CaptionDot(),
        Text(
          when,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: Color(0xA8FFFFFF),
          ),
        ),
        const _CaptionDot(),
        Text(
          AlbumStats.formatBytes(bytes),
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: Color(0xA8FFFFFF),
          ),
        ),
      ],
    );
  }

  static String formatWhen(DateTime at, {DateTime? now}) {
    final today = now ?? DateTime.now();
    final days = DateTime(today.year, today.month, today.day)
        .difference(DateTime(at.year, at.month, at.day))
        .inDays;
    if (days == 0) return 'Today';
    if (days == 1) return 'Yesterday';
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June', //
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    if (days < 365 && at.year == today.year) {
      return '${at.day} ${months[at.month - 1]}';
    }
    return '${at.day} ${months[at.month - 1]} ${at.year}';
  }
}

class _CaptionDot extends StatelessWidget {
  const _CaptionDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 2.5,
      height: 2.5,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: Color(0x57FFFFFF),
        shape: BoxShape.circle,
      ),
    );
  }
}

class ReactionRow extends StatelessWidget {
  const ReactionRow({super.key});

  static const _glyphs = [
    Icons.favorite_border_rounded,
    Icons.star_border_rounded,
    Icons.sentiment_satisfied_alt_rounded,
    Icons.done_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
      decoration: BoxDecoration(
        color: Warm.glassFill,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Warm.glassHairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _glyphs.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            SizedBox(
              width: 42,
              height: 38,
              child: Icon(_glyphs[i], size: 19, color: Color(0x9EFFFFFF)),
            ),
          ],
        ],
      ),
    );
  }
}

class _SayBar extends StatelessWidget {
  const _SayBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: Warm.glassFill,
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: Warm.glassHairline),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(AlbumCopy.sayPlaceholder,
                style: TextStyle(fontSize: 13.5, color: Warm.glassInkFaint)),
          ),
          const _LaterPill(),
        ],
      ),
    );
  }
}

class _LaterPill extends StatelessWidget {
  const _LaterPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Warm.glassFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        AlbumCopy.laterBadge,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: Warm.glassInkFaint,
        ),
      ),
    );
  }
}

class PeekAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  const PeekAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = onTap == null
        ? Warm.glassInkFaint
        : danger
            ? Warm.warnGlass
            : Warm.glassInk;
    return PressableScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 7),
            Text(label,
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600, color: color)),
            if (onTap == null) ...[
              const SizedBox(width: 7),
              const _LaterPill(),
            ],
          ],
        ),
      ),
    );
  }
}
