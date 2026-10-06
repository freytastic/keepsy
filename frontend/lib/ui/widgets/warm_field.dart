import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

class WarmField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String label;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final int? maxLength;
  final bool autofocus;
  final bool autocorrect;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool soft;

  const WarmField({
    super.key,
    required this.controller,
    required this.label,
    this.focusNode,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.maxLength,
    this.autofocus = false,
    this.autocorrect = true,
    this.onChanged,
    this.onSubmitted,
    this.soft = false,
  });

  @override
  State<WarmField> createState() => _WarmFieldState();
}

class _WarmFieldState extends State<WarmField> {
  FocusNode? _own;

  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant WarmField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _own)?.removeListener(_changed);
      _focus.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    _own?.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    if (widget.soft) return _soft(focused);
    return AnimatedContainer(
      duration: Warm.quick,
      curve: Warm.easeOut,
      height: Warm.fieldHeight,
      decoration: BoxDecoration(
        color: focused ? Warm.fieldFillFocus : Warm.fieldFill,
        borderRadius: BorderRadius.circular(Warm.fieldRadius),
        border: Border.all(
          color: focused ? Warm.ink : Colors.transparent,
          width: 1.5,
        ),
      ),
      alignment: Alignment.center,
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        autofillHints: widget.autofillHints,
        autofocus: widget.autofocus,
        autocorrect: widget.autocorrect,
        maxLength: widget.maxLength,
        maxLengthEnforcement: MaxLengthEnforcement.enforced,
        style: Warm.fieldText,
        textAlignVertical: TextAlignVertical.center,
        cursorColor: Warm.ink,
        cursorWidth: 2,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
        decoration: InputDecoration(
          labelText: widget.label,
          labelStyle: Warm.fieldLabel,
          floatingLabelStyle: Warm.fieldLabel
              .copyWith(color: focused ? Warm.inkSoft : Warm.inkFaint),
          counterText: '',
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        ),
      ),
    );
  }

  Widget _soft(bool focused) {
    return AnimatedContainer(
      duration: Warm.quick,
      curve: Warm.easeOut,
      height: Warm.fieldHeight,
      decoration: BoxDecoration(
        color: focused ? Colors.white : Warm.groundLift.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Warm.ink.withValues(alpha: focused ? 0.1 : 0.06),
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                    color: Warm.shadow(0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 6)),
                BoxShadow(
                    color: Warm.shadow(0.05),
                    blurRadius: 3,
                    offset: const Offset(0, 1)),
              ]
            : [
                BoxShadow(
                    color: Warm.shadow(0.04),
                    blurRadius: 2,
                    offset: const Offset(0, 1)),
              ],
      ),
      alignment: Alignment.center,
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        autofillHints: widget.autofillHints,
        autofocus: widget.autofocus,
        autocorrect: widget.autocorrect,
        maxLength: widget.maxLength,
        maxLengthEnforcement: MaxLengthEnforcement.enforced,
        style: Warm.fieldText,
        textAlignVertical: TextAlignVertical.center,
        cursorColor: Warm.ink,
        cursorWidth: 2,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
        decoration: InputDecoration(
          hintText: widget.label,
          hintStyle: Warm.fieldLabel.copyWith(color: Warm.inkFaint),
          counterText: '',
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 18),
        ),
      ),
    );
  }
}
