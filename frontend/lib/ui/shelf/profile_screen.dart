import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:keepsy/data/native/image_transcoder.dart';
import 'package:keepsy/data/storage/media_cache_manager.dart';
import 'package:keepsy/data/storage/own_avatar_store.dart';
import 'package:keepsy/data/storage/picked_file.dart';
import 'package:keepsy/domain/account/account_deletion.dart';
import 'package:keepsy/domain/avatar/avatar_publisher.dart';
import 'package:keepsy/e2ee/avatar_image.dart';
import 'package:keepsy/e2ee/display_name.dart';
import 'package:keepsy/e2ee/handle.dart';
import 'package:keepsy/e2ee/identity.dart';
import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/ui/shelf/avatar_crop_screen.dart';
import 'package:keepsy/ui/shelf/safety_summary.dart';
import 'package:keepsy/ui/providers/app_state.dart';
import 'package:keepsy/ui/settings/delete_account_screen.dart';
import 'package:keepsy/ui/settings/settings_page.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/print_card.dart';
import 'package:keepsy/ui/widgets/upload_copy.dart';
import 'package:keepsy/ui/widgets/warm_button.dart';
import 'package:keepsy/ui/widgets/warm_field.dart';

const _siteUrl = 'https://keepsy-web.vercel.app';
const _repoUrl = 'https://github.com/freytastic/keepsy';

const _revealFor = Duration(seconds: 20);

class ProfileScreen extends StatefulWidget {
  // Null leaves the safety numbers row as a count only
  final VoidCallback? onSafetyNumbers;

  const ProfileScreen({super.key, this.onSafetyNumbers});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String? _verified;
  int? _stored;
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadVerified());
    unawaited(_loadStored());
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

  Future<void> _loadStored() async {
    final MediaCacheManager cache;
    try {
      cache = context.read<MediaCacheManager>();
    } catch (_) {
      return;
    }
    final u = await cache.usage();
    if (mounted) setState(() => _stored = u.thumbs + u.full);
  }

  Future<void> _editName() async {
    final state = context.read<AppState>();
    final name = await _NameSheet.show(context, state.profileName);
    if (name == null || !mounted || name == state.profileName) return;
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

  Future<void> _editPhoto(bool hasPhoto) async {
    final choice = await _PhotoSheet.show(context, hasPhoto: hasPhoto);
    if (!mounted) return;
    switch (choice) {
      case _PhotoChoice.pick:
        await _pickPhoto();
      case _PhotoChoice.remove:
        await _removePhoto();
      case null:
        break;
    }
  }

  // The photo is cleaned of metadata before the crop screen ever shows it
  Future<void> _pickPhoto() async {
    final own = context.read<OwnAvatarStore?>();
    if (own == null || _preparing) return;
    final messenger = ScaffoldMessenger.of(context);
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    setState(() => _preparing = true);
    Uint8List? clean;
    try {
      clean = await AvatarImage.prepare(await picked.readAsBytes(),
          transcode: platformImageTranscoder);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
        content: Text("This photo couldn't be used. Try another one."),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      unawaited(pickerCacheRoots()
          .then((roots) => discardPickedFile(picked.path, roots)));
      if (mounted) setState(() => _preparing = false);
    }
    if (clean == null || !mounted) return;
    final jpeg = await AvatarCropScreen.show(context, clean);
    if (jpeg == null || !mounted) return;
    await own.set(jpeg);
    if (mounted) unawaited(context.read<AvatarPublisher?>()?.sync());
  }

  Future<void> _removePhoto() async {
    final own = context.read<OwnAvatarStore?>();
    if (own == null) return;
    await own.remove();
    if (mounted) unawaited(context.read<AvatarPublisher?>()?.sync());
  }

  Future<void> _open(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Future<void> _openStorage() async {
    await _open(const StoragePage());
    await _loadStored();
  }

  void _openDelete() {
    final AccountDeletion deletion;
    try {
      deletion = context.read<AccountDeletion>();
    } catch (_) {
      return;
    }
    _open(DeleteAccountScreen(deletion: deletion));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final photo = context.select<OwnAvatarStore?, Uint8List?>(
        (o) => o?.state == OwnAvatarState.set ? o?.jpeg : null);

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
                padding: const EdgeInsets.only(bottom: 40),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(Warm.pagePad - 8, 16, 0, 0),
                    child: Align(
                        alignment: Alignment.centerLeft, child: WarmBack()),
                  ),
                  _You(
                    photo: photo,
                    name: state.profileName,
                    busy: _preparing,
                    onPhoto: () => _editPhoto(photo != null),
                    onName: _editName,
                  ),
                  _Group(top: 30, children: [
                    _IdRow(handle: state.keepsyId),
                    _Row(
                      title: 'Safety numbers',
                      value: _verified,
                      onTap: widget.onSafetyNumbers,
                    ),
                    _Row(
                      title: 'Notifications',
                      onTap: () => _open(const NotificationsPage()),
                    ),
                    _Row(
                      title: 'Backup',
                      value: 'Not yet',
                      onTap: () => _open(const BackupPage()),
                    ),
                    _Row(
                      title: 'Storage',
                      value: _stored == null ? null : formatBytes(_stored!),
                      onTap: _openStorage,
                    ),
                  ]),
                  const _Group(children: [
                    _Row(title: 'Send feedback', href: '$_repoUrl/issues/new'),
                    _Row(title: 'Privacy policy', href: '$_siteUrl/privacy'),
                  ]),
                  _Group(children: [
                    _Row(
                        title: 'Delete account',
                        warn: true,
                        onTap: _openDelete),
                  ]),
                  const _Foot(),
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

class _You extends StatelessWidget {
  final Uint8List? photo;
  final bool busy;
  final String name;
  final VoidCallback onPhoto;
  final VoidCallback onName;

  const _You({
    required this.photo,
    required this.busy,
    required this.name,
    required this.onPhoto,
    required this.onName,
  });

  bool get _hasPhoto => photo != null;

  @override
  Widget build(BuildContext context) {
    final empty = name.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 18, Warm.pagePad, 0),
      child: Center(
        child: Transform.rotate(
          angle: -1.6 * 3.141592653589793 / 180,
          child: SizedBox(
            width: 188,
            child: PrintCard(
              frame: true,
              blank: !_hasPhoto,
              well: Semantics(
                button: true,
                label: _hasPhoto ? 'Change photo' : 'Add photo',
                child: GestureDetector(
                  onTap: busy ? null : onPhoto,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _hasPhoto ? _photo() : const _NoFace(),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: _CameraBadge(busy: busy),
                      ),
                    ],
                  ),
                ),
              ),
              chin: Center(
                child: Semantics(
                  button: true,
                  label: 'Edit name',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onName,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            empty ? 'Add your name' : name,
                            style: empty
                                ? Warm.printName.copyWith(color: Warm.inkFaint)
                                : Warm.printName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.edit_outlined,
                            size: 13, color: Warm.inkFaint),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _photo() => Image.memory(
        photo!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const _NoFace(),
      );
}

class _CameraBadge extends StatelessWidget {
  final bool busy;

  const _CameraBadge({required this.busy});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xDBFDFCFA),
        boxShadow: [
          BoxShadow(
              color: Warm.shadow(0.18),
              blurRadius: 3,
              offset: const Offset(0, 1)),
        ],
      ),
      child: busy
          ? const SizedBox(
              width: 12,
              height: 12,
              child:
                  CircularProgressIndicator(strokeWidth: 1.6, color: Warm.ink),
            )
          : const Icon(Icons.photo_camera_outlined, size: 14, color: Warm.ink),
    );
  }
}

class _NoFace extends StatelessWidget {
  const _NoFace();

  @override
  Widget build(BuildContext context) => const Center(
        child:
            Icon(Icons.person_outline_rounded, size: 26, color: Warm.inkGhost),
      );
}

class _Group extends StatelessWidget {
  final double top;
  final List<Widget> children;

  const _Group({required this.children, this.top = 26});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(Warm.pagePad - 8, top, Warm.pagePad - 8, 0),
      child: Column(children: children),
    );
  }
}

class _IdRow extends StatefulWidget {
  final String? handle;

  const _IdRow({required this.handle});

  @override
  State<_IdRow> createState() => _IdRowState();
}

class _IdRowState extends State<_IdRow> {
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

    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Expanded(
            child: Text(_copied ? 'Copied' : 'keepsy ID', style: Warm.rowTitle),
          ),
          Text(value, style: Warm.idValue.copyWith(color: Warm.inkSoft)),
          const SizedBox(width: 4),
          _IconButton(
            icon: _shown
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            label: _shown ? 'Hide keepsy ID' : 'Reveal keepsy ID',
            onTap: h == null ? null : _toggle,
          ),
          _IconButton(
            icon: Icons.copy_outlined,
            label: 'Copy keepsy ID',
            onTap: h == null ? null : _copy,
          ),
        ],
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _IconButton(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(icon, size: 16, color: Warm.inkFaint),
          ),
        ),
      );
}

class _Row extends StatelessWidget {
  final String title;
  final String? value;
  final String? href;
  final bool warn;
  final VoidCallback? onTap;

  const _Row({
    required this.title,
    this.value,
    this.href,
    this.warn = false,
    this.onTap,
  });

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
    final tap = href != null ? () => _open(context) : onTap;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: tap,
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: warn
                      ? Warm.rowTitle.copyWith(color: Warm.warn)
                      : Warm.rowTitle,
                ),
              ),
              if (value != null) ...[
                Text(value!,
                    style: Warm.rowValue.copyWith(color: Warm.inkFaint)),
                const SizedBox(width: 10),
              ],
              if (href != null)
                const Icon(Icons.north_east_rounded,
                    size: 14, color: Warm.inkGhost)
              else if (tap != null)
                const Icon(Icons.chevron_right_rounded,
                    size: 17, color: Warm.inkGhost),
            ],
          ),
        ),
      ),
    );
  }
}

class _Foot extends StatelessWidget {
  const _Foot();

  static const _octocat =
      '<svg viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg"><path '
      'fill="#1C1917" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07'
      '.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-'
      '.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 '
      '1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31'
      '-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 '
      '2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56'
      '.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 '
      '1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/>'
      '</svg>';

  Future<void> _open() async {
    try {
      await launchUrl(Uri.parse(_repoUrl),
          mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: 0.26,
                  child: SvgPicture.string(_octocat, width: 14, height: 14),
                ),
                const SizedBox(width: 7),
                Text('keepsy 1.0.0 beta', style: Warm.footMark),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _PhotoChoice { pick, remove }

class _PhotoSheet extends StatelessWidget {
  final bool hasPhoto;

  const _PhotoSheet({required this.hasPhoto});

  static Future<_PhotoChoice?> show(BuildContext context,
          {required bool hasPhoto}) =>
      showModalBottomSheet<_PhotoChoice>(
        context: context,
        backgroundColor: Warm.ground,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
        builder: (_) => _PhotoSheet(hasPhoto: hasPhoto),
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grip(),
            const SizedBox(height: 10),
            _SheetRow(
              icon: Icons.photo_outlined,
              label: hasPhoto ? 'Choose a new photo' : 'Choose a photo',
              onTap: () => Navigator.of(context).pop(_PhotoChoice.pick),
            ),
            if (hasPhoto)
              _SheetRow(
                icon: Icons.delete_outline_rounded,
                label: 'Remove photo',
                warn: true,
                onTap: () => Navigator.of(context).pop(_PhotoChoice.remove),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 0),
              child: Text('Only people in your albums can see it.',
                  style: Warm.pageSoft),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool warn;
  final VoidCallback onTap;

  const _SheetRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.warn = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = warn ? Warm.warn : Warm.ink;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 54,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 14),
              Text(label, style: Warm.sheetRow.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

class _NameSheet extends StatefulWidget {
  final String name;

  const _NameSheet({required this.name});

  static Future<String?> show(BuildContext context, String name) =>
      showModalBottomSheet<String>(
        context: context,
        backgroundColor: Warm.ground,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
        builder: (_) => _NameSheet(name: name),
      );

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final TextEditingController _draft =
      TextEditingController(text: widget.name);

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  String get _clean => _draft.text.trim();

  bool get _ready => _clean.isNotEmpty && _clean != widget.name.trim();

  void _save() {
    if (_ready) Navigator.of(context).pop(_clean);
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(26, 12, 26, 22 + inset),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grip(),
            const SizedBox(height: 16),
            Text('Your name', style: Warm.sheetTitle),
            const SizedBox(height: 16),
            WarmField(
              controller: _draft,
              label: 'Name',
              maxLength: 28,
              autofocus: true,
              autofillHints: const [AutofillHints.name],
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 10, 2, 0),
              child: Text('Only people in your albums can see it.',
                  style: Warm.pageSoft),
            ),
            const SizedBox(height: 22),
            WarmButton(label: 'Save', onTap: _ready ? _save : null),
            const SizedBox(height: 6),
            Center(
              child: WarmTextButton(
                label: 'Cancel',
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Grip extends StatelessWidget {
  const _Grip();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Warm.inkGhost,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}
