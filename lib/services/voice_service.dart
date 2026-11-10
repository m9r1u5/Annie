import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';

import 'routing_service.dart';
import 'settings.dart';

/// Spoken turn instructions in English or Afrikaans,
/// using the phone's own text-to-speech voices (free, works offline).
class VoiceService {
  VoiceService(this.settings);
  final Settings settings;
  final FlutterTts _tts = FlutterTts();
  String? _activeLang;
  bool afrikaansAvailable = false;

  /// Voice used for Afrikaans: a real Afrikaans voice, or a Dutch voice as
  /// a stand-in (Dutch voices read Afrikaans quite understandably).
  String? afrikaansVoiceLocale;
  bool get afrikaansIsDutch => afrikaansVoiceLocale != null && afrikaansVoiceLocale != 'af-ZA';

  Future<bool> _has(String locale) async {
    try {
      final r = await _tts.isLanguageAvailable(locale);
      return r == true || r == 1;
    } catch (_) {
      return false;
    }
  }

  /// Afrikaans phrases recorded by the generated Afrikaans voice
  /// (made on GitHub during the build). Null if the build had none.
  Map<String, Uint8List>? _clips;
  int _clipRate = 16000;
  final AudioPlayer _player = AudioPlayer();
  int _clipNo = 0;

  bool get hasAfrikaansClips => _clips != null && _clips!.isNotEmpty;

  /// True when Afrikaans is spoken with the recorded phrases.
  bool get _useClips =>
      settings.voiceLang == 'af' && afrikaansVoiceLocale != 'af-ZA' && hasAfrikaansClips;

  Future<void> _loadClips() async {
    try {
      final j = jsonDecode(await rootBundle.loadString('assets/voice_af/clips.json'))
          as Map<String, dynamic>;
      _clipRate = (j['sample_rate'] as num).toInt();
      final map = <String, Uint8List>{};
      for (final k in (j['clips'] as List).cast<String>()) {
        final data = await rootBundle.load('assets/voice_af/$k.wav');
        final pcm = _pcmFromWav(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        if (pcm != null) map[k] = pcm;
      }
      _clips = map;
    } catch (_) {
      _clips = null;
    }
  }

  /// Returns the raw sound samples inside a WAV file.
  static Uint8List? _pcmFromWav(Uint8List b) {
    if (b.length < 12) return null;
    var i = 12;
    final bd = ByteData.sublistView(b);
    while (i + 8 <= b.length) {
      final id = String.fromCharCodes(b.sublist(i, i + 4));
      final size = bd.getUint32(i + 4, Endian.little);
      if (id == 'data') {
        final end = (i + 8 + size).clamp(0, b.length);
        return Uint8List.sublistView(b, i + 8, end);
      }
      i += 8 + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  Future<void> _playClips(List<String> keys) async {
    final clips = _clips;
    if (clips == null) return;
    final gap = Uint8List((_clipRate * 0.12).round() * 2); // short pause
    final parts = <Uint8List>[];
    for (final k in keys) {
      final c = clips[k];
      if (c == null) continue;
      if (parts.isNotEmpty) parts.add(gap);
      parts.add(c);
    }
    if (parts.isEmpty) return;
    final len = parts.fold<int>(0, (a, p) => a + p.length);
    final out = BytesBuilder();
    final h = ByteData(44);
    void s(int o, String v) {
      for (var n = 0; n < 4; n++) {
        h.setUint8(o + n, v.codeUnitAt(n));
      }
    }
    s(0, 'RIFF');
    h.setUint32(4, 36 + len, Endian.little);
    s(8, 'WAVE');
    s(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little); // PCM
    h.setUint16(22, 1, Endian.little); // mono
    h.setUint32(24, _clipRate, Endian.little);
    h.setUint32(28, _clipRate * 2, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    s(36, 'data');
    h.setUint32(40, len, Endian.little);
    out.add(h.buffer.asUint8List());
    for (final p in parts) {
      out.add(p);
    }
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/say_${_clipNo++ % 4}.wav');
      await f.writeAsBytes(out.takeBytes(), flush: true);
      await _tts.stop();
      await _player.stop();
      await _player.play(DeviceFileSource(f.path));
    } catch (_) {}
  }

  Future<void> _speak(String text, List<String> keys) async {
    if (!settings.voiceOn) return;
    if (_useClips) {
      await _playClips(keys);
    } else {
      await say(text);
    }
  }

  Future<void> init() async {
    await _loadClips();
    for (final l in ['af-ZA', 'nl-NL', 'nl-BE']) {
      if (await _has(l)) {
        afrikaansVoiceLocale = l;
        break;
      }
    }
    // A real Afrikaans voice wins, then the recorded phrases, then Dutch.
    if (afrikaansVoiceLocale != 'af-ZA' && hasAfrikaansClips) afrikaansVoiceLocale = null;
    afrikaansAvailable = afrikaansVoiceLocale != null || hasAfrikaansClips;
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _applyLanguage();
  }

  /// The language actually used (falls back to English if no Afrikaans voice).
  String get lang => settings.voiceLang == 'af' && afrikaansAvailable ? 'af' : 'en';

  Future<void> _applyLanguage() async {
    if (_activeLang == lang) return;
    try {
      if (lang == 'af' && afrikaansVoiceLocale != null) {
        await _tts.setLanguage(afrikaansVoiceLocale!);
      } else {
        final za = await _tts.isLanguageAvailable('en-ZA');
        await _tts.setLanguage(za == true || za == 1 ? 'en-ZA' : 'en-GB');
      }
      _activeLang = lang;
    } catch (_) {}
  }

  Future<void> say(String text) async {
    if (!settings.voiceOn || text.isEmpty) return;
    await _applyLanguage();
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
      await _player.stop();
    } catch (_) {}
  }

  // ---------------- Spoken prompts ----------------

  static const _distKeys = <int, String>{
    50: 'd50', 100: 'd100', 150: 'd150', 200: 'd200', 250: 'd250', 300: 'd300',
    400: 'd400', 500: 'd500', 600: 'd600', 700: 'd700', 800: 'd800', 900: 'd900',
    1000: 'd1000', 1500: 'd1500', 2000: 'd2000', 3000: 'd3000',
  };

  String _distKey(double m) {
    var best = 50;
    for (final d in _distKeys.keys) {
      if ((d - m).abs() < (best - m).abs()) best = d;
    }
    return _distKeys[best]!;
  }

  String _actionKey(Maneuver m) {
    switch (m.type) {
      case 1:
      case 2:
      case 3:
        return 'start';
      case 4:
      case 5:
      case 6:
        return 'arrive';
      case 9:
        return 'slight_right';
      case 10:
        return 'right';
      case 11:
        return 'sharp_right';
      case 12:
      case 13:
        return 'uturn';
      case 14:
        return 'sharp_left';
      case 15:
        return 'left';
      case 16:
        return 'slight_left';
      case 17:
        return 'ramp';
      case 18:
        return 'ramp_right';
      case 19:
        return 'ramp_left';
      case 20:
        return 'exit_right';
      case 21:
        return 'exit_left';
      case 23:
        return 'keep_right';
      case 24:
        return 'keep_left';
      case 25:
      case 37:
      case 38:
        return 'merge';
      case 26:
        final n = m.roundaboutExit;
        return n >= 1 && n <= 8 ? 'roundabout_$n' : 'roundabout';
      case 27:
        return 'roundabout_exit';
      case 28:
        return 'ferry';
      case 29:
        return 'ferry_exit';
      default:
        return 'straight';
    }
  }

  Future<void> sayAnnouncement(Maneuver m, double distanceM) =>
      _speak(announcement(m, distanceM), [_distKey(distanceM), _actionKey(m)]);

  Future<void> sayNow(Maneuver m) {
    final k = _actionKey(m);
    return _speak(now(m), k == 'arrive' ? [k] : ['now', k]);
  }

  Future<void> sayRerouting() => _speak(rerouting(), ['reroute']);

  Future<void> sayStarted() => _speak(started(), ['start']);

  Future<void> sayFaster() =>
      _speak(lang == 'af' ? 'Vinniger roete gevind.' : 'Faster route found.', ['faster']);

  Future<void> sayLanguageSelected() => _speak(
      lang == 'af' ? 'Afrikaans stem gekies.' : 'English voice selected.', ['selected']);

  // ---------------- Phrases ----------------

  static const _ordEn = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh', 'eighth'];
  static const _ordAf = ['eerste', 'tweede', 'derde', 'vierde', 'vyfde', 'sesde', 'sewende', 'agtste'];

  String _onto(Maneuver m, String l) {
    if (m.street.isEmpty) return '';
    return l == 'af' ? ' in ${m.street}' : ' onto ${m.street}';
  }

  /// What to do, without the distance: "turn right onto Main Road".
  String action(Maneuver m, {String? language}) {
    final l = language ?? lang;
    final af = l == 'af';
    final onto = _onto(m, l);
    switch (m.type) {
      case 1:
      case 2:
      case 3:
        return af ? 'ry$onto' : 'head out$onto';
      case 4:
      case 5:
      case 6:
        return af ? 'jy het jou bestemming bereik' : 'you have arrived at your destination';
      case 9:
        return af ? 'draai effens regs$onto' : 'bear right$onto';
      case 10:
        return af ? 'draai regs$onto' : 'turn right$onto';
      case 11:
        return af ? 'draai skerp regs$onto' : 'turn sharp right$onto';
      case 12:
      case 13:
        return af ? 'maak \'n U-draai' : 'make a U-turn';
      case 14:
        return af ? 'draai skerp links$onto' : 'turn sharp left$onto';
      case 15:
        return af ? 'draai links$onto' : 'turn left$onto';
      case 16:
        return af ? 'draai effens links$onto' : 'bear left$onto';
      case 17:
        return af ? 'neem die oprit$onto' : 'take the ramp$onto';
      case 18:
        return af ? 'neem die oprit regs$onto' : 'take the ramp on the right$onto';
      case 19:
        return af ? 'neem die oprit links$onto' : 'take the ramp on the left$onto';
      case 20:
        return af ? 'neem die afrit regs$onto' : 'take the exit on the right$onto';
      case 21:
        return af ? 'neem die afrit links$onto' : 'take the exit on the left$onto';
      case 23:
        return af ? 'hou regs$onto' : 'keep right$onto';
      case 24:
        return af ? 'hou links$onto' : 'keep left$onto';
      case 25:
      case 37:
      case 38:
        return af ? 'voeg in$onto' : 'merge$onto';
      case 26:
        final n = m.roundaboutExit;
        if (n >= 1 && n <= 8) {
          return af
              ? 'by die verkeerssirkel, neem die ${_ordAf[n - 1]} afrit$onto'
              : 'at the roundabout, take the ${_ordEn[n - 1]} exit$onto';
        }
        return af ? 'ry by die verkeerssirkel in' : 'enter the roundabout';
      case 27:
        return af ? 'verlaat die verkeerssirkel$onto' : 'exit the roundabout$onto';
      case 28:
        return af ? 'neem die pont' : 'take the ferry';
      case 29:
        return af ? 'verlaat die pont' : 'leave the ferry';
      default:
        return af ? 'gaan reguit aan$onto' : 'continue straight$onto';
    }
  }

  String _distanceWords(double m, String l) {
    final af = l == 'af';
    if (m >= 1000) {
      final km = (m / 1000);
      final s = km >= 10 ? km.round().toString() : km.toStringAsFixed(1).replaceAll('.0', '');
      return af ? 'Oor $s kilometer' : 'In $s kilometres';
    }
    final rounded = m >= 100 ? (m / 50).round() * 50 : (m / 10).round() * 10;
    return af ? 'Oor $rounded meter' : 'In $rounded metres';
  }

  String announcement(Maneuver m, double distanceM) {
    final a = action(m);
    return '${_distanceWords(distanceM, lang)}, $a.';
  }

  String now(Maneuver m) {
    final a = action(m);
    final then = lang == 'af' ? 'Nou, $a.' : '${a[0].toUpperCase()}${a.substring(1)}.';
    return then;
  }

  String rerouting() => lang == 'af' ? 'Roete word herbereken.' : 'Recalculating route.';

  String started() => lang == 'af' ? 'Kom ons ry.' : "Let's go.";

  static IconData iconFor(Maneuver? m) {
    if (m == null) return Icons.navigation;
    switch (m.type) {
      case 4:
      case 5:
      case 6:
        return Icons.flag;
      case 9:
      case 23:
        return Icons.turn_slight_right;
      case 10:
        return Icons.turn_right;
      case 11:
        return Icons.turn_sharp_right;
      case 12:
        return Icons.u_turn_right;
      case 13:
        return Icons.u_turn_left;
      case 14:
        return Icons.turn_sharp_left;
      case 15:
        return Icons.turn_left;
      case 16:
      case 24:
        return Icons.turn_slight_left;
      case 18:
      case 20:
        return Icons.ramp_right;
      case 19:
      case 21:
        return Icons.ramp_left;
      case 25:
      case 37:
      case 38:
        return Icons.merge;
      case 26:
      case 27:
        return Icons.roundabout_left; // South Africa drives on the left
      case 28:
      case 29:
        return Icons.directions_boat;
      default:
        return Icons.straight;
    }
  }
}
