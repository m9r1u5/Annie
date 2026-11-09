import 'package:flutter/material.dart';

import '../main.dart';
import '../services/map_pack_service.dart';
import '../utils/geo.dart';

/// Download, update and delete province maps for offline use.
class MapsScreen extends StatefulWidget {
  const MapsScreen({super.key});
  @override
  State<MapsScreen> createState() => _MapsScreenState();
}

class _Progress {
  String stage;
  int done;
  int total;
  _Progress(this.stage, this.done, this.total);
}

class _MapsScreenState extends State<MapsScreen> {
  final s = Services.i;
  MapManifest? _m;
  String? _error;
  bool _loading = true;
  final Map<String, _Progress> _active = {};
  final Map<String, int> _partial = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final m = await s.packs.fetchManifest();
      for (final p in m.packs) {
        _partial[p.id] = await s.packs.partialBytes(p.id);
      }
      setState(() => _m = m);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download(MapPack p) async {
    final blocked = await s.packs.blockedReason();
    if (blocked != null) {
      _toast(blocked);
      return;
    }
    if (!mounted) return;
    final have = _partial[p.id] ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Download ${p.name}?'),
        content: Text(have > 0
            ? 'Size: ${formatBytes(p.size)}\nAlready downloaded: ${formatBytes(have)}. It will carry on where it stopped.'
            : 'Size: ${formatBytes(p.size)}'
                '${s.packs.manifest!.assetsSize > 0 && s.settings.installedAssetsVersion != s.packs.manifest!.version ? '\nPlus map fonts and icons: ${formatBytes(s.packs.manifest!.assetsSize)}' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Download')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _active[p.id] = _Progress('Starting…', 0, p.size));
    try {
      await s.packs.downloadPack(p, (stage, done, total) {
        if (!mounted) return;
        setState(() => _active[p.id] = _Progress(stage, done, total));
      });
      _partial[p.id] = 0;
      _toast('${p.name} is ready for offline use.');
    } on DownloadCancelled {
      _partial[p.id] = await s.packs.partialBytes(p.id);
      _toast('Paused. Tap Download to carry on later.');
    } catch (e) {
      _partial[p.id] = await s.packs.partialBytes(p.id);
      _toast('Download stopped: $e. Tap Download to resume.');
    } finally {
      if (mounted) setState(() => _active.remove(p.id));
    }
  }

  Future<void> _delete(MapPack p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${p.name}?'),
        content: const Text('You can download it again any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await s.packs.deletePack(p.id);
    _partial[p.id] = 0;
    setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final st = s.settings;
    final m = _m;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline maps'),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Download on Wi-Fi only'),
            subtitle: const Text('Big map downloads and weekly updates wait for Wi-Fi. '
                'Live traffic and reports always use a little mobile data.'),
            value: st.wifiOnly,
            onChanged: (v) => setState(() => st.update((x) => x.wifiOnly = v)),
          ),
          if (m != null)
            ListTile(
              dense: true,
              leading: const Icon(Icons.update),
              title: Text('Latest map data: ${m.version}'),
              subtitle: const Text('Maps are rebuilt from OpenStreetMap every week and update automatically.'),
            ),
          const Divider(),
          if (_loading) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
          if (m != null) ...m.packs.map(_packTile),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _packTile(MapPack p) {
    final installed = s.settings.installedPacks.containsKey(p.id);
    final update = s.packs.updateAvailable(p);
    final prog = _active[p.id];
    final partial = _partial[p.id] ?? 0;

    String sub;
    if (prog != null) {
      final pct = prog.total > 0 ? (prog.done * 100 / prog.total).clamp(0, 100).toStringAsFixed(0) : '0';
      sub = '${prog.stage}: ${formatBytes(prog.done)} of ${formatBytes(prog.total)} ($pct%)';
    } else if (update) {
      sub = 'Update available · ${formatBytes(p.size)}';
    } else if (installed) {
      sub = 'On this phone · ${formatBytes(p.size)}';
    } else if (partial > 0) {
      sub = 'Paused at ${formatBytes(partial)} of ${formatBytes(p.size)}';
    } else {
      sub = formatBytes(p.size);
    }

    Widget trailing;
    if (prog != null) {
      trailing = IconButton(
        icon: const Icon(Icons.pause_circle),
        tooltip: 'Pause',
        onPressed: () {
          s.packs.cancel(p.id);
          s.packs.cancel('assets');
        },
      );
    } else if (installed && !update) {
      trailing = IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(p));
    } else {
      trailing = FilledButton.tonal(
        onPressed: _active.isEmpty ? () => _download(p) : null,
        child: Text(update ? 'Update' : (partial > 0 ? 'Resume' : 'Download')),
      );
    }

    return Column(children: [
      ListTile(
        leading: Icon(installed ? Icons.offline_pin : Icons.map_outlined,
            color: installed ? Theme.of(context).colorScheme.primary : null),
        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(sub),
        trailing: trailing,
      ),
      if (prog != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LinearProgressIndicator(value: prog.total > 0 ? prog.done / prog.total : null),
        ),
    ]);
  }
}
