"""Generates the Afrikaans voice clips used by SafeRoute SA.

Runs on GitHub (build.yml) with Meta's free MMS Afrikaans voice
(facebook/mms-tts-afr, CC-BY-NC 4.0: personal / non-commercial use only).
Writes assets/voice_af/<key>.wav and assets/voice_af/clips.json.

Numbers are written out in words because the voice cannot read digits.
"""
import json
import os
import wave

import torch
from transformers import AutoTokenizer, VitsModel

OUT = "assets/voice_af"

PHRASES = {
    # Distances (played before an instruction)
    "d50": "oor vyftig meter",
    "d100": "oor honderd meter",
    "d150": "oor honderd en vyftig meter",
    "d200": "oor tweehonderd meter",
    "d250": "oor tweehonderd en vyftig meter",
    "d300": "oor driehonderd meter",
    "d400": "oor vierhonderd meter",
    "d500": "oor vyfhonderd meter",
    "d600": "oor seshonderd meter",
    "d700": "oor sewehonderd meter",
    "d800": "oor agthonderd meter",
    "d900": "oor negehonderd meter",
    "d1000": "oor een kilometer",
    "d1500": "oor anderhalf kilometer",
    "d2000": "oor twee kilometer",
    "d3000": "oor drie kilometer",
    "now": "nou",
    # Instructions
    "start": "kom ons ry",
    "arrive": "jy het jou bestemming bereik",
    "slight_right": "draai effens regs",
    "right": "draai regs",
    "sharp_right": "draai skerp regs",
    "uturn": "draai om",
    "sharp_left": "draai skerp links",
    "left": "draai links",
    "slight_left": "draai effens links",
    "ramp": "neem die oprit",
    "ramp_right": "neem die oprit regs",
    "ramp_left": "neem die oprit links",
    "exit_right": "neem die afrit regs",
    "exit_left": "neem die afrit links",
    "keep_right": "hou regs",
    "keep_left": "hou links",
    "merge": "voeg in",
    "roundabout": "ry by die verkeerssirkel in",
    "roundabout_1": "by die verkeerssirkel neem die eerste afrit",
    "roundabout_2": "by die verkeerssirkel neem die tweede afrit",
    "roundabout_3": "by die verkeerssirkel neem die derde afrit",
    "roundabout_4": "by die verkeerssirkel neem die vierde afrit",
    "roundabout_5": "by die verkeerssirkel neem die vyfde afrit",
    "roundabout_6": "by die verkeerssirkel neem die sesde afrit",
    "roundabout_7": "by die verkeerssirkel neem die sewende afrit",
    "roundabout_8": "by die verkeerssirkel neem die agtste afrit",
    "roundabout_exit": "verlaat die verkeerssirkel",
    "ferry": "neem die pont",
    "ferry_exit": "verlaat die pont",
    "straight": "gaan reguit aan",
    "reroute": "roete word herbereken",
    "selected": "afrikaanse stem gekies",
}

os.makedirs(OUT, exist_ok=True)
tok = AutoTokenizer.from_pretrained("facebook/mms-tts-afr")
model = VitsModel.from_pretrained("facebook/mms-tts-afr")
model.eval()
rate = model.config.sampling_rate

for key, text in PHRASES.items():
    torch.manual_seed(7)  # same sound on every build
    inputs = tok(text, return_tensors="pt")
    with torch.no_grad():
        audio = model(**inputs).waveform[0]
    peak = float(audio.abs().max()) or 1.0
    pcm = (audio / peak * 0.9 * 32767).to(torch.int16).numpy().tobytes()
    with wave.open(f"{OUT}/{key}.wav", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    print(f"{key}: {text} ({len(pcm) / 2 / rate:.1f}s)")

with open(f"{OUT}/clips.json", "w") as f:
    json.dump({"sample_rate": rate, "clips": sorted(PHRASES)}, f)
