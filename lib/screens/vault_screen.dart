import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/vault_models.dart';
import '../state/chest_controller.dart';
import '../theme/chest_theme.dart';
import '../widgets/chest_widgets.dart';

/// The vault itself: the list of sealed files.
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Picks files and seals each one.
  ///
  /// The picker is allowed multiple selections so a user can drop in a batch;
  /// each file is encrypted independently, which means one failure does not
  /// abandon the rest of the batch.
  Future<void> _importFiles() async {
    final controller = context.read<ChestController>();
    final messenger = ScaffoldMessenger.of(context);

    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;

    var sealed = 0;
    for (final file in files) {
      final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (_) {
        continue;
      }
      final entry = await controller.addFile(name: file.name, data: bytes);
      if (entry != null) sealed++;
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(sealed == 1
            ? 'Sealed 1 file into the chest.'
            : 'Sealed $sealed files into the chest.'),
      ),
    );
  }

  /// Creates a small text note and seals it.
  Future<void> _addNote() async {
    final controller = context.read<ChestController>();
    final messenger = ScaffoldMessenger.of(context);
    final nameController = TextEditingController();
    final bodyController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New sealed note'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(hintText: 'Note name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: bodyController,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(hintText: 'Contents'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Seal'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      nameController.dispose();
      bodyController.dispose();
      return;
    }

    final rawName = nameController.text.trim();
    final name = rawName.isEmpty
        ? 'note-${DateTime.now().millisecondsSinceEpoch}.txt'
        : (rawName.contains('.') ? rawName : '$rawName.txt');
    final data = Uint8List.fromList(utf8.encode(bodyController.text));
    nameController.dispose();
    bodyController.dispose();

    final entry = await controller.addFile(name: name, data: data);
    messenger.showSnackBar(
      SnackBar(content: Text(entry != null ? 'Sealed $name.' : 'Could not seal the note.')),
    );
  }

  /// Decrypts an entry and shows it, with an explicit copy action.
  ///
  /// The plaintext is never written to disk or to the clipboard automatically;
  /// the user has to ask, and the buffer is shown in a dialog they close.
  Future<void> _openEntry(VaultEntry entry) async {
    final controller = context.read<ChestController>();
    final messenger = ScaffoldMessenger.of(context);

    final data = await controller.readFile(entry);
    if (!mounted) return;
    if (data == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(controller.error ?? 'Could not open that file.')),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(entry.displayName),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${entry.readableSize} · sealed ${_formatDate(entry.addedAt)}',
                  style: const TextStyle(color: ChestTheme.muted, fontSize: 12),
                ),
                const SizedBox(height: 14),
                SelectableText(
                  _previewOf(data, entry.originalExtension),
                  style: ChestTheme.mono.copyWith(color: ChestTheme.parchment),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: _previewOf(data, entry.originalExtension)),
              );
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('Copied to the clipboard.')),
                );
              }
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(VaultEntry entry) async {
    final controller = context.read<ChestController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this entry?'),
        content: Text(
          '"${entry.displayName}" and its encrypted blob will be removed. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ChestTheme.ember),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.deleteFile(entry);
  }

  /// Renders bytes as text when they look like text, otherwise as hex.
  static String _previewOf(Uint8List data, String extension) {
    const textExtensions = {
      'txt', 'md', 'json', 'csv', 'xml', 'yaml', 'yml', 'log', 'dart', 'js',
      'ts', 'py', 'sh', 'html', 'css', 'ini', 'conf', 'sql',
    };
    final looksTextual = textExtensions.contains(extension) ||
        (data.isNotEmpty &&
            data.take(512).every((b) => b == 9 || b == 10 || b == 13 || (b >= 32 && b < 127)));
    if (looksTextual) {
      return utf8.decode(data, allowMalformed: true);
    }
    final head = data.take(256);
    return head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  static String _formatDate(DateTime date) {
    final local = date.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChestController>();
    final entries = controller.entries;

    return Scaffold(
      appBar: AppBar(
        title: const Text('The chest'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune),
            onPressed: () => controller.goTo(ChestRoute.settings),
          ),
          IconButton(
            tooltip: 'Lock now',
            icon: const Icon(Icons.lock_outline),
            onPressed: controller.lock,
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'note',
            tooltip: 'New sealed note',
            backgroundColor: ChestTheme.slate,
            foregroundColor: ChestTheme.cyan,
            onPressed: controller.busy ? null : _addNote,
            child: const Icon(Icons.note_add_outlined),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'import',
            tooltip: 'Seal files',
            backgroundColor: ChestTheme.gold,
            foregroundColor: ChestTheme.obsidian,
            onPressed: controller.busy ? null : _importFiles,
            icon: const Icon(Icons.add),
            label: const Text('Seal files'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
            child: TextField(
              controller: _search,
              onChanged: controller.search,
              decoration: const InputDecoration(
                hintText: 'Search sealed names',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: ChestErrorBanner(
                message: controller.error!,
                onDismiss: controller.clearError,
              ),
            ),
          Expanded(
            child: entries.isEmpty
                ? const _EmptyChest()
                : RefreshIndicator(
                    onRefresh: controller.refreshEntries,
                    color: ChestTheme.gold,
                    backgroundColor: ChestTheme.slate,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 110),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return _EntryTile(
                          entry: entry,
                          onOpen: () => _openEntry(entry),
                          onDelete: () => _confirmDelete(entry),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.onOpen,
    required this.onDelete,
  });

  final VaultEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  /// A stable icon per file family.
  static IconData _iconFor(String extension) {
    switch (extension) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'heic':
        return Icons.image_outlined;
      case 'mp4':
      case 'mov':
      case 'mkv':
      case 'webm':
        return Icons.movie_outlined;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'm4a':
        return Icons.audiotrack_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'txt':
      case 'md':
      case 'log':
        return Icons.description_outlined;
      case 'json':
      case 'xml':
      case 'yaml':
      case 'yml':
      case 'csv':
        return Icons.data_object;
      case 'zip':
      case 'tar':
      case 'gz':
      case '7z':
        return Icons.folder_zip_outlined;
      case 'key':
      case 'pem':
      case 'p12':
      case 'kdbx':
        return Icons.vpn_key_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChestPanel(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: ChestTheme.gold.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_iconFor(entry.originalExtension), size: 19, color: ChestTheme.gold),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: ChestTheme.parchment,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.lock, size: 11, color: ChestTheme.moss),
                    const SizedBox(width: 4),
                    Text(
                      entry.readableSize,
                      style: const TextStyle(color: ChestTheme.muted, fontSize: 12),
                    ),
                    const Text(' · ', style: TextStyle(color: ChestTheme.muted, fontSize: 12)),
                    Text(
                      _VaultScreenState._formatDate(entry.addedAt),
                      style: const TextStyle(color: ChestTheme.muted, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Open',
            icon: const Icon(Icons.lock_open, size: 19, color: ChestTheme.cyan),
            onPressed: onOpen,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline, size: 19, color: ChestTheme.muted),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _EmptyChest extends StatelessWidget {
  const _EmptyChest();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 52, color: ChestTheme.muted.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            const Text(
              'The chest is empty',
              style: TextStyle(
                color: ChestTheme.parchment,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Seal a file and it is encrypted before it touches the disk. Nothing here is readable without your passphrase.',
              textAlign: TextAlign.center,
              style: TextStyle(color: ChestTheme.muted, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
