import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../main.dart';
import '../services/settings.dart';
import 'maps_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final s = Services.i;
  String _version = '';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    s.updates.currentVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  void _set(void Function(Settings st) change) => setState(() => s.settings.update(change));

  Future<void> _checkUpdate() async {
    setState(() => _checking = true);
    try {
      final u = await s.updates.check();
      if (!mounted) return;
      if (u == null) {
        _toast('You have the latest version.');
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Update to ${u.version}?'),
          content: const Text(
              'The new APK will download in your browser. Open it when it finishes and tap Install.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Later')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Download')),
          ],
        ),
      );
      if (ok == true) {
        await launchUrl(Uri.parse(u.apkUrl), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(t,
            style: TextStyle(
                fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.primary)),
      );

  @override
  Widget build(BuildContext context) {
    final st = s.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        _header('Voice'),
        SwitchListTile(
          title: const Text('Voice directions'),
          value: st.voiceOn,
          onChanged: (v) => _set((x) => x.voiceOn = v),
        ),
        ListTile(
          title: const Text('Voice language'),
          subtitle: Text(st.voiceLang == 'af' && !s.voice.afrikaansAvailable
              ? 'No Afrikaans voice on this phone. Install one under Settings › Text-to-speech, then reopen the app. Using English for now.'
              : (st.voiceLang == 'af' ? 'Afrikaans' : 'English')),
          trailing: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'en', label: Text('EN')),
              ButtonSegment(value: 'af', label: Text('AF')),
            ],
            selected: {st.voiceLang},
            onSelectionChanged: (v) {
              _set((x) => x.voiceLang = v.first);
              s.voice.say(s.voice.lang == 'af' ? 'Afrikaans stem gekies.' : 'English voice selected.');
            },
          ),
        ),
        _header('Route options'),
        SwitchListTile(
          title: const Text('Avoid toll roads'),
          value: st.avoidTolls,
          onChanged: (v) => _set((x) => x.avoidTolls = v),
        ),
        SwitchListTile(
          title: const Text('Avoid highways'),
          value: st.avoidHighways,
          onChanged: (v) => _set((x) => x.avoidHighways = v),
        ),
        SwitchListTile(
          title: const Text('Avoid gravel roads'),
          value: st.avoidGravel,
          onChanged: (v) => _set((x) => x.avoidGravel = v),
        ),
        const ListTile(
          leading: Icon(Icons.shield_outlined),
          title: Text('Safety avoid zones'),
          subtitle: Text('Coming in the next update: draw areas on the map for routes to avoid.'),
        ),
        _header('Display'),
        ListTile(
          title: const Text('Day / night colours'),
          subtitle: SegmentedButton<ThemeChoice>(
            segments: const [
              ButtonSegment(value: ThemeChoice.auto, label: Text('Auto')),
              ButtonSegment(value: ThemeChoice.day, icon: Icon(Icons.light_mode)),
              ButtonSegment(value: ThemeChoice.night, icon: Icon(Icons.dark_mode)),
            ],
            selected: {st.theme},
            onSelectionChanged: (v) => _set((x) => x.theme = v.first),
          ),
        ),
        SwitchListTile(
          title: const Text('Keep screen on while driving'),
          value: st.keepScreenOn,
          onChanged: (v) => _set((x) => x.keepScreenOn = v),
        ),
        _header('Maps'),
        ListTile(
          leading: const Icon(Icons.download_for_offline),
          title: const Text('Offline maps'),
          subtitle: Text(st.installedPacks.isEmpty
              ? 'No provinces downloaded'
              : '${st.installedPacks.length} province(s) on this phone'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MapsScreen())),
        ),
        SwitchListTile(
          title: const Text('Download updates on Wi-Fi only'),
          value: st.wifiOnly,
          onChanged: (v) => _set((x) => x.wifiOnly = v),
        ),
        _header('App'),
        ListTile(
          leading: const Icon(Icons.system_update),
          title: const Text('Update app'),
          subtitle: Text(_version.isEmpty ? '' : 'Installed: $_version'),
          trailing: _checking
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.chevron_right),
          onTap: _checking ? null : _checkUpdate,
        ),
        ListTile(
          leading: const Icon(Icons.share),
          title: const Text('Share app'),
          onTap: () => Share.share(
              'Try ${AppConfig.appName}, navigation for South Africa: ${AppConfig.releasesPage}'),
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Map data and credits'),
          subtitle: Text('Map data © OpenStreetMap contributors (ODbL). Map tiles: Protomaps, '
              'OpenFreeMap / OpenMapTiles. Routing: Valhalla (FOSSGIS server). Search: Photon by Komoot.'),
        ),
        const SizedBox(height: 32),
      ]),
    );
  }
}
