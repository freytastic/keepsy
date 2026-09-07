import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:keepsy/e2ee/display_name.dart';
import 'package:keepsy/e2ee/handle.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/ui/shelf/safety_summary.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/print_card.dart';

const _docsUrl = 'https://keepsy-web.vercel.app';
const _repoUrl = 'https://github.com/freytastic/keepsy';

const _revealFor = Duration(seconds: 20);

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final TextEditingController _name;
  final FocusNode _nameFocus = FocusNode();
  bool _editing = false;
  bool _confirmingDelete = false;
  final GlobalKey _dangerKey = GlobalKey();
  String? _verified;

  void _askDelete() {
    setState(() => _confirmingDelete = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _dangerKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(ctx,
          duration: Warm.springSoft, curve: Warm.easeSoft, alignment: 1);
    });
  }

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: context.read<AppState>().profileName);
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus && _editing) _commitName();
    });
    unawaited(_loadVerified());
  }

  // Derive verification from local rosters
  Future<void> _loadVerified() async {
    final IdentityTrust trust;
    final IdentityService identity;
    try {
      trust = context.read<IdentityTrust>();
      identity = context.read<IdentityService>();
    } catch (_) {
      return;
    }
    final summary = await safetyNumberSummary(
      albums: context.read<AppState>().albums,
      trust: trust,
      identity: identity,
    );
    if (mounted) setState(() => _verified = summary);
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _commitName() {
    final name = _name.text.trim();
    setState(() => _editing = false);
    if (name.isEmpty) return;
    final state = context.read<AppState>();
    if (name == state.profileName) return;
    state.setProfileName(name);
    _publishName(name);
  }

  void _publishName(String name) {
    final publisher = context.read<DisplayNamePublisher>();
    final targets = <NameTarget>[];
    for (final a in context.read<AppState>().albums) {
      final tok = a.memberToken;
      if (tok == null) continue;
      try {
        targets.add((
          albumId: a.id,
          memberToken: base64.decode(base64.normalize(tok)),
        ));
      } catch (_) {}
    }
    unawaited(publisher.publishToAll(targets, name));
  }

  Future<void> _pickPhoto() async {
    final img = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (img != null && mounted) {
      context.read<AppState>().setProfileAvatar(img.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final photo = state.avatarUrl;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: Stack(
          children: [
            const _Ground(),
            SafeArea(
              bottom: false,
              child: ListView(
                physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics()),
                padding: const EdgeInsets.only(bottom: 56),
                children: [
                  const _Head(),
                  _You(
                    photo: photo,
                    name: state.profileName,
                    editing: _editing,
                    controller: _name,
                    focus: _nameFocus,
                    onEdit: () {
                      setState(() => _editing = true);
                      _nameFocus.requestFocus();
                    },
                    onDone: _commitName,
                    onPick: _pickPhoto,
                    onRemove: () =>
                        context.read<AppState>().setProfileAvatar(''),
                  ),
                  _IdBlock(handle: state.keepsyId),
                  _Section(
                    label: 'People',
                    children: [
                      _Row(
                        title: 'Safety numbers',
                        value: _verified,
                      ),
                      const _Note(
                          'Compare a short code with someone in person to be '
                          'certain their phone is really theirs. Verifying once '
                          'counts in every album you share.'),
                    ],
                  ),
                  const _Section(
                    label: 'What Keepsy knows',
                    children: [
                      _Row(
                          title: 'How Keepsy works',
                          href: '$_docsUrl/how-it-works'),
                    ],
                  ),
                  const _Section(
                    label: 'Backup',
                    children: [
                      _FactTitle('Not in beta version.', muted: true),
                      _Note(
                          "There's no way to move your account to a new phone "
                          'yet. If you reinstall Keepsy, this phone gets a new '
                          'key, and the people you share albums with will need '
                          'to invite you again.'),
                    ],
                  ),
                  const _Section(
                    label: 'About',
                    children: [
                      _Row(title: 'Source code', href: _repoUrl, mark: true),
                      _Version(),
                    ],
                  ),
                  _Danger(
                    key: _dangerKey,
                    confirming: _confirmingDelete,
                    onAsk: _askDelete,
                    onDismiss: () => setState(() => _confirmingDelete = false),
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

class _Ground extends StatelessWidget {
  const _Ground();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          color: Warm.ground,
          gradient: RadialGradient(
            center: Alignment(0, -1.36),
            radius: 1.4,
            colors: [Warm.groundLift, Warm.ground],
          ),
        ),
        child: SizedBox.expand(),
      );
}

class _Head extends StatelessWidget {
  const _Head();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 26, Warm.pagePad, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onTap: () => Navigator.of(context).maybePop(),
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: Warm.stoneFill,
              shape: BoxShape.circle,
              boxShadow: Warm.avatarShadow,
            ),
            child: const Icon(Icons.chevron_left_rounded,
                size: 22, color: Warm.inkSoft),
          ),
        ),
      ),
    );
  }
}

class _You extends StatelessWidget {
  final String? photo;
  final String name;
  final bool editing;
  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onEdit;
  final VoidCallback onDone;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  const _You({
    required this.photo,
    required this.name,
    required this.editing,
    required this.controller,
    required this.focus,
    required this.onEdit,
    required this.onDone,
    required this.onPick,
    required this.onRemove,
  });

  bool get _hasPhoto => photo != null && photo!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 26, Warm.pagePad, 0),
      child: Column(
        children: [
          Transform.rotate(
            angle: -1.6 * 3.141592653589793 / 180,
            child: SizedBox(
              width: 188,
              child: PrintCard(
                frame: true,
                blank: !_hasPhoto,
                well: _hasPhoto ? _photo() : const _NoFace(),
                chin: Center(
                  child: editing
                      ? TextField(
                          controller: controller,
                          focusNode: focus,
                          maxLength: 28,
                          textAlign: TextAlign.center,
                          style: Warm.printName,
                          cursorColor: Warm.inkFaint,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            counterText: '',
                            contentPadding: EdgeInsets.zero,
                          ),
                          onSubmitted: (_) => onDone(),
                        )
                      : GestureDetector(
                          onTap: onEdit,
                          child: Text(
                            name.trim().isEmpty ? 'Add your name' : name,
                            style: Warm.printName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Link(_hasPhoto ? 'Change photo' : 'Add photo', onTap: onPick),
                if (_hasPhoto) ...[
                  const _Mid(),
                  _Link('Remove', onTap: onRemove),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _photo() => Image(
        image: _fileOrNetwork(photo!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const _NoFace(),
      );

  static ImageProvider _fileOrNetwork(String src) =>
      src.startsWith('http') ? NetworkImage(src) : FileImage(File(src));
}

class _NoFace extends StatelessWidget {
  const _NoFace();

  @override
  Widget build(BuildContext context) => const Center(
        child:
            Icon(Icons.person_outline_rounded, size: 26, color: Warm.inkGhost),
      );
}

class _IdBlock extends StatefulWidget {
  final String? handle;

  const _IdBlock({required this.handle});

  @override
  State<_IdBlock> createState() => _IdBlockState();
}

class _IdBlockState extends State<_IdBlock> {
  bool _shown = false;
  bool _copied = false;
  Timer? _hide;
  Timer? _clearCopied;

  @override
  void dispose() {
    _hide?.cancel();
    _clearCopied?.cancel();
    super.dispose();
  }

  void _toggle() {
    setState(() => _shown = !_shown);
    _hide?.cancel();
    if (_shown) {
      _hide = Timer(_revealFor, () {
        if (mounted) setState(() => _shown = false);
      });
    }
  }

  void _copy() {
    final h = widget.handle;
    if (h == null) return;
    Clipboard.setData(ClipboardData(text: formatHandle(h)));
    setState(() => _copied = true);
    _clearCopied?.cancel();
    _clearCopied = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.handle;
    final value =
        h == null ? '••••-••••' : (_shown ? formatHandle(h) : '••••-••••');

    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 34, Warm.pagePad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 54,
            padding: const EdgeInsets.only(left: 18, right: 8),
            decoration: BoxDecoration(
              gradient: Warm.fieldFill,
              borderRadius: BorderRadius.circular(27),
              boxShadow: Warm.stoneShadow,
            ),
            child: Row(
              children: [
                Text(_copied ? 'Copied' : 'keepsy ID', style: Warm.idLabel),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(value,
                        textAlign: TextAlign.right, style: Warm.idValue),
                  ),
                ),
                _IconButton(
                  icon: _shown
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  onTap: h == null ? null : _toggle,
                ),
                _IconButton(
                  icon: Icons.copy_outlined,
                  onTap: h == null ? null : _copy,
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 12, left: 4, right: 4),
            child: _Note('Share this with anyone who wants to add you to an '
                'album.'),
          ),
        ],
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _IconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(icon, size: 16, color: Warm.inkFaint),
        ),
      );
}

class _Section extends StatelessWidget {
  final String label;
  final List<Widget> children;

  const _Section({required this.label, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 38, Warm.pagePad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(label.toUpperCase(), style: Warm.sectionLabel),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final String? value;
  final String? href;
  final bool mark;

  const _Row({required this.title, this.value, this.href, this.mark = false});

  Future<void> _open(BuildContext context) async {
    final url = href;
    if (url == null) return;
    HapticFeedback.selectionClick();
    final uri = Uri.tryParse(url);
    if (uri != null) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
      } catch (_) {}
    }
    if (!context.mounted) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Link copied'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final row = _body();
    if (href == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(context),
      child: row,
    );
  }

  Widget _body() {
    return Padding(
      padding: const EdgeInsets.only(left: 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 42),
        child: Row(
          children: [
            if (mark) ...[
              const Icon(Icons.code_rounded, size: 15, color: Warm.inkSoft),
              const SizedBox(width: 10),
            ],
            Expanded(child: Text(title, style: Warm.rowTitle)),
            if (value != null) ...[
              Text(value!, style: Warm.rowValue),
              const SizedBox(width: 10),
            ],
            const Icon(Icons.chevron_right_rounded,
                size: 17, color: Warm.inkGhost),
          ],
        ),
      ),
    );
  }
}

class _Version extends StatelessWidget {
  const _Version();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 22),
        child: Text('Keepsy v1.0.0 · beta', style: Warm.version),
      );
}

class _FactTitle extends StatelessWidget {
  final String text;
  final bool muted;

  const _FactTitle(this.text, {this.muted = false});

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: muted
            ? Warm.factTitle.copyWith(color: Warm.inkSoft)
            : Warm.factTitle,
      );
}

class _Note extends StatelessWidget {
  final String text;

  const _Note(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 7),
        child: Text(text, style: Warm.note),
      );
}

class _Link extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool warn;

  const _Link(this.label, {this.onTap, this.warn = false});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Text(label,
              style: warn ? Warm.link.copyWith(color: Warm.warn) : Warm.link),
        ),
      );
}

class _Mid extends StatelessWidget {
  const _Mid();

  @override
  Widget build(BuildContext context) => Container(
        width: 2.5,
        height: 2.5,
        margin: const EdgeInsets.symmetric(horizontal: 10),
        decoration: const BoxDecoration(
          color: Warm.inkGhost,
          shape: BoxShape.circle,
        ),
      );
}

class _Danger extends StatelessWidget {
  final bool confirming;
  final VoidCallback onAsk;
  final VoidCallback onDismiss;

  const _Danger({
    super.key,
    required this.confirming,
    required this.onAsk,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 46, Warm.pagePad, 0),
      child: AnimatedSwitcher(
        duration: Warm.quick,
        switchOutCurve: const FlippedCurve(Warm.easeOut),
        child: confirming
            ? Column(
                key: const ValueKey('confirm'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _FactTitle('Delete your account?'),
                  const _Note(
                      'This removes your account, your albums, and everything '
                      "stored for them on Keepsy's servers. Photos other "
                      "members already downloaded stay on their phones, we "
                      "can't reach those."),
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Row(
                      children: [
                        _Link('Delete everything',
                            warn: true, onTap: onDismiss),
                        const _Mid(),
                        _Link('Cancel', onTap: onDismiss),
                      ],
                    ),
                  ),
                ],
              )
            : Align(
                key: const ValueKey('ask'),
                alignment: Alignment.centerLeft,
                child: _Link('Delete account', warn: true, onTap: onAsk),
              ),
      ),
    );
  }
}
