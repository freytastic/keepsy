import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keepsy/data/api/api_error.dart';
import 'package:keepsy/e2ee/handle.dart';
import 'package:keepsy/e2ee/prekey_api.dart' show HandleNotFoundException;
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/blur_scrim.dart';
import 'package:keepsy/ui/widgets/member_face.dart';
import 'package:keepsy/ui/widgets/pressable_scale.dart';
import 'package:keepsy/ui/widgets/warm_button.dart';

import 'album_copy.dart';
import 'member_avatars.dart';

typedef SendInvite = Future<void> Function(String keepsyId);

class AddPeopleSheet extends StatefulWidget {
  final String? albumId;
  final String albumTitle;
  final List<AvatarMember> members;
  final String? myKeepsyId;
  final SendInvite onInvite;
  final Animation<double> entry;

  const AddPeopleSheet({
    super.key,
    this.albumId,
    required this.albumTitle,
    required this.members,
    required this.myKeepsyId,
    required this.onInvite,
    this.entry = kAlwaysCompleteAnimation,
  });

  // Resolves true once at least one invite went through
  static Future<bool> show(
    BuildContext context, {
    String? albumId,
    required String albumTitle,
    required List<AvatarMember> members,
    required String? myKeepsyId,
    required SendInvite onInvite,
  }) async {
    final added = await Navigator.of(context).push(PageRouteBuilder<bool>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: Warm.springSnappy,
      reverseTransitionDuration: Warm.springSnappy,
      pageBuilder: (_, a, __) => AddPeopleSheet(
        albumId: albumId,
        albumTitle: albumTitle,
        members: members,
        myKeepsyId: myKeepsyId,
        onInvite: onInvite,
        entry: a,
      ),
      transitionsBuilder: (_, __, ___, child) => child,
    ));
    return added ?? false;
  }

  @override
  State<AddPeopleSheet> createState() => _AddPeopleSheetState();
}

class _AddPeopleSheetState extends State<AddPeopleSheet>
    with TickerProviderStateMixin {
  static final _allowed = RegExp('[0-9A-HJKMNP-TV-Z]');

  final _field = TextEditingController();
  final _focus = FocusNode();
  late final CurvedAnimation _slide = CurvedAnimation(
    parent: widget.entry,
    curve: Warm.easeSoft,
    reverseCurve: Curves.easeInCubic,
  );
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1050),
  )..repeat();

  String _code = '';
  bool _finding = false;
  String? _error;
  String? _added;
  bool _anyAdded = false;
  bool _copied = false;
  Timer? _copiedReset;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _copiedReset?.cancel();
    _field.dispose();
    _focus.dispose();
    _slide.dispose();
    _shake.dispose();
    _blink.dispose();
    super.dispose();
  }

  // Same folding as normalizeHandle, applied while the ID is still partial
  void _type(String raw) {
    final out = StringBuffer();
    var rejected = false;
    for (final ch in raw.toUpperCase().split('')) {
      if (ch == '-' || ch.trim().isEmpty) continue;
      final c = ch == 'I' || ch == 'L' ? '1' : (ch == 'O' ? '0' : ch);
      if (_allowed.hasMatch(c)) {
        out.write(c);
      } else {
        rejected = true;
      }
    }
    final code = out.toString();
    final clipped = code.substring(0, math.min(code.length, handleLength));
    if (rejected) _shake.forward(from: 0);
    _field.value = TextEditingValue(
      text: clipped,
      selection: TextSelection.collapsed(offset: clipped.length),
    );
    setState(() {
      _code = clipped;
      _error = null;
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) _type(data!.text!);
    _focus.requestFocus();
  }

  void _copyMine() {
    final mine = widget.myKeepsyId;
    if (mine == null) return;
    Clipboard.setData(ClipboardData(text: formatHandle(mine)));
    _copiedReset?.cancel();
    setState(() => _copied = true);
    _copiedReset = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _submit() async {
    if (_code.length != handleLength || _finding) return;
    final handle = normalizeHandle(_code);
    if (handle == widget.myKeepsyId) return _fail(AlbumCopy.addSelf);
    setState(() => _finding = true);
    try {
      await widget.onInvite(handle);
      if (!mounted) return;
      setState(() {
        _finding = false;
        _added = handle;
        _anyAdded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _finding = false);
      _fail(_messageFor(e));
    }
  }

  static String _messageFor(Object e) => switch (e) {
        HandleNotFoundException() => AlbumCopy.addUnknown,
        ApiError(code: 'E_CONFLICT') => AlbumCopy.addAlready,
        ApiError(code: 'E_ALBUM_FULL') => AlbumCopy.addFull,
        ApiError(code: 'E_EPOCH_PENDING_ROTATION') => AlbumCopy.addRotating,
        _ => AlbumCopy.addFailed,
      };

  void _fail(String message) {
    setState(() => _error = message);
    _shake.forward(from: 0);
  }

  void _again() {
    _field.clear();
    setState(() {
      _added = null;
      _code = '';
    });
    _focus.requestFocus();
  }

  void _close() => Navigator.of(context).pop(_anyAdded);

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: BlurScrim(
              progress: _slide,
              color: const Color(0x66181410),
              sigma: 10,
              onTap: _close,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                  .animate(_slide),
              child: Material(
                color: Warm.ground,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(26)),
                elevation: 0,
                child: Padding(
                  padding:
                      EdgeInsets.fromLTRB(26, 12, 26, 30 + math.max(inset, 0)),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Center(child: _Grip()),
                        const SizedBox(height: 20),
                        _Faces(
                            albumId: widget.albumId,
                            members: widget.members,
                            added: _added != null),
                        const SizedBox(height: 16),
                        AnimatedSwitcher(
                          duration: Warm.quick,
                          child: _added == null ? _entry() : _done(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _entry() {
    return Column(
      key: const ValueKey('add-entry'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(AlbumCopy.addTitle, style: _title),
        const SizedBox(height: 3),
        Text(AlbumCopy.addTo(widget.albumTitle), style: _sub),
        const SizedBox(height: 24),
        AnimatedBuilder(
          animation: _shake,
          builder: (_, child) => Transform.translate(
            offset: Offset(
                math.sin(_shake.value * math.pi * 5) * 7 * (1 - _shake.value),
                0),
            child: child,
          ),
          child: _cells(),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 40,
          child: _error != null
              ? Text(_error!,
                  key: const ValueKey('add-error'),
                  textAlign: TextAlign.center,
                  style: _help.copyWith(color: Warm.warn))
              : Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: AlbumCopy.addHelp),
                    if (_code.isEmpty)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child:
                              _Chip(label: AlbumCopy.addPaste, onTap: _paste),
                        ),
                      ),
                  ]),
                  textAlign: TextAlign.center,
                  style: _help,
                ),
        ),
        const SizedBox(height: 8),
        _Button(
          label: _finding ? AlbumCopy.addFinding : AlbumCopy.addGo,
          primary: true,
          onTap: _code.length == handleLength && !_finding ? _submit : null,
        ),
        if (widget.myKeepsyId != null) ...[
          const SizedBox(height: 14),
          _Mine(
            id: formatHandle(widget.myKeepsyId!),
            copied: _copied,
            onCopy: _copyMine,
          ),
        ],
      ],
    );
  }

  Widget _cells() {
    return LayoutBuilder(builder: (context, box) {
      // 7 gaps of 5, the dash and its margin, and the gap between halves
      final cell = math.min(34.0, (box.maxWidth - 35 - 13 - 10) / 8);
      final active = _focus.hasFocus && !_finding
          ? math.min(_code.length, handleLength - 1)
          : -1;
      return SizedBox(
        height: 46,
        child: Stack(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < handleLength; i++) ...[
                  if (i == 4) ...[
                    const SizedBox(width: 10),
                    Container(
                      width: 8,
                      height: 1.6,
                      decoration: BoxDecoration(
                        color: Warm.inkFaint,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                    const SizedBox(width: 13),
                  ] else if (i > 0)
                    const SizedBox(width: 5),
                  _Cell(
                    width: cell,
                    char: i < _code.length ? _code[i] : null,
                    active: i == active,
                    error: _error != null,
                    blink: _blink,
                  ),
                ],
              ],
            ),
            // The field owns keyboard, paste and autofill; the cells only draw it
            Positioned.fill(
              child: Opacity(
                opacity: 0,
                child: TextField(
                  key: const ValueKey('add-field'),
                  controller: _field,
                  focusNode: _focus,
                  autofocus: true,
                  enabled: !_finding,
                  showCursor: false,
                  enableSuggestions: false,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: _type,
                  onSubmitted: (_) => _submit(),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _done() {
    return Column(
      key: const ValueKey('add-done'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(AlbumCopy.addDoneTitle, style: _title),
        const SizedBox(height: 3),
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: formatHandle(_added!),
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.7,
                color: Warm.ink,
              ),
            ),
            TextSpan(text: AlbumCopy.addDoneBody(widget.albumTitle)),
          ]),
          style: _sub,
        ),
        Container(
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.only(left: 12),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: Warm.inkGhost, width: 1.5)),
          ),
          child: Text(AlbumCopy.addDoneNote,
              style: _help.copyWith(color: Warm.inkFaint)),
        ),
        const SizedBox(height: 22),
        _Button(label: AlbumCopy.addDone, primary: true, onTap: _close),
        const SizedBox(height: 6),
        _Button(label: AlbumCopy.addAnother, primary: false, onTap: _again),
      ],
    );
  }

  static const _title = TextStyle(
    fontSize: 21,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.46,
    color: Warm.ink,
  );
  static const _sub =
      TextStyle(fontSize: 13.5, height: 1.5, color: Warm.inkSoft);
  static const _help =
      TextStyle(fontSize: 12.5, height: 1.5, color: Warm.inkSoft);
}

class _Grip extends StatelessWidget {
  const _Grip();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: Warm.inkGhost,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _Faces extends StatelessWidget {
  final String? albumId;
  final List<AvatarMember> members;
  final bool added;

  const _Faces(
      {required this.albumId, required this.members, required this.added});

  static const double _size = 34;
  static const double _step = 26;
  static const double _ringWidth = 2.5;
  // The ring sits outside the face, so the box must hold it or it clips flat
  static const double _outer = _size + _ringWidth * 2;

  @override
  Widget build(BuildContext context) {
    final shown = members.take(4).toList();
    return SizedBox(
      height: _outer,
      width: shown.length * _step + _outer,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * _step,
              child: _ring(MemberFace(
                albumId: albumId,
                token: shown[i].token,
                name: shown[i].name,
                size: _size,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Warm.inkSoft,
                ),
              )),
            ),
          Positioned(
            left: shown.length * _step,
            child: AnimatedSwitcher(
              duration: Warm.springSnappy,
              transitionBuilder: (child, a) => ScaleTransition(
                scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
                child: FadeTransition(opacity: a, child: child),
              ),
              child: added
                  ? _ring(Container(
                      key: const ValueKey('face-added'),
                      width: _size,
                      height: _size,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: Warm.ctaFill,
                      ),
                      child: const Icon(Icons.check_rounded,
                          size: 16, color: Warm.ctaInk),
                    ))
                  : _ring(
                      const DashedCircle(
                        key: ValueKey('face-slot'),
                        size: _size,
                        child: Icon(Icons.add_rounded,
                            size: 15, color: Warm.inkFaint),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _ring(Widget child) => DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Warm.ground,
        ),
        child: Padding(padding: const EdgeInsets.all(_ringWidth), child: child),
      );
}

class _Cell extends StatelessWidget {
  final double width;
  final String? char;
  final bool active;
  final bool error;
  final Animation<double> blink;

  const _Cell({
    required this.width,
    required this.char,
    required this.active,
    required this.error,
    required this.blink,
  });

  @override
  Widget build(BuildContext context) {
    final rule = error
        ? Warm.warn
        : active
            ? Warm.ink
            : char != null
                ? Warm.inkFaint
                : Warm.inkGhost;
    return SizedBox(
      width: width,
      height: 46,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedSwitcher(
            duration: Warm.quick,
            transitionBuilder: (child, a) => ScaleTransition(
              scale: Tween(begin: 0.8, end: 1.0).animate(a),
              child: FadeTransition(opacity: a, child: child),
            ),
            child: char != null
                ? Text(
                    char!,
                    key: ValueKey(char),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: Warm.ink,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  )
                : active
                    ? FadeTransition(
                        opacity: blink.drive(TweenSequence([
                          TweenSequenceItem(
                              tween: ConstantTween(1.0), weight: 1),
                          TweenSequenceItem(
                              tween: ConstantTween(0.0), weight: 1),
                        ])),
                        child:
                            Container(width: 1.6, height: 22, color: Warm.ink),
                      )
                    : const SizedBox.shrink(),
          ),
          Positioned(
            left: 3,
            right: 3,
            bottom: 3,
            child: AnimatedContainer(
              duration: Warm.quick,
              height: 2,
              decoration: BoxDecoration(
                color: rule,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Button extends StatelessWidget {
  final String label;
  final bool primary;
  final VoidCallback? onTap;

  const _Button({required this.label, required this.primary, this.onTap});

  @override
  Widget build(BuildContext context) => primary
      ? WarmButton(label: label, onTap: onTap)
      : Center(child: WarmTextButton(label: label, onTap: onTap));
}

class _Chip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _Chip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Text(label,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: Warm.ink,
            decoration: TextDecoration.underline,
            decorationColor: Warm.inkGhost,
          )),
    );
  }
}

class _Mine extends StatelessWidget {
  final String id;
  final bool copied;
  final VoidCallback onCopy;

  const _Mine({required this.id, required this.copied, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text.rich(
          TextSpan(children: [
            const TextSpan(text: AlbumCopy.addYours),
            TextSpan(
              text: id,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.75,
                color: Warm.inkSoft,
              ),
            ),
          ]),
          style: const TextStyle(fontSize: 12.5, color: Warm.inkFaint),
        ),
        PressableScale(
          onTap: onCopy,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 4, 12),
            child: Text(
              copied ? AlbumCopy.addCopied : AlbumCopy.addCopy,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Warm.ink,
                decoration: TextDecoration.underline,
                decorationColor: Warm.inkGhost,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
