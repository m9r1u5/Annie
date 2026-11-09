"""Generates the Afrikaans voice clips used by SafeRoute SA.

Runs on GitHub (build.yml). Uses the Google Translate Afrikaans voice
(via the gTTS library, no key needed) and falls back to the free eSpeak NG
Afrikaans voice for any phrase that fails. Clips are made once and cached.
Writes assets/voice_af/<key>.wav (16 kHz mono) and assets/voice_af/clips.json.
"""
import json
import os
import subprocess
import time

OUT = "assets/voice_af"
RATE = 16000

PHRASES = {
    # Distances (played before an instruction)
    "d50": "Oor vyftig meter,",
    "d100": "Oor honderd meter,",
    "d150": "Oor honderd-en-vyftig meter,",
    "d200": "Oor tweehonderd meter,",
    "d250": "Oor tweehonderd-en-vyftig meter,",
    "d300": "Oor driehonderd meter,",
    "d400": "Oor vierhonderd meter,",
    "d500": "Oor vyfhonderd meter,",
    "d600": "Oor seshonderd meter,",
    "d700": "Oor sewehonderd meter,",
    "d800": "Oor agthonderd meter,",
    "d900": "Oor negehonderd meter,",
    "d1000": "Oor een kilometer,",
    "d1500": "Oor anderhalf kilometer,",
    "d2000": "Oor twee kilometer,",
    "d3000": "Oor drie kilometer,",
    "now": "Nou,",
    # Instructions
    "start": "Kom ons ry.",
    "arrive": "Jy het jou bestemming bereik.",
    "slight_right": "draai effens regs.",
    "right": "draai regs.",
    "sharp_right": "draai skerp regs.",
    "uturn": "maak 'n U-draai.",
    "sharp_left": "draai skerp links.",
    "left": "draai links.",
    "slight_left": "draai effens links.",
    "ramp": "neem die oprit.",
    "ramp_right": "neem die oprit regs.",
    "ramp_left": "neem die oprit links.",
    "exit_right": "neem die afrit regs.",
    "exit_left": "neem die afrit links.",
    "keep_right": "hou regs.",
    "keep_left": "hou links.",
    "merge": "voeg in.",
    "roundabout": "ry by die verkeerssirkel in.",
    "roundabout_1": "by die verkeerssirkel, neem die eerste afrit.",
    "roundabout_2": "by die verkeerssirkel, neem die tweede afrit.",
    "roundabout_3": "by die verkeerssirkel, neem die derde afrit.",
    "roundabout_4": "by die verkeerssirkel, neem die vierde afrit.",
    "roundabout_5": "by die verkeerssirkel, neem die vyfde afrit.",
    "roundabout_6": "by die verkeerssirkel, neem die sesde afrit.",
    "roundabout_7": "by die verkeerssirkel, neem die sewende afrit.",
    "roundabout_8": "by die verkeerssirkel, neem die agtste afrit.",
    "roundabout_exit": "verlaat die verkeerssirkel.",
    "ferry": "neem die pont.",
    "ferry_exit": "verlaat die pont.",
    "straight": "gaan reguit aan.",
    "reroute": "Roete word herbereken.",
    "selected": "Afrikaanse stem gekies.",
}

# Trim silence at both ends so joined phrases flow naturally.
TRIM = (
    "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.05,"
    "areverse,"
    "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.05,"
    "areverse"
)


def to_wav(src: str, dst: str) -> None:
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-af", TRIM,
         "-ar", str(RATE), "-ac", "1", "-sample_fmt", "s16", dst],
        check=True,
    )


def google(text: str, mp3: str) -> bool:
    try:
        from gtts import gTTS
        for attempt in range(3):
            try:
                gTTS(text=text, lang="af").save(mp3)
                return os.path.getsize(mp3) > 1000
            except Exception as e:  # network hiccup or rate limit
                print(f"  google attempt {attempt + 1} failed: {e}")
                time.sleep(3 * (attempt + 1))
    except ImportError:
        pass
    return False


def espeak(text: str, wav: str) -> bool:
    try:
        subprocess.run(["espeak-ng", "-v", "af", "-s", "150", "-w", wav, text], check=True)
        return True
    except Exception as e:
        print(f"  espeak failed: {e}")
        return False


os.makedirs(OUT, exist_ok=True)
tmp = "/tmp/afvoice"
os.makedirs(tmp, exist_ok=True)
made, engines = [], set()

for key, text in PHRASES.items():
    dst = f"{OUT}/{key}.wav"
    if google(text, f"{tmp}/{key}.mp3"):
        to_wav(f"{tmp}/{key}.mp3", dst)
        engines.add("google")
    elif espeak(text, f"{tmp}/{key}_raw.wav"):
        to_wav(f"{tmp}/{key}_raw.wav", dst)
        engines.add("espeak")
    else:
        print(f"!! no audio for {key}")
        continue
    made.append(key)
    print(f"{key}: {text}")
    time.sleep(0.4)  # be gentle with the free service

if len(made) < len(PHRASES) - 3:
    raise SystemExit(f"Only {len(made)} of {len(PHRASES)} clips made")

with open(f"{OUT}/clips.json", "w") as f:
    json.dump({"sample_rate": RATE, "clips": sorted(made), "engines": sorted(engines)}, f)
print(f"Made {len(made)} clips with {sorted(engines)}")
