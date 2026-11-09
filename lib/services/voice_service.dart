import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

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

  Future<void> init() async {
    try {
      final af = await _tts.isLanguageAvailable('af-ZA');
      afrikaansAvailable = af == true || af == 1;
    } catch (_) {
      afrikaansAvailable = false;
    }
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _applyLanguage();
  }

  /// The language actually used (falls back to English if no Afrikaans voice).
  String get lang => settings.voiceLang == 'af' && afrikaansAvailable ? 'af' : 'en';

  Future<void> _applyLanguage() async {
    if (_activeLang == lang) return;
    try {
      if (lang == 'af') {
        await _tts.setLanguage('af-ZA');
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
    } catch (_) {}
  }

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
