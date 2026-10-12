import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:musify/extensions/l10n.dart';
import 'package:musify/services/spotify_sync_service.dart';
import 'package:musify/utilities/flutter_toast.dart';

class SpotifySettingsPage extends StatefulWidget {
  const SpotifySettingsPage({super.key});
  @override
  State<SpotifySettingsPage> createState() => _SpotifySettingsPageState();
}

class _SpotifySettingsPageState extends State<SpotifySettingsPage> {
  bool _busy = false;
  SpotifySyncProgress? _progress;

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      await SpotifySyncService.instance.connect();
      if (!mounted) return;
      setState(() => _busy = false);
      await _sync();
    } catch (error) {
      if (mounted) showToast(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    if (_busy && SpotifySyncService.instance.isConnected) return;
    setState(() { _busy = true; _progress = null; });
    try {
      final result = await SpotifySyncService.instance.synchronize(
        onProgress: (value) { if (mounted) setState(() => _progress = value); },
      );
      if (mounted) {
        showToast(context, context.l10n!.spotifySyncResult(
          result.matched, result.added, result.alreadyPresent, result.unmatched,
        ));
      }
    } catch (error) {
      if (mounted) showToast(context, error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    await SpotifySyncService.instance.disconnect();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n!.spotifyAccount)),
    body: ValueListenableBuilder<SpotifyAccount?>(
      valueListenable: SpotifySyncService.instance.connection,
      builder: (_, account, __) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Icon(FluentIcons.music_note_2_24_filled, size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(context.l10n!.spotifyAccount, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(account == null ? context.l10n!.spotifyNotConnected : context.l10n!.spotifyConnectedAs(account.name), textAlign: TextAlign.center),
          const SizedBox(height: 28),
          if (_busy) ...[
            const Center(child: CircularProgressIndicator()),
            if (_progress != null) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress!.total == 0 ? null : _progress!.processed / _progress!.total),
              const SizedBox(height: 8),
              Text(context.l10n!.spotifySyncProgress(_progress!.processed, _progress!.total), textAlign: TextAlign.center),
            ],
            const SizedBox(height: 16),
          ],
          if (account == null)
            FilledButton.icon(onPressed: _busy ? null : _connect, icon: const Icon(FluentIcons.link_24_regular), label: Text(context.l10n!.connectSpotify))
          else ...[
            FilledButton.icon(onPressed: _busy ? null : _sync, icon: const Icon(FluentIcons.arrow_sync_24_regular), label: Text(context.l10n!.syncSpotify)),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _busy ? null : _connect, icon: const Icon(FluentIcons.arrow_sync_24_regular), label: Text(context.l10n!.reconnectSpotify)),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _busy ? null : _disconnect, icon: const Icon(FluentIcons.link_dismiss_24_regular), label: Text(context.l10n!.disconnectSpotify)),
          ],
        ],
      ),
    ),
  );
}

