import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'blur_region.dart';
import 'export_service.dart';

/// Pick how a blur looks: a style (pixelate, frosted blur, black box, match
/// background) and, for the styles that have one, a strength. Shows your own box,
/// cut from the real frame, drawn each way, and re-draws the previews when the style
/// changes. Reports the choice through [onChanged].
class LookPicker extends StatefulWidget {
  const LookPicker({
    super.key,
    required this.exporter,
    required this.path,
    required this.time,
    required this.rect,
    required this.initial,
    required this.onChanged,
    this.text = false,
  });

  final ExportService exporter;
  final String path;

  /// Clip time (seconds) of the frame the box was drawn on.
  final double time;

  /// The box on the clip's frame (0 to 1, top-left origin).
  final Rect rect;
  final BlurLook initial;

  /// Whether the box is around text (it is padded differently).
  final bool text;
  final ValueChanged<BlurLook> onChanged;

  @override
  State<LookPicker> createState() => _LookPickerState();
}

class _LookPickerState extends State<LookPicker> {
  late BlurLook _look = widget.initial;
  List<Uint8List?>? _previews; // null while loading
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final id = ++_request;
    setState(() => _previews = null);
    widget.exporter
        .blurPreview(
            path: widget.path,
            time: widget.time,
            rect: widget.rect,
            style: _look.style,
            text: widget.text)
        .then((p) {
      if (mounted && id == _request) setState(() => _previews = p);
    });
  }

  void _set(BlurLook look) {
    final styleChanged = look.style != _look.style;
    setState(() => _look = look);
    widget.onChanged(look);
    if (styleChanged) _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = _look.style;
    Widget card(PixelScale s, String label, int index) => _PreviewCard(
          label: label,
          selected: !style.hasScale || _look.scale == s,
          loading: _previews == null,
          image: _previews == null ? null : _previews![index],
          onTap: () => _set(BlurLook(style, s)),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final st in BlurStyle.values)
              ChoiceChip(
                label: Text(st.label),
                selected: style == st,
                onSelected: (_) => _set(BlurLook(st, _look.scale)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (style.hasScale)
          Row(
            children: [
              for (final s in PixelScale.values)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: card(s, style.labelFor(s), s.index),
                  ),
                ),
            ],
          )
        else
          Center(
            child: SizedBox(width: 190, child: card(PixelScale.medium, style.label, 1)),
          ),
        const SizedBox(height: 10),
        Text(
          style.hint,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Shown after drawing a box on an object: choose how it looks. Pops the chosen
/// [BlurLook]; **Back** (or clicking away) pops null, which returns to drawing so the
/// box can be redone. Tracking starts after this.
class BlurScaleDialog extends StatefulWidget {
  const BlurScaleDialog({
    super.key,
    required this.exporter,
    required this.path,
    required this.time,
    required this.rect,
    required this.initial,
  });

  final ExportService exporter;
  final String path;
  final double time;
  final Rect rect;
  final BlurLook initial;

  @override
  State<BlurScaleDialog> createState() => _BlurScaleDialogState();
}

class _BlurScaleDialogState extends State<BlurScaleDialog> {
  late BlurLook _look = widget.initial;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('How should it look?'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LookPicker(
                exporter: widget.exporter,
                path: widget.path,
                time: widget.time,
                rect: widget.rect,
                initial: widget.initial,
                onChanged: (l) => _look = l,
              ),
              const SizedBox(height: 12),
              Text(
                'This is your box on the frame, as it will look. The box is then followed '
                'automatically through the marked stretch. Back lets you redraw it.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _look),
          child: const Text('Blur'),
        ),
      ],
    );
  }
}

/// What the user chose in [TextBlurDialog]: the text to find and how it looks.
class TextBlurChoice {
  const TextBlurChoice({required this.phrases, required this.look});
  final List<String> phrases;
  final BlurLook look;
}

class _Phrase {
  _Phrase(String text) : controller = TextEditingController(text: text);
  final TextEditingController controller;
  bool on = true;
}

/// Shows what was read inside the box the user drew (one editable line each, with
/// a checkbox to leave a line out, since the reader can misread and a misread
/// phrase can't be found again), and how it will look. Pops a [TextBlurChoice];
/// **Back** (or clicking away) pops null, which returns to drawing.
class TextBlurDialog extends StatefulWidget {
  const TextBlurDialog({
    super.key,
    required this.exporter,
    required this.path,
    required this.time,
    required this.rect,
    required this.initial,
  });

  final ExportService exporter;
  final String path;
  final double time;
  final Rect rect;
  final BlurLook initial;

  @override
  State<TextBlurDialog> createState() => _TextBlurDialogState();
}

class _TextBlurDialogState extends State<TextBlurDialog> {
  late BlurLook _look = widget.initial;
  List<_Phrase>? _phrases; // null while reading

  @override
  void initState() {
    super.initState();
    widget.exporter.readText(path: widget.path, time: widget.time, rect: widget.rect).then((lines) {
      if (!mounted) return;
      setState(() => _phrases = lines.isEmpty ? [_Phrase('')] : [for (final l in lines) _Phrase(l)]);
    });
  }

  @override
  void dispose() {
    for (final p in _phrases ?? const <_Phrase>[]) {
      p.controller.dispose();
    }
    super.dispose();
  }

  List<String> get _chosen => [
        for (final p in _phrases ?? const <_Phrase>[])
          if (p.on && p.controller.text.trim().isNotEmpty) p.controller.text.trim(),
      ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final phrases = _phrases;
    return AlertDialog(
      title: const Text('Blur text'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Text to find'),
              const SizedBox(height: 6),
              if (phrases == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                      child: SizedBox(
                          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                )
              else ...[
                for (final p in phrases)
                  Row(
                    children: [
                      Checkbox(
                        value: p.on,
                        onChanged: (v) => setState(() => p.on = v ?? true),
                      ),
                      Expanded(
                        child: TextField(
                          controller: p.controller,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                              isDense: true, border: OutlineInputBorder(), hintText: 'Type text to find'),
                        ),
                      ),
                    ],
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => phrases.add(_Phrase(''))),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add another phrase'),
                  ),
                ),
              ],
              Text(
                phrases != null && phrases.every((p) => p.controller.text.isEmpty)
                    ? 'Nothing could be read in that box. Type the text yourself.'
                    : 'Fix anything misread: it can only find what it\'s told. Capital letters, '
                        'punctuation and spacing don\'t matter, and a letter or two of misreading '
                        'is forgiven. Each line is searched for separately.',
                style: muted,
              ),
              const SizedBox(height: 18),
              const Text('How should it look?'),
              const SizedBox(height: 8),
              LookPicker(
                exporter: widget.exporter,
                path: widget.path,
                time: widget.time,
                rect: widget.rect,
                initial: widget.initial,
                text: true,
                onChanged: (l) => _look = l,
              ),
              const SizedBox(height: 12),
              Text(
                'Every place that text appears between your two marks gets blurred, '
                'wherever it moves on screen, and the blur stops when the text does. '
                'Frames are read about 8 times a second, which takes a little while.',
                style: muted,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
        FilledButton(
          onPressed: _chosen.isEmpty
              ? null
              : () => Navigator.pop(context, TextBlurChoice(phrases: _chosen, look: _look)),
          child: const Text('Find and blur'),
        ),
      ],
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.label,
    required this.selected,
    required this.loading,
    required this.image,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool loading;
  final Uint8List? image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 130,
              child: Center(
                child: loading
                    ? const SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : image == null
                        ? const Icon(Icons.broken_image_outlined)
                        : Image.memory(image!, fit: BoxFit.contain, filterQuality: FilterQuality.none),
              ),
            ),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? scheme.primary : null)),
          ],
        ),
      ),
    );
  }
}
