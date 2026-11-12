import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/android_auto.dart';
import '../main.dart';
import '../services/settings.dart';
import 'maps_screen.dart';
import 'zones_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final s = Services.i;
  String _version = '';
  bool _checking = false;

  ShizukuStatus? _auto;

  Future<void> _refreshAuto() async {
    final st = await AndroidAutoHelper.status();
    if (mounted) setState(() => _auto = st);
  }

  /// Steps to make SafeRoute show up in Android Auto.
  Future<void> _fixAndroidAuto() async {
    var st = await AndroidAutoHelper.status();
    if (!mounted) return;
    if (!st.installed || !st.running) {
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          scrollable: true,
          title: Text(st.installed ? 'Start Shizuku' : 'Install Shizuku first'),
          content: Text(st.installed
              ? 'Open Shizuku and start it with Wireless debugging (it shows you how), then come back and tap this again.'
              : 'Android Auto only lists apps it thinks came from the Play Store. The free app Shizuku lets '
                  'SafeRoute reinstall itself that way, without a computer.\n\n'
                  '1. Install Shizuku from the Play Store.\n'
                  '2. Open it and start it with Wireless debugging (follow its steps).\n'
                  '3. Come back here and tap "Show in Android Auto" again.'),
          actions: [
            if (!st.installed)
              TextButton(
                onPressed: () => launchUrl(
                    Uri.parse('https://play.google.com/store/apps/details?id=moe.shizuku.privileged.api'),
                    mode: LaunchMode.externalApplication),
                child: const Text('Open Play Store'),
              ),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
          ],
        ),
      );
      _refreshAuto();
      return;
    }
    if (!st.granted) {
      await AndroidAutoHelper.requestPermission();
      _toast('Tap "Allow all the time" in the Shizuku prompt, then tap "Show in Android Auto" again.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true,
        title: const Text('Show in Android Auto'),
        content: const Text('SafeRoute will reinstall itself (your maps and settings stay). '
            'The app closes when it is done: open it again, then restart Android Auto and check '
            'Customise launcher.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reinstall')),
        ],
      ),
    );
    if (ok != true) return;
    _toast('Reinstalling…');
    final out = await AndroidAutoHelper.reinstallSelf();
    if (out != 'OK') _toast(out);
    st = await AndroidAutoHelper.status();
    if (mounted) setState(() => _auto = st);
  }

  @override
  void initState() {
    super.initState();
    _refreshAuto();
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
              'SafeRoute downloads and installs the update (through Shizuku if it is running, otherwise in your browser: open the file and tap Install).'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Later')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Download')),
          ],
        ),
      );
      if (ok == true) {
        final st = await AndroidAutoHelper.status();
        if (st.ready) {
          // Install through Shizuku so SafeRoute stays visible in Android Auto.
          _toast('Downloading update…');
          final out = await AndroidAutoHelper.downloadAndInstall(u.apkUrl, (_) {});
          if (out != 'OK') _toast(out);
        } else {
          await launchUrl(Uri.parse(u.apkUrl), mode: LaunchMode.externalApplication);
        }
      }
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _editKey() async {
    final ctrl = TextEditingController(text: s.settings.tomtomKey);
    var testing = false;
    String? result;
    final saved = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          scrollable: true,
          title: const Text('TomTom API key'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Sign in at developer.tomtom.com, open Dashboard › API Keys, copy your key and paste it here.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'API key', border: OutlineInputBorder()),
            ),
            if (testing) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            if (result != null)
              Padding(padding: const EdgeInsets.only(top: 12), child: Text(result!)),
          ]),
          actions: [
            if (s.settings.hasTraffic)
              TextButton(onPressed: () => Navigator.pop(c, ''), child: const Text('Remove')),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              onPressed: testing
                  ? null
                  : () async {
                      final k = ctrl.text.trim();
                      if (k.isEmpty) return;
                      setD(() {
                        testing = true;
                        result = null;
                      });
                      final err = await s.traffic.testKey(k);
                      if (err == null) {
                        if (c.mounted) Navigator.pop(c, k);
                      } else {
                        setD(() {
                          testing = false;
                          result = err;
                        });
                      }
                    },
              child: const Text('Test & save'),
            ),
          ],
        ),
      ),
    );
    if (saved == null) return;
    _set((x) => x.tomtomKey = saved);
    _toast(saved.isEmpty ? 'Key removed. Live traffic is off.' : 'Key works. Live traffic is on.');
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
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(st.voiceLang != 'af'
                ? 'English'
                : !s.voice.afrikaansAvailable
                    ? 'No Afrikaans voice available. Using English for now.'
                    : s.voice.afrikaansVoiceLocale == 'af-ZA'
                        ? 'Afrikaans'
                        : s.voice.hasAfrikaansClips
                            ? 'Afrikaans voice. Street names are shown on screen, not spoken.'
                            : 'Afrikaans directions, read by the Dutch voice (no Afrikaans voice found).'),
            const SizedBox(height: 8),
            SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'en', label: Text('EN')),
              ButtonSegment(value: 'af', label: Text('AF')),
            ],
            selected: {st.voiceLang},
            onSelectionChanged: (v) {
              _set((x) => x.voiceLang = v.first);
              s.voice.sayLanguageSelected();
            },
            ),
          ]),
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
        ListTile(
          leading: const Icon(Icons.shield),
          title: const Text('Safety avoid zones'),
          subtitle: Text(!st.avoidZones
              ? 'Off'
              : st.zones.isEmpty
                  ? 'Draw areas on the map for routes to avoid'
                  : '${st.zones.where((z) => z.enabled).length} of ${st.zones.length} zone(s) on'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const ZonesScreen()));
            if (mounted) setState(() {});
          },
        ),
        _header('Live traffic (TomTom)'),
        ListTile(
          leading: const Icon(Icons.traffic),
          title: const Text('TomTom API key'),
          subtitle: Text(st.hasTraffic
              ? 'Key saved (…${st.tomtomKey.trim().substring((st.tomtomKey.trim().length - 4).clamp(0, 999))}). Tap to change.'
              : 'Not set. Tap to paste your free key from developer.tomtom.com'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _editKey,
        ),
        SwitchListTile(
          title: const Text('Show traffic on the map'),
          subtitle: const Text('Green = flowing, orange = slow, red = jam, purple = closed. '
              'Works on downloaded maps.'),
          value: st.showTraffic,
          onChanged: st.hasTraffic ? (v) => _set((x) => x.showTraffic = v) : null,
        ),
        SwitchListTile(
          title: const Text('Switch to faster routes automatically'),
          subtitle: const Text('While driving, traffic is checked every 4 minutes. '
              'A faster route is only used if it also avoids your zones.'),
          value: st.autoFaster,
          onChanged: st.hasTraffic ? (v) => _set((x) => x.autoFaster = v) : null,
        ),
        _header('Trail'),
        SwitchListTile(
          title: const Text('Record my trail'),
          subtitle: const Text('Keeps the last 12 hours of where you drove (only on this phone), '
              'so you can retrace your way out of an area.'),
          value: st.recordTrail,
          onChanged: (v) => _set((x) => x.recordTrail = v),
        ),
        SwitchListTile(
          title: const Text('Record in background'),
          subtitle: const Text('Keep recording your trail with the screen off even when you are not '
              'navigating (shows a notification, uses more battery). During a trip the app '
              'always keeps running with the screen off.'),
          value: st.backgroundTrail,
          onChanged: st.recordTrail ? (v) => _set((x) => x.backgroundTrail = v) : null,
        ),
        SwitchListTile(
          title: const Text('Show my trail on the map'),
          subtitle: const Text('Orange line of the last hour. You can also switch it on and off '
              'with the orange history button on the map.'),
          value: st.showTrail,
          onChanged: (v) => _set((x) => x.showTrail = v),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('Clear my trail'),
          onTap: () async {
            await s.trail.clear();
            _toast('Trail cleared.');
          },
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
          title: const Text('Auto 3D in towns'),
          subtitle: const Text('Switches to 3D where the speed limit is 60 or less (or when '
              'you drive slowly) and back to 2D on open roads. Tapping 2D/3D while '
              'driving turns this off for that trip.'),
          value: st.auto3d,
          onChanged: (v) => _set((x) => x.auto3d = v),
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
        _header('Android Auto'),
        ListTile(
          leading: Icon(Icons.directions_car,
              color: _auto?.visibleInAndroidAuto == true ? const Color(0xFF2E7D32) : null),
          title: const Text('Show in Android Auto'),
          subtitle: Text(_auto == null
              ? 'Checking…'
              : _auto!.visibleInAndroidAuto
                  ? 'Ready: SafeRoute can appear in Android Auto. (Also turn on Unknown sources in Android Auto developer settings.)'
                  : 'Not visible yet: Android Auto hides apps not installed from the Play Store. Tap to fix (uses the free Shizuku app).'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _fixAndroidAuto,
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
              'OpenFreeMap / OpenMapTiles. Routing: Valhalla (FOSSGIS server). Search: Photon by Komoot. '
              'Afrikaans voice clips: Google Translate voice / eSpeak NG, for personal use.'),
        ),
        const SizedBox(height: 32),
      ]),
    );
  }
}
