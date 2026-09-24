import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:keepsy/data/models/album_summary.dart';
import 'package:keepsy/ui/shelf/print_style.dart';
import 'package:keepsy/ui/shelf/shelf_copy.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/member_face.dart';
import 'package:keepsy/ui/widgets/print_card.dart';

enum PrintSize { large, small }

class _Pose {
  final double rotation;
  final Offset shift;
  final double scale;

  const _Pose(this.rotation, this.shift, this.scale);
}

const _back1Rest = _Pose(-1.6, Offset(-0.016, 0.016), 1);
const _back1Out = _Pose(-12, Offset(-0.052, -0.047), 0.985);
const _back2Rest = _Pose(2.3, Offset(0.023, 0.026), 1);
const _back2Out = _Pose(12.5, Offset(0.058, -0.031), 0.975);
const _tucked = _Pose(0, Offset.zero, 0.97);

const double _degrees = 3.141592653589793 / 180;

class AlbumPrint extends StatefulWidget {
  final String albumId;
  final String? title;
  final int mediaCount;
  final int unseen;
  final DateTime? lastActivity;
  final List<MemberPreview> members;
  final int totalMembers;
  final PrintSize size;
  final int staggerIndex;

  final String? Function(MemberPreview) nameOf;

  final Widget? cover;

  final List<Widget> behind;

  final Animation<double> develop;
  final VoidCallback? onHold;
  final VoidCallback? onTap;
  // Global layout rect, untilted
  final void Function(Rect from)? onPeek;
  final bool fanned;
  final bool tilted;

  const AlbumPrint({
    super.key,
    required this.albumId,
    required this.title,
    required this.mediaCount,
    required this.unseen,
    required this.lastActivity,
    required this.members,
    required this.totalMembers,
    required this.nameOf,
    required this.develop,
    this.size = PrintSize.large,
    this.staggerIndex = 0,
    this.cover,
    this.behind = const [],
    this.onHold,
    this.onTap,
    this.onPeek,
    this.fanned = false,
    this.tilted = true,
  });

  @override
  State<AlbumPrint> createState() => _AlbumPrintState();
}

class _AlbumPrintState extends State<AlbumPrint> {
  static const _peekAfter = Duration(milliseconds: 280);

  bool _riffled = false;
  Timer? _peek;

  bool get _hasCover => widget.cover != null;
  bool get _small => widget.size == PrintSize.small;

  // The first hold also starts lazy riffle loading
  void _setRiffled(bool on) {
    if (_riffled == on) return;
    setState(() => _riffled = on);
  }

  void _release() {
    _peek?.cancel();
    _setRiffled(false);
  }

  void _lift() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    _setRiffled(false);
    widget.onPeek!(box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  void dispose() {
    _peek?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final edges = edgesFor(widget.mediaCount);
    final fanned = _riffled || widget.fanned;
    // Paper depth exists before lazy riffle images load
    final backs = [
      for (var i = 0; i < fanFor(widget.mediaCount); i++)
        i < widget.behind.length ? widget.behind[i] : null,
    ];
    _Pose pose(int i, _Pose out, _Pose rest) =>
        fanned ? out : (i < edges ? rest : _tucked);

    return RawGestureDetector(
      gestures: {
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          TapGestureRecognizer.new,
          (r) {
            r.onTap = widget.onTap;
          },
        ),
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(
              duration: const Duration(milliseconds: 180)),
          (r) {
            r.onLongPressStart = (_) {
              widget.onHold?.call();
              _setRiffled(true);
              if (widget.onPeek != null) _peek = Timer(_peekAfter, _lift);
            };
            r.onLongPressEnd = (_) => _release();
            r.onLongPressCancel = _release;
          },
        ),
      },
      child: Transform.rotate(
        angle: widget.tilted
            ? tiltFor(widget.albumId, small: _small) * _degrees
            : 0,
        child: AspectRatio(
          aspectRatio: 300 / 372,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (backs.length > 1)
                _BackPrint(
                  pose: pose(1, _back2Out, _back2Rest),
                  small: _small,
                  child: backs[1],
                ),
              if (backs.isNotEmpty)
                _BackPrint(
                  pose: pose(0, _back1Out, _back1Rest),
                  small: _small,
                  child: backs[0],
                ),
              PrintCard(
                develop: _hasCover ? widget.develop : null,
                blank: !_hasCover,
                shadow: _small ? Warm.printShadowSmall : Warm.printShadow,
                well: widget.cover,
                chin: _small ? _smallChin() : _largeChin(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _smallChin() => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Align(
          alignment: Alignment.center,
          child: Text(
            widget.title ?? '',
            style: Warm.cardTitleSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );

  Widget _largeChin() {
    final time = relativeTime(widget.lastActivity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.title ?? '',
                style: Warm.cardTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 13),
            PrintFaces(
              albumId: widget.albumId,
              members: widget.members,
              total: widget.totalMembers,
              nameOf: widget.nameOf,
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text.rich(
          TextSpan(
            style: Warm.meta,
            children: [
              if (widget.unseen > 0) ...[
                TextSpan(text: '${widget.unseen} new', style: Warm.metaNew),
                _dotSpan,
              ],
              TextSpan(
                  text: widget.mediaCount == 0
                      ? 'No frames yet'
                      : '${widget.mediaCount} frames'),
              if (time != null) ...[_dotSpan, TextSpan(text: time)],
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _BackPrint extends StatelessWidget {
  final _Pose pose;
  final bool small;
  final Widget? child;

  const _BackPrint(
      {required this.pose, required this.small, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: pose.shift,
      duration: Warm.springSoft,
      curve: Warm.easeSoft,
      child: AnimatedScale(
        scale: pose.scale,
        duration: Warm.springSoft,
        curve: Warm.easeSoft,
        child: AnimatedRotation(
          turns: pose.rotation / 360,
          duration: Warm.springSoft,
          curve: Warm.easeSoft,
          child: PrintCard(
            shadow: small ? Warm.printShadowSmall : Warm.printShadowBack,
            blank: child == null,
            well: child,
          ),
        ),
      ),
    );
  }
}

class PrintFaces extends StatelessWidget {
  final String albumId;
  final List<MemberPreview> members;
  final int total;
  final String? Function(MemberPreview) nameOf;
  // Matches whatever the faces sit on
  final Color ring;

  const PrintFaces({
    super.key,
    required this.albumId,
    required this.members,
    required this.total,
    required this.nameOf,
    this.ring = Warm.paper,
  });

  static const double _size = 24;
  static const double _step = 17;

  @override
  Widget build(BuildContext context) {
    final shown = members.take(4).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    final rest = total - shown.length;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: _size + (shown.length - 1) * _step,
          height: _size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < shown.length; i++)
                Positioned(
                  left: i * _step,
                  child: _Face(
                    albumId: albumId,
                    token: shown[i].memberToken,
                    initial: _initial(nameOf(shown[i])),
                    ring: ring,
                  ),
                ),
            ],
          ),
        ),
        // The count stands apart, never laid over someone's photo
        if (rest > 0)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text('+$rest', style: Warm.faceMore),
          ),
      ],
    );
  }

  static String? _initial(String? name) {
    final t = name?.trim();
    if (t == null || t.isEmpty) return null;
    return t.characters.first.toUpperCase();
  }
}

class _Face extends StatelessWidget {
  final String albumId;
  final String token;
  final String? initial;
  final Color ring;

  const _Face({
    required this.albumId,
    required this.token,
    required this.ring,
    this.initial,
  });

  @override
  Widget build(BuildContext context) {
    return FaceCircle(
      size: PrintFaces._size,
      color: hueFor(token).withValues(alpha: 0.62),
      // The ring is the paper, so the faces read as printed on the chin
      shadow: [BoxShadow(color: ring, spreadRadius: 2)],
      photo: memberPhoto(context, albumId, token),
      child: initial == null
          ? const SizedBox.shrink()
          : Text(initial!, style: Warm.faceInitial),
    );
  }
}

const _dotSpan = WidgetSpan(
  alignment: PlaceholderAlignment.middle,
  child: Padding(
    padding: EdgeInsets.symmetric(horizontal: 7),
    child: SizedBox(
      width: 2.5,
      height: 2.5,
      child: DecoratedBox(
        decoration: BoxDecoration(color: Warm.inkGhost, shape: BoxShape.circle),
      ),
    ),
  ),
);
