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
    # Keep navigating with the screen off / app in the background.
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_LOCATION",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
    # Android Auto navigation app
    "androidx.car.app.NAVIGATION_TEMPLATES",
    "androidx.car.app.ACCESS_SURFACE",
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
        </intent>
        <intent>
            <action android:name="android.intent.action.DIAL"/>
            <data android:scheme="tel"/>
        </intent>"""
if "TTS_SERVICE" not in xml:
    if "<queries>" in xml:
        xml = xml.replace("<queries>", "<queries>" + intents, 1)
    else:
        xml = xml.replace("</manifest>", "    <queries>" + intents + "\n    </queries>\n</manifest>")

# Android Auto: the car app service and its declaration.
car = '''
        <service
            android:name=".SafeRouteCarAppService"
            android:exported="true">
            <intent-filter>
                <action android:name="androidx.car.app.CarAppService"/>
                <category android:name="androidx.car.app.category.NAVIGATION"/>
            </intent-filter>
        </service>
        <meta-data
            android:name="com.google.android.gms.car.application"
            android:resource="@xml/automotive_app_desc"/>
        <meta-data
            android:name="androidx.car.app.minCarApiLevel"
            android:value="1"/>
'''
car += '''
        <provider
            android:name="rikka.shizuku.ShizukuProvider"
            android:authorities="za.saferoute.saferoute_sa.shizuku"
            android:multiprocess="false"
            android:enabled="true"
            android:exported="true"
            android:permission="android.permission.INTERACT_ACROSS_USERS_FULL"/>
'''
if "SafeRouteCarAppService" not in xml:
    xml = xml.replace("</application>", car + "    </application>", 1)

manifest.write_text(xml)
print("AndroidManifest.xml patched")

res_xml = pathlib.Path("android/app/src/main/res/xml")
res_xml.mkdir(parents=True, exist_ok=True)
(res_xml / "automotive_app_desc.xml").write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n<automotiveApp>\n    <uses name="template"/>\n</automotiveApp>\n'
)

# ---------------- Offline routing (Valhalla on the phone) ----------------
import glob
import shutil

VALHALLA = "0.6.4"
MODELS = "0.6.0"

# 1. Our MainActivity talks to the on-phone route engine.
targets = glob.glob("android/app/src/main/kotlin/**/MainActivity.kt", recursive=True)
target = targets[0] if targets else "android/app/src/main/kotlin/za/saferoute/saferoute_sa/MainActivity.kt"
pathlib.Path(target).parent.mkdir(parents=True, exist_ok=True)
shutil.copy("tool/android/MainActivity.kt", target)
shutil.copy("tool/android/CarService.kt", str(pathlib.Path(target).parent / "CarService.kt"))
print(f"MainActivity written to {target}")

# 2. Gradle: engine library, Android 7+ (minSdk 24), 64-bit ARM phones only (smaller APK).
gradle = pathlib.Path("android/app/build.gradle.kts")
g = gradle.read_text()
g = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 24", g)
if "abiFilters" not in g:
    g = re.sub(r"(defaultConfig\s*\{)", r'\1\n        ndk { abiFilters += listOf("arm64-v8a") }', g, count=1)
if "valhalla-mobile" not in g:
    g += f'''
dependencies {{
    implementation("io.github.rallista:valhalla-mobile:{VALHALLA}")
    // Types the engine uses in its public API.
    implementation("io.github.rallista:valhalla-models:{MODELS}")
    implementation("io.github.rallista:valhalla-models-config:{MODELS}")
    implementation("com.squareup.moshi:moshi-kotlin:1.15.1")
    // Android Auto (car screen)
    implementation("androidx.car.app:app:1.4.0")
    // Shizuku: install SafeRoute "from the Play Store" so Android Auto lists it
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    // The map engine the Flutter map plugin already ships (compile against it only).
    compileOnly("org.maplibre.gl:android-sdk-opengl:13.7.1")
}}
'''
gradle.write_text(g)
print("app/build.gradle.kts patched")

# 3. The engine was built with Kotlin 2.3: use the same Kotlin version.
settings = pathlib.Path("android/settings.gradle.kts")
s = settings.read_text()
s = re.sub(r'(id\("org\.jetbrains\.kotlin\.android"\)\s+version\s+")[^"]+(")', r"\g<1>2.3.20\2", s)
settings.write_text(s)
print("settings.gradle.kts patched:", re.findall(r'kotlin\.android"\)\s+version\s+"[^"]+"', s))
