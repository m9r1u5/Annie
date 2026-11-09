"""Adds permissions, app name and settings to the Android project that
'flutter create' generates during the GitHub build."""
import pathlib
import re

manifest = pathlib.Path("android/app/src/main/AndroidManifest.xml")
xml = manifest.read_text()

permissions = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.ACCESS_FINE_LOCATION",
    "android.permission.ACCESS_COARSE_LOCATION",
    "android.permission.WAKE_LOCK",
]
lines = "".join(
    f'    <uses-permission android:name="{p}"/>\n'
    for p in permissions
    if p not in xml
)
xml = re.sub(r"(<manifest[^>]*>\n)", r"\1" + lines.replace("\\", "\\\\"), xml, count=1)

# App name shown under the icon.
xml = re.sub(r'android:label="[^"]*"', 'android:label="SafeRoute SA"', xml, count=1)

# Lets the app find text-to-speech engines, the browser and WhatsApp (Android 11+).
intents = """
        <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>
        <intent>
            <action android:name="android.intent.action.VIEW"/>
            <data android:scheme="https"/>
        </intent>
        <intent>
            <action android:name="android.intent.action.SEND"/>
            <data android:mimeType="text/plain"/>
        </intent>"""
if "TTS_SERVICE" not in xml:
    if "<queries>" in xml:
        xml = xml.replace("<queries>", "<queries>" + intents, 1)
    else:
        xml = xml.replace("</manifest>", "    <queries>" + intents + "\n    </queries>\n</manifest>")

manifest.write_text(xml)
print("AndroidManifest.xml patched")
