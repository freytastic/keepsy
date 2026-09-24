import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keepsy/e2ee/identity_trust.dart';
import 'package:keepsy/ui/album/member_avatars.dart';
import 'package:keepsy/ui/theme/warm_tokens.dart';
import 'package:keepsy/ui/widgets/warm_button.dart';

class PersonEntry {
  final String id;
  final String name;
  final Widget face;
  final TrustState trust;
  // Invited but not joined: no key yet, so nothing to compare
  final bool invited;
  final String? detail;

  const PersonEntry({
    required this.id,
    required this.name,
    required this.face,
    this.trust = TrustState.unverified,
    this.invited = false,
    this.detail,
  });
}

// Verifying is optional, so an unverified person looks normal. Only a changed
// number is allowed to be loud
class PeopleScreen extends StatefulWidget {
  final String title;
  final String subtitle;
  final Future<List<PersonEntry>> Function() load;
  final Future<void> Function(PersonEntry entry) onOpen;
  final Future<void> Function()? onAdd;
  final String? note;

  const PeopleScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.load,
    required this.onOpen,
    this.onAdd,
    this.note,
  });

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  List<PersonEntry>? _people;
  bool _failed = false;

  static const _rank = {
    TrustState.changed: 0,
    TrustState.unverified: 1,
    TrustState.verified: 2,
  };

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final people = await widget.load();
      people.sort((a, b) {
        if (a.invited != b.invited) return a.invited ? 1 : -1;
        return _rank[a.trust]!.compareTo(_rank[b.trust]!);
      });
      if (mounted) {
        setState(() {
          _people = people;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _open(PersonEntry p) async {
    HapticFeedback.selectionClick();
    await widget.onOpen(p);
    await _reload();
  }

  Future<void> _add() async {
    await widget.onAdd?.call();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    final joined = people?.where((p) => !p.invited).toList() ?? const [];
    final done = joined.where((p) => p.trust == TrustState.verified).length;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          bottom: false,
          child: ListView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            padding: const EdgeInsets.fromLTRB(
                Warm.pagePad - 8, 16, Warm.pagePad - 8, 56),
            children: [
              const Align(alignment: Alignment.centerLeft, child: WarmBack()),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 22, 8, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: Warm.pageTitle),
                    const SizedBox(height: 6),
                    Text(
                      people == null
                          ? widget.subtitle
                          : '${widget.subtitle} · $done of ${joined.length} '
                              'verified',
                      style: Warm.rowValue,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              if (widget.onAdd != null)
                _Row(
                  face: const _AddFace(),
                  name: 'Add someone',
                  onTap: _add,
                ),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child:
                            Text("Couldn't load people.", style: Warm.pageSoft),
                      ),
                      WarmTextButton(label: 'Try again', onTap: _reload),
                    ],
                  ),
                )
              else if (people == null)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Warm.ink),
                    ),
                  ),
                )
              else
                for (final p in people)
                  _Row(
                    key: ValueKey('person-${p.id}'),
                    face: p.invited ? const DashedCircle(size: 40) : p.face,
                    name: p.name,
                    verified: p.trust == TrustState.verified,
                    status: p.trust == TrustState.changed
                        ? 'Safety number changed'
                        : p.detail,
                    alarm: p.trust == TrustState.changed,
                    onTap: p.invited ? null : () => _open(p),
                  ),
              if (widget.note != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
                  child: Text(widget.note!, style: Warm.pageSoft),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final Widget face;
  final String name;
  final String? status;
  final bool verified;
  final bool alarm;
  final VoidCallback? onTap;

  const _Row({
    super.key,
    required this.face,
    required this.name,
    this.status,
    this.verified = false,
    this.alarm = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: [
        name,
        if (verified) 'verified',
        if (status != null) status!,
      ].join(', '),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              SizedBox(width: 40, height: 40, child: face),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(name,
                              style: Warm.rowTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (verified) ...[
                          const SizedBox(width: 5),
                          const Icon(Icons.check_rounded,
                              size: 15, color: Warm.ink),
                        ],
                      ],
                    ),
                    if (status != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        status!,
                        style: alarm
                            ? Warm.rowValue.copyWith(color: Warm.warn)
                            : Warm.rowValue.copyWith(color: Warm.inkFaint),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                const Icon(Icons.chevron_right_rounded,
                    size: 17, color: Warm.inkGhost),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddFace extends StatelessWidget {
  const _AddFace();

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: Warm.ctaFill,
        ),
        child: const Icon(Icons.add_rounded, size: 18, color: Warm.ctaInk),
      );
}
