import 'package:flutter/material.dart';

import 'export_settings.dart';

/// Asks for the output format and compression before the save panel opens.
/// [canConvertOnly] is true when nothing was edited (one whole clip, no
/// transitions), in which case "no compression" can just copy the video into
/// the new container instead of re-encoding it.
class ExportDialog extends StatefulWidget {
  const ExportDialog({super.key, required this.canConvertOnly});

  final bool canConvertOnly;

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  ExportFormat _format = ExportFormat.mp4;
  Compression _compression = Compression.none;

  String get _note {
    if (_compression != Compression.none) {
      return 'Re-encodes as H.264, using only as many bits as the picture needs: '
          'a mostly still screen recording gets very small, busy footage '
          'less so. A video already smaller than the limit keeps its size.';
    }
    if (widget.canConvertOnly) {
      return 'Nothing was edited, so the video is converted by copying it as-is: '
          'instant, with no quality loss. If that isn\'t possible for this '
          'file, it is re-encoded instead.';
    }
    return 'Re-encodes at high quality, keeping the original frame size.';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save as'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Format'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final f in ExportFormat.values)
                  ChoiceChip(
                    label: Text(f.label),
                    selected: _format == f,
                    onSelected: (_) => setState(() => _format = f),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            const Text('Compression'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in Compression.values)
                  ChoiceChip(
                    label: Text(c == Compression.none
                        ? c.label
                        : '${c.label} (${c.detail.replaceFirst('Up to ', '')})'),
                    selected: _compression == c,
                    onSelected: (_) => setState(() => _compression = c),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              _note,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            ExportSettings(format: _format, compression: _compression),
          ),
          child: const Text('Continue…'),
        ),
      ],
    );
  }
}
