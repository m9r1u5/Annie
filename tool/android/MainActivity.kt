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
