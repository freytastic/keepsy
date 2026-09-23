import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/member_face.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';

import 'album_copy.dart';

class AvatarMember {
  final String token;

  // Null until decryption completes
  final String? name;

  // Invited but no name published yet, so they have not opened the album
  final bool pending;

  final bool self;

  // Compared in person on this phone
  final bool verified;

  const AvatarMember({
    required this.token,
    this.name,
    this.pending = false,
    this.self = false,
    this.verified = false,
  });
}

// At rest the same small stack as the shelf print. A tap spreads every face
// into one row that never overlaps, with names, and that row is the filter.
// It folds back on an outside tap or once the header scrolls away
class MemberAvatars extends StatefulWidget {
  // Scopes avatar lookups; faces fall back to initials without it
  final String? albumId;
  final List<AvatarMember> members;
  final String? selectedToken;
  final ValueChanged<String> onTap;
  final VoidCallback? onAdd;
  final bool folded;

  const MemberAvatars({
    super.key,
    this.albumId,
    required this.members,
    required this.onTap,
    this.selectedToken,
    this.onAdd,
    this.folded = false,
  });

  static const double stackSize = 30;
  static const double rowSize = 44;
  static const double _stackStep = 22;
  static const double _stackRing = 2.5;
  static const int _stacked = 4;
  static const double _slot = 50;
  static const double _gap = 12;
  static const double _nameGap = 7;
  static const double _rowHeight = rowSize + _nameGap + 16;

  static const List<Color> palette = [
    Color(0xFFF4C7BF),
    Color(0xFFF6D2AB),
    Color(0xFFF0DFA9),
    Color(0xFFCFE0C6),
    Color(0xFFC6D4EC),
    Color(0xFFE9CDBE),
  ];

  // Token hashing keeps member colors stable across devices
  static Color hueFor(String token) {
    var hash = 0;
    for (final unit in token.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return palette[hash % palette.length];
  }

  static String initialFor(String? name) {
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return '·';
    return trimmed.characters.first.toUpperCase();
  }

  @override
  State<MemberAvatars> createState() => _MemberAvatarsState();
}

class _MemberAvatarsState extends State<MemberAvatars> {
  final ScrollController _row = ScrollController();
  bool _open = false;

  @override
  void didUpdateWidget(MemberAvatars old) {
    super.didUpdateWidget(old);
    if (widget.folded && !old.folded) _setOpen(false);
  }

  @override
  void dispose() {
    _row.dispose();
    super.dispose();
  }

  void _setOpen(bool open) {
    if (open == _open) return;
    setState(() => _open = open);
    if (!open && _row.hasClients && _row.offset > 0) {
      _row.animateTo(0, duration: Warm.springSnappy, curve: Warm.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = widget.members.where((m) => !m.pending).toList();
    final pending = widget.members.where((m) => m.pending).toList();
    if (people.isEmpty && widget.onAdd == null) return const SizedBox.shrink();

    // While filtering the chosen face leads the stack so folding never hides it
    final selected = widget.selectedToken;
    final stackOrder = [
      ...people.where((m) => m.token == selected),
      ...people.where((m) => m.token != selected),
    ];
    final rest = math.max(0, people.length - MemberAvatars._stacked);
    final extras = pending.length + (widget.onAdd == null ? 0 : 1);
    final slots = people.length + extras;
    final rowWidth = slots == 0
        ? 0.0
        : slots * MemberAvatars._slot + (slots - 1) * MemberAvatars._gap;
    final stackWidth = people.isEmpty
        ? 0.0
        : (math.min(people.length, MemberAvatars._stacked) - 1) *
                MemberAvatars._stackStep +
            MemberAvatars.stackSize;

    // Later children paint on top: the chosen face must not be cut by a neighbour
    final faces = [
      for (var i = 0; i < people.length; i++) (i, people[i]),
    ]..sort((a, b) {
        final at = a.$2.token == selected ? 1 : 0;
        final bt = b.$2.token == selected ? 1 : 0;
        if (at != bt) return at - bt;
        return stackOrder.indexOf(b.$2) - stackOrder.indexOf(a.$2);
      });

    return TapRegion(
      onTapOutside: (_) => _setOpen(false),
      child: AnimatedContainer(
        duration: Warm.springSnappy,
        curve: Warm.easeOut,
        height: _open ? MemberAvatars._rowHeight : MemberAvatars.stackSize,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          maxHeight: MemberAvatars._rowHeight,
          child: SingleChildScrollView(
            controller: _row,
            scrollDirection: Axis.horizontal,
            physics: _open
                ? const BouncingScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            clipBehavior: Clip.none,
            child: SizedBox(
              width: math.max(rowWidth, stackWidth + 40),
              height: MemberAvatars._rowHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final (i, m) in faces)
                    _Person(
                      key: ValueKey(m.token),
                      albumId: widget.albumId,
                      member: m,
                      open: _open,
                      rowLeft: i * (MemberAvatars._slot + MemberAvatars._gap),
                      stackIndex: stackOrder.indexOf(m),
                      selected: m.token == selected,
                      dimmed: selected != null && m.token != selected,
                      onTap: () => widget.onTap(m.token),
                    ),
                  for (var j = 0; j < pending.length; j++)
                    _Extra(
                      open: _open,
                      left: (people.length + j) *
                          (MemberAvatars._slot + MemberAvatars._gap),
                      label: AlbumCopy.invitedShort,
                      semantics: AlbumCopy.invitedPending,
                      child: const DashedCircle(size: MemberAvatars.rowSize),
                    ),
                  if (widget.onAdd != null)
                    _Extra(
                      open: _open,
                      left: (people.length + pending.length) *
                          (MemberAvatars._slot + MemberAvatars._gap),
                      label: AlbumCopy.addShort,
                      semantics: AlbumCopy.addSomeone,
                      onTap: widget.onAdd,
                      child: const _AddFace(key: ValueKey('add-someone')),
                    ),
                  if (rest > 0)
                    Positioned(
                      left: stackWidth + 9,
                      top: 0,
                      height: MemberAvatars.stackSize,
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: _open ? 0 : 1,
                          duration: Warm.quick,
                          child: Center(
                            child: Text('+$rest', style: _moreStyle),
                          ),
                        ),
                      ),
                    ),
                  // The whole stack is one target until it opens
                  if (!_open && people.isNotEmpty)
                    Positioned(
                      left: 0,
                      top: 0,
                      width: stackWidth + (rest > 0 ? 40 : 0),
                      height: MemberAvatars.stackSize,
                      child: Semantics(
                        button: true,
                        label: AlbumCopy.showEveryone(people.length),
                        excludeSemantics: true,
                        child: GestureDetector(
                          key: const ValueKey('people-stack'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _setOpen(true),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const _moreStyle = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    color: Warm.inkSoft,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

class _Person extends StatelessWidget {
  final String? albumId;
  final AvatarMember member;
  final bool open;
  final double rowLeft;
  final int stackIndex;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  const _Person({
    super.key,
    required this.albumId,
    required this.member,
    required this.open,
    required this.rowLeft,
    required this.stackIndex,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final stacked = stackIndex < MemberAvatars._stacked;
    final size = open ? MemberAvatars.rowSize : MemberAvatars.stackSize;
    // Faces beyond the stack wait under its last face, invisible
    final stackLeft = math.min(stackIndex, MemberAvatars._stacked - 1) *
        MemberAvatars._stackStep;
    final name =
        member.self ? AlbumCopy.you : member.name ?? AlbumCopy.unknownMember;

    return AnimatedPositioned(
      duration: Warm.springSnappy,
      curve: Warm.easeOut,
      left: open ? rowLeft : stackLeft,
      top: 0,
      width: open ? MemberAvatars._slot : size,
      child: IgnorePointer(
        ignoring: !open,
        child: Semantics(
          button: true,
          selected: selected,
          label: AlbumCopy.onlyTheirPhotos(member.self ? null : member.name),
          excludeSemantics: true,
          child: PressableScale(
            onTap: onTap,
            child: AnimatedOpacity(
              opacity: open ? (dimmed ? 0.36 : 1) : (stacked ? 1 : 0),
              duration: Warm.quick,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: Warm.springSnappy,
                    curve: Warm.easeOut,
                    width: size,
                    height: size,
                    child: MemberFace(
                      albumId: albumId,
                      token: member.token,
                      name: member.name,
                      size: size,
                      shadow: _rings(),
                      style: TextStyle(
                        fontSize: open ? 15 : 12,
                        fontWeight: FontWeight.w700,
                        color: Warm.inkSoft,
                        height: 1,
                      ),
                    ),
                  ),
                  if (open)
                    Padding(
                      padding:
                          const EdgeInsets.only(top: MemberAvatars._nameGap),
                      child: _Label(
                        name,
                        strong: selected,
                        delay: stackIndex,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Rings sit outside the face so a photo is never covered by its own frame
  List<BoxShadow> _rings() {
    const gap = BoxShadow(color: Warm.ground, spreadRadius: 2);
    if (!open) {
      const ring =
          BoxShadow(color: Warm.ground, spreadRadius: MemberAvatars._stackRing);
      if (!selected) return const [ring];
      return const [BoxShadow(color: Warm.ink, spreadRadius: 3.7), ring];
    }
    if (selected) {
      return const [BoxShadow(color: Warm.ink, spreadRadius: 3.5), gap];
    }
    if (member.verified) {
      return const [BoxShadow(color: Color(0x331C1917), spreadRadius: 3), gap];
    }
    return const [];
  }
}

class _Label extends StatelessWidget {
  final String text;
  final bool strong;
  final int delay;

  const _Label(this.text, {this.strong = false, this.delay = 0});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 220 + 25 * math.min(delay, 10)),
      curve: Curves.easeOut,
      builder: (_, t, child) => Opacity(
        opacity: t,
        child:
            Transform.translate(offset: Offset(0, (1 - t) * -3), child: child),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: strong ? FontWeight.w600 : FontWeight.w500,
          color: strong ? Warm.ink : Warm.inkSoft,
          height: 1.2,
        ),
      ),
    );
  }
}

// Invited and add only exist in the open row, after everyone who is there
class _Extra extends StatelessWidget {
  final bool open;
  final double left;
  final String label;
  final String semantics;
  final VoidCallback? onTap;
  final Widget child;

  const _Extra({
    required this.open,
    required this.left,
    required this.label,
    required this.semantics,
    required this.child,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      top: 0,
      width: MemberAvatars._slot,
      child: IgnorePointer(
        ignoring: !open,
        child: ExcludeSemantics(
          excluding: !open,
          child: AnimatedOpacity(
            opacity: open ? 1 : 0,
            duration: open ? Warm.springSnappy : Warm.quick,
            curve: Warm.easeOut,
            child: Semantics(
              button: onTap != null,
              label: semantics,
              excludeSemantics: true,
              child: PressableScale(
                onTap: onTap,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    child,
                    const SizedBox(height: MemberAvatars._nameGap),
                    _Label(label),
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

class _AddFace extends StatelessWidget {
  const _AddFace({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: MemberAvatars.rowSize,
      height: MemberAvatars.rowSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: Warm.stoneFill,
        boxShadow: [
          BoxShadow(
              color: Warm.shadow(0.08),
              blurRadius: 2,
              offset: const Offset(0, 1)),
          BoxShadow(
              color: Warm.shadow(0.06),
              blurRadius: 8,
              offset: const Offset(0, 3)),
        ],
      ),
      child: const Icon(Icons.add_rounded, size: 17, color: Warm.inkSoft),
    );
  }
}

// A kept place with nothing to draw in it yet
class DashedCircle extends StatelessWidget {
  final double size;
  final double ring;
  final Widget? child;

  const DashedCircle(
      {super.key, required this.size, this.ring = 0, this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ring == 0
          ? null
          : BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Warm.ground, width: ring),
            ),
      child: CustomPaint(
        size: Size.square(size - ring * 2),
        painter: const _Dashes(),
        child: SizedBox.square(
            dimension: size - ring * 2, child: Center(child: child)),
      ),
    );
  }
}

class _Dashes extends CustomPainter {
  const _Dashes();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..color = const Color(0x421C1917);
    final r = size.width / 2 - 0.65;
    final center = size.center(Offset.zero);
    const dashes = 14;
    const sweep = 2 * math.pi / dashes;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: r), i * sweep,
          sweep * 0.55, false, paint);
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => false;
}
