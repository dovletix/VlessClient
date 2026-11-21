import 'package:flutter/material.dart';

import 'theme.dart';

/// A rounded panel like the web UI's cards.
class PanelCard extends StatelessWidget {
  const PanelCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.margin = const EdgeInsets.only(bottom: 12)});
  final Widget child;
  final EdgeInsets padding, margin;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // a Material (not a coloured Container), so that list tiles inside keep their ink splashes
    return Padding(
      padding: margin,
      child: Material(
        color: p.panel,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.line)),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class H2 extends StatelessWidget {
  const H2(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Expanded(child: Text(text, style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.w700))),
        ?trailing,
      ]),
    );
  }
}

class Hint extends StatelessWidget {
  const Hint(this.text, {super.key, this.color, this.size = 13});
  final String text;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(color: color ?? Palette.of(context).muted, fontSize: size, height: 1.35));
}

enum PillKind { ok, bad, warn, accent, muted }

/// Status pill with a dot, as at the top of the web UI.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.kind = PillKind.muted, this.dot = true});
  final String text;
  final PillKind kind;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (fg, bg) = switch (kind) {
      PillKind.ok => (p.ok, p.okSoft),
      PillKind.bad => (p.bad, p.badSoft),
      PillKind.warn => (p.warn, p.warnSoft),
      PillKind.accent => (p.accent, p.accentSoft),
      PillKind.muted => (p.muted, p.chip),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot) ...[
          Container(width: 7, height: 7, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
          const SizedBox(width: 6),
        ],
        Text(text, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// A removable chip (sites lists).
class RemovableChip extends StatelessWidget {
  const RemovableChip(this.text, {super.key, required this.onRemove});
  final String text;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 2, top: 2, bottom: 2),
      decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(text, style: TextStyle(color: p.text, fontSize: 13, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis)),
        InkWell(
          onTap: onRemove,
          borderRadius: BorderRadius.circular(6),
          child: Padding(padding: const EdgeInsets.all(6), child: Icon(Icons.close, size: 14, color: p.muted)),
        ),
      ]),
    );
  }
}

/// Two-way choice drawn as segmented pills ("Через VPN" / "Напрямую").
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.value, required this.options, required this.onChanged});
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (v, label) in options)
          GestureDetector(
            onTap: () => onChanged(v),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: v == value ? p.accent : Colors.transparent, borderRadius: BorderRadius.circular(8)),
              child: Text(label, style: TextStyle(color: v == value ? p.onAccent : p.muted, fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          ),
      ]),
    );
  }
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
}
