// Layout pieces every screen shares: sections, form rows, empty states and action sheets.
library;

import 'package:flutter/material.dart';

/// Keeps content at a readable width on wide windows; the builder gets the side inset to pad with.
class Readable extends StatelessWidget {
  const Readable({super.key, required this.builder});
  final Widget Function(BuildContext context, double inset) builder;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) => builder(context, box.maxWidth > 760 ? (box.maxWidth - 760) / 2 : 0));
}

/// The big title of a tab's first page.
AppBar rootBar(BuildContext context, String title, {String note = '', List<Widget> actions = const []}) => AppBar(
  toolbarHeight: 64,
  title: Row(
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Text(title, style: Theme.of(context).textTheme.headlineMedium),
      if (note.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(note, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
    ],
  ),
  actions: [...actions, const SizedBox(width: 8)],
);

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700),
    ),
  );
}

/// A titled card of rows with hairlines between them.
class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.children, this.footer = ''});
  final String title;
  final List<Widget> children;
  final String footer;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty) SectionTitle(title),
        Card(
          child: Column(
            children: [
              for (final (i, c) in children.indexed) ...[if (i > 0) const Divider(indent: 16, endIndent: 16), c],
            ],
          ),
        ),
        if (footer.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(footer, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    ),
  );
}

/// A titled stack of full-width text fields.
class FieldGroup extends StatelessWidget {
  const FieldGroup({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty) SectionTitle(title),
        for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(height: 12), c],
      ],
    ),
  );
}

/// A row with its label on the left and a short number box on the right.
class NumberRow extends StatelessWidget {
  const NumberRow({super.key, required this.label, required this.controller, required this.unit, required this.hint, required this.enabled});
  final String label;
  final bool enabled;
  final TextEditingController controller;
  final String unit;
  final String hint;
  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(label),
    enabled: enabled,
    trailing: SizedBox(
      width: 128,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => TextField(
          controller: controller,
          enabled: enabled,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.end,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            // An empty box shows only its hint; a hidden unit would still push the hint off the edge.
            suffixText: unit.isEmpty || controller.text.isEmpty ? null : unit,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
      ),
    ),
  );
}

/// A row with its label on the left and the chosen option on the right; tapping lists the others.
class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({super.key, required this.label, required this.value, required this.options, required this.onChanged});
  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(label),
    trailing: PopupMenuButton<T>(
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [for (final (v, l) in options) PopupMenuItem(value: v, child: Text(l))],
      child: Pill(text: options.where((o) => o.$1 == value).firstOrNull?.$2 ?? '', icon: Icons.unfold_more),
    ),
  );
}

/// A small rounded label, used for menu buttons.
class Pill extends StatelessWidget {
  const Pill({super.key, required this.text, required this.icon});
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(width: 4),
          Icon(icon, size: 18, color: cs.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// A rounded square in an accent colour with an icon on it.
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, required this.color, required this.size});
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * 0.28),
      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color.lerp(color, Colors.white, 0.22)!, color]),
    ),
    child: Icon(icon, color: Colors.white, size: size * 0.48),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: 0.5), shape: BoxShape.circle),
              child: Icon(icon, size: 36, color: cs.primary),
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              body,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// A notice inside a page: what is wrong or happening, in a tinted box.
class Notice extends StatelessWidget {
  const Notice({super.key, required this.icon, required this.text, required this.error});
  final IconData icon;
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = error ? cs.onErrorContainer : cs.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: error ? cs.errorContainer : cs.secondaryContainer, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: fg)),
          ),
        ],
      ),
    );
  }
}

/// The button pinned under a form.
class SaveBar extends StatelessWidget {
  const SaveBar({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Readable(
      builder: (context, inset) => Padding(
        padding: EdgeInsets.fromLTRB(16 + inset, 8, 16 + inset, 12),
        child: FilledButton(onPressed: onPressed, child: Text(label)),
      ),
    ),
  );
}

class SheetAction {
  const SheetAction({required this.icon, required this.label, required this.run, this.danger = false});
  final IconData icon;
  final String label;
  final VoidCallback run;
  final bool danger;
}

/// A bottom sheet of actions on the thing in the header; the action runs after the sheet closes.
Future<void> showActionSheet(BuildContext context, {required Widget header, required List<SheetAction> actions}) async {
  final pick = await showModalBottomSheet<SheetAction>(
    context: context,
    builder: (c) {
      final cs = Theme.of(c).colorScheme;
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            header,
            const SizedBox(height: 8),
            const Divider(),
            for (final a in actions)
              ListTile(
                leading: Icon(a.icon, color: a.danger ? cs.error : null),
                title: Text(a.label, style: a.danger ? TextStyle(color: cs.error) : null),
                onTap: () => Navigator.pop(c, a),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  pick?.run();
}

String megabytes(num bytes) {
  final mb = bytes / 1048576;
  return mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}
