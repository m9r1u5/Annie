package za.saferoute.saferoute_sa

import android.os.Handler
import android.os.Looper
import com.valhalla.valhalla.Valhalla
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import org.json.JSONObject
import android.content.pm.PackageManager
import rikka.shizuku.Shizuku
import java.io.FileInputStream
import java.io.InputStream

/**
 * Runs the Valhalla route engine on the phone (offline routing).
 * Dart sends the same JSON it would send to the online server and gets the
 * same JSON back, so the app's routing code works with either.
 */
class MainActivity : FlutterActivity() {
    private var valhalla: Valhalla? = null
    private var openTilesDir: String? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android Auto: the phone app sends its navigation state to the car screen,
        // and the car screen can ask the phone to end the trip.
        val car = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "saferoute/car")
        car.setMethodCallHandler { call, result ->
            if (call.method == "update") {
                val json = call.arguments as? String
                if (json != null) {
                    try {
                        CarState.update(json)
                    } catch (_: Throwable) {
                    }
                }
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
        CarState.toPhone = { action -> main.post { car.invokeMethod("carAction", action) } }

        // Shizuku: (re)install SafeRoute with the Play Store as installer, so
        // Android Auto lists it (it hides apps installed from a browser).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "saferoute/shizuku")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(shizukuStatus())
                    "request" -> {
                        try {
                            if (Shizuku.pingBinder() && Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                                Shizuku.requestPermission(4242)
                            }
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("SHIZUKU", e.message, null)
                        }
                    }
                    "installSelf" -> worker.execute {
                        val out = installViaShizuku(FileInputStream(applicationInfo.sourceDir))
                        main.post { result.success(out) }
                    }
                    "installFile" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("ARGS", "path required", null)
                        } else {
                            worker.execute {
                                val out = installViaShizuku(FileInputStream(path))
                                main.post { result.success(out) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "saferoute/valhalla")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "route" -> {
                        val dir = call.argument<String>("tilesDir")
                        val request = call.argument<String>("request")
                        if (dir == null || request == null) {
                            result.error("ARGS", "tilesDir and request are required", null)
                        } else {
                            worker.execute {
                                try {
                                    val answer = engine(dir).routeRaw(request)
                                    main.post { result.success(answer) }
                                } catch (e: Throwable) {
                                    main.post { result.error("VALHALLA", e.message ?: e.toString(), null) }
                                }
                            }
                        }
                    }
                    // Close the engine so it re-reads tiles after a download or delete.
                    "reset" -> worker.execute {
                        try {
                            valhalla?.close()
                        } catch (_: Throwable) {
                        }
                        valhalla = null
                        openTilesDir = null
                        main.post { result.success(true) }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun shizukuStatus(): Map<String, Any> {
        val installed = try {
            packageManager.getPackageInfo("moe.shizuku.privileged.api", 0)
            true
        } catch (_: Throwable) {
            false
        }
        val running = try {
            Shizuku.pingBinder()
        } catch (_: Throwable) {
            false
        }
        val granted = running && try {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) {
            false
        }
        val installer = try {
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                packageManager.getInstallSourceInfo(packageName).installingPackageName ?: ""
            } else {
                @Suppress("DEPRECATION")
                packageManager.getInstallerPackageName(packageName) ?: ""
            }
        } catch (_: Throwable) {
            ""
        }
        return mapOf("installed" to installed, "running" to running, "granted" to granted, "installer" to installer)
    }

    /** Runs a shell command through Shizuku (as the ADB shell user). */
    private fun shizukuShell(cmd: String, input: InputStream?): Pair<Int, String> {
        val m = Shizuku::class.java.getDeclaredMethod(
            "newProcess", Array<String>::class.java, Array<String>::class.java, String::class.java
        )
        m.isAccessible = true
        val p = m.invoke(null, arrayOf("sh", "-c", cmd), null, null) as Process
        if (input != null) {
            p.outputStream.use { o -> input.use { it.copyTo(o) } }
        } else {
            p.outputStream.close()
        }
        val out = p.inputStream.bufferedReader().readText() + p.errorStream.bufferedReader().readText()
        return p.waitFor() to out.trim()
    }

    /** Copies the APK to the phone's temp folder and installs it as if from the Play Store. */
    private fun installViaShizuku(apk: InputStream): String {
        return try {
            val tmp = "/data/local/tmp/saferoute_install.apk"
            val (c1, o1) = shizukuShell("cat > $tmp", apk)
            if (c1 != 0) return "Copy failed: $o1"
            val (c2, o2) = shizukuShell("pm install -r -i com.android.vending $tmp; rm -f $tmp", null)
            if (c2 != 0 || !o2.contains("Success")) "Install failed: $o2" else "OK"
        } catch (e: Throwable) {
            "Error: ${e.message ?: e}"
        }
    }

    private fun engine(tilesDir: String): Valhalla {
        val current = valhalla
        if (current != null && openTilesDir == tilesDir) return current
        try {
            current?.close()
        } catch (_: Throwable) {
        }
        val created = Valhalla(writeConfig(tilesDir))
        valhalla = created
        openTilesDir = tilesDir
        return created
    }

    /** Valhalla's default settings, pointed at our tile folder, with bigger avoid-zone limits. */
    private fun writeConfig(tilesDir: String): String {
        val text = javaClass.getResourceAsStream("/com/valhalla/valhalla/default.json")
            ?.bufferedReader()?.use { it.readText() }
            ?: throw IllegalStateException("Valhalla default config missing")
        val config = JSONObject(text)
        val mjolnir = config.getJSONObject("mjolnir")
        mjolnir.put("tile_dir", tilesDir)
        mjolnir.remove("tile_extract")
        mjolnir.remove("traffic_extract")
        mjolnir.remove("tile_url")
        val limits = config.optJSONObject("service_limits")
        // Your avoid zones can be large: allow up to 1,000 km of zone outline.
        limits?.put("max_exclude_polygons_length", 1_000_000)
        val file = File(filesDir, "valhalla_offline.json")
        file.writeText(config.toString())
        return file.absolutePath
    }
}
