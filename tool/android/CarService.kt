package za.saferoute.saferoute_sa

import android.app.Presentation
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.os.Handler
import android.os.Looper
import androidx.car.app.AppManager
import androidx.car.app.CarAppService
import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.SurfaceCallback
import androidx.car.app.SurfaceContainer
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarColor
import androidx.car.app.model.CarIcon
import androidx.car.app.model.DateTimeWithZone
import androidx.car.app.model.Distance
import androidx.car.app.model.Template
import androidx.car.app.navigation.NavigationManager
import androidx.car.app.navigation.NavigationManagerCallback
import androidx.car.app.navigation.model.Maneuver
import androidx.car.app.navigation.model.MessageInfo
import androidx.car.app.navigation.model.NavigationTemplate
import androidx.car.app.navigation.model.RoutingInfo
import androidx.car.app.navigation.model.Step
import androidx.car.app.navigation.model.TravelEstimate
import androidx.car.app.validation.HostValidator
import androidx.core.graphics.drawable.IconCompat
import android.content.Intent
import java.util.TimeZone
import org.json.JSONArray
import org.json.JSONObject
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapLibreMapOptions
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.sources.GeoJsonSource

/** What the phone app is doing right now, shared with the car screen. */
object CarState {
    var navigating = false
    var maneuverType = 0
    var roundaboutExit = 0
    var distToNextM = 0.0
    var cue = ""
    var street = ""
    var remainingM = 0.0
    var remainingS = 0.0
    var lat = Double.NaN
    var lon = Double.NaN
    var heading = 0.0
    var offRoute = false
    var stylePath: String? = null
    var routeGeoJson: String? = null
    var routeVersion = 0

    /** Called when the car screen should refresh. */
    val listeners = mutableListOf<() -> Unit>()

    /** Sends a request back to the phone app (e.g. "end"). Set by MainActivity. */
    var toPhone: ((String) -> Unit)? = null

    fun update(json: String) {
        val o = JSONObject(json)
        navigating = o.optBoolean("navigating", navigating)
        maneuverType = o.optInt("type", maneuverType)
        roundaboutExit = o.optInt("exit", roundaboutExit)
        distToNextM = o.optDouble("next", distToNextM)
        cue = o.optString("cue", cue)
        street = o.optString("street", street)
        remainingM = o.optDouble("remainingM", remainingM)
        remainingS = o.optDouble("remainingS", remainingS)
        lat = o.optDouble("lat", lat)
        lon = o.optDouble("lon", lon)
        heading = o.optDouble("heading", heading)
        offRoute = o.optBoolean("offRoute", offRoute)
        if (o.has("style")) stylePath = o.getString("style")
        if (o.has("route")) {
            val coords = o.optJSONArray("route") ?: JSONArray()
            routeGeoJson = JSONObject()
                .put("type", "Feature")
                .put("properties", JSONObject())
                .put("geometry", JSONObject().put("type", "LineString").put("coordinates", coords))
                .toString()
            routeVersion++
        }
        listeners.toList().forEach { it() }
    }
}

/** Android Auto entry point. */
class SafeRouteCarAppService : CarAppService() {
    // Sideloaded personal app: accept any Android Auto host.
    override fun createHostValidator(): HostValidator = HostValidator.ALLOW_ALL_HOSTS_VALIDATOR

    override fun onCreateSession(): Session = NavSession()
}

class NavSession : Session() {
    override fun onCreateScreen(intent: Intent): Screen = NavScreen(carContext)
}

/** The navigation screen on the car display: map + turn card + arrival time. */
class NavScreen(carContext: CarContext) : Screen(carContext) {
    private val renderer = CarMapRenderer(carContext)
    private val main = Handler(Looper.getMainLooper())
    private var lastInvalidate = 0L
    private var pending = false
    private var wasNavigating = false
    private val navManager: NavigationManager = carContext.getCarService(NavigationManager::class.java)

    private val onState: () -> Unit = {
        main.post {
            renderer.update()
            if (CarState.navigating != wasNavigating) {
                wasNavigating = CarState.navigating
                try {
                    if (wasNavigating) navManager.navigationStarted() else navManager.navigationEnded()
                } catch (_: Throwable) {
                }
            }
            throttledInvalidate()
        }
    }

    init {
        carContext.getCarService(AppManager::class.java).setSurfaceCallback(renderer)
        navManager.setNavigationManagerCallback(object : NavigationManagerCallback {
            override fun onStopNavigation() {
                CarState.toPhone?.invoke("end")
            }
        })
        CarState.listeners.add(onState)
        lifecycle.addObserver(object : androidx.lifecycle.DefaultLifecycleObserver {
            override fun onDestroy(owner: androidx.lifecycle.LifecycleOwner) {
                CarState.listeners.remove(onState)
                renderer.release()
            }
        })
    }

    private fun throttledInvalidate() {
        val now = System.currentTimeMillis()
        if (now - lastInvalidate >= 1000) {
            lastInvalidate = now
            invalidate()
        } else if (!pending) {
            pending = true
            main.postDelayed({
                pending = false
                lastInvalidate = System.currentTimeMillis()
                invalidate()
            }, 1000)
        }
    }

    override fun onGetTemplate(): Template {
        val s = CarState
        val strip = ActionStrip.Builder()
            .addAction(
                Action.Builder()
                    .setTitle(if (s.navigating) "End" else "SafeRoute")
                    .setOnClickListener { if (s.navigating) s.toPhone?.invoke("end") }
                    .build()
            )
            .build()
        val b = NavigationTemplate.Builder()
            .setActionStrip(strip)
            .setBackgroundColor(CarColor.createCustom(0xFF0E7C7B.toInt(), 0xFF0A5554.toInt()))
        if (s.navigating) {
            if (s.offRoute) {
                b.setNavigationInfo(MessageInfo.Builder("Off route").setText("Finding a new route…").build())
            } else {
                val maneuver = Maneuver.Builder(carType(s.maneuverType))
                    .setIcon(CarIcon.Builder(IconCompat.createWithBitmap(arrow(s.maneuverType))).build())
                    .build()
                val step = Step.Builder(s.cue.ifEmpty { "Continue" })
                    .setManeuver(maneuver)
                    .apply { if (s.street.isNotEmpty()) setRoad(s.street) }
                    .build()
                b.setNavigationInfo(RoutingInfo.Builder().setCurrentStep(step, distance(s.distToNextM)).build())
            }
            val arrive = System.currentTimeMillis() + (s.remainingS * 1000).toLong()
            b.setDestinationTravelEstimate(
                TravelEstimate.Builder(distance(s.remainingM), DateTimeWithZone.create(arrive, TimeZone.getDefault()))
                    .setRemainingTimeSeconds(s.remainingS.toLong().coerceAtLeast(0))
                    .build()
            )
        } else {
            b.setNavigationInfo(
                MessageInfo.Builder("SafeRoute SA")
                    .setText("Choose a destination on your phone and press Go.")
                    .build()
            )
        }
        return b.build()
    }

    private fun distance(m: Double): Distance =
        if (m >= 1000) Distance.create(m / 1000.0, Distance.UNIT_KILOMETERS)
        else Distance.create((Math.round(m / 10.0) * 10).toDouble(), Distance.UNIT_METERS)

    /** Valhalla maneuver numbers -> Android Auto maneuver types (South Africa: roundabouts clockwise). */
    private fun carType(t: Int): Int = when (t) {
        1, 2, 3 -> Maneuver.TYPE_DEPART
        4, 5, 6 -> Maneuver.TYPE_DESTINATION
        9 -> Maneuver.TYPE_TURN_SLIGHT_RIGHT
        10 -> Maneuver.TYPE_TURN_NORMAL_RIGHT
        11 -> Maneuver.TYPE_TURN_SHARP_RIGHT
        12 -> Maneuver.TYPE_U_TURN_RIGHT
        13 -> Maneuver.TYPE_U_TURN_LEFT
        14 -> Maneuver.TYPE_TURN_SHARP_LEFT
        15 -> Maneuver.TYPE_TURN_NORMAL_LEFT
        16 -> Maneuver.TYPE_TURN_SLIGHT_LEFT
        18 -> Maneuver.TYPE_ON_RAMP_SLIGHT_RIGHT
        19 -> Maneuver.TYPE_ON_RAMP_SLIGHT_LEFT
        20 -> Maneuver.TYPE_OFF_RAMP_SLIGHT_RIGHT
        21 -> Maneuver.TYPE_OFF_RAMP_SLIGHT_LEFT
        23 -> Maneuver.TYPE_KEEP_RIGHT
        24 -> Maneuver.TYPE_KEEP_LEFT
        25, 37, 38 -> Maneuver.TYPE_MERGE_SIDE_UNSPECIFIED
        26 -> Maneuver.TYPE_ROUNDABOUT_ENTER_CW
        27 -> Maneuver.TYPE_ROUNDABOUT_EXIT_CW
        28, 29 -> Maneuver.TYPE_FERRY_BOAT
        else -> Maneuver.TYPE_STRAIGHT
    }

    /** Simple white turn arrow for the car's turn card. */
    private fun arrow(t: Int): Bitmap {
        val size = 128
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.STROKE
            strokeWidth = 14f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        if (t in 4..6) { // destination: a ring
            c.drawCircle(64f, 64f, 34f, p)
            p.style = Paint.Style.FILL
            c.drawCircle(64f, 64f, 14f, p)
            return bmp
        }
        val angle = when (t) {
            9, 18, 20, 23 -> 45.0
            10 -> 90.0
            11 -> 135.0
            12, 13 -> 180.0
            14 -> -135.0
            15 -> -90.0
            16, 19, 21, 24 -> -45.0
            26 -> 90.0
            else -> 0.0
        }
        val cx = 64f
        val cy = 70f
        val path = Path()
        path.moveTo(cx, 118f)
        path.lineTo(cx, cy)
        val rad = Math.toRadians(angle)
        val len = if (angle == 180.0) 0f else 46f
        val ex: Float
        val ey: Float
        if (angle == 180.0) { // U-turn
            val dir = if (t == 12) 1 else -1
            path.lineTo(cx, 34f)
            path.quadTo(cx, 12f, cx + dir * 24f, 12f)
            path.quadTo(cx + dir * 46f, 12f, cx + dir * 46f, 34f)
            path.lineTo(cx + dir * 46f, 70f)
            ex = cx + dir * 46f
            ey = 70f
            c.drawPath(path, p)
            drawHead(c, p, ex, ey, 180.0)
            return bmp
        }
        ex = cx + (Math.sin(rad) * len).toFloat()
        ey = cy - (Math.cos(rad) * len).toFloat()
        path.lineTo(ex, ey)
        c.drawPath(path, p)
        drawHead(c, p, ex, ey, angle)
        return bmp
    }

    private fun drawHead(c: Canvas, p: Paint, x: Float, y: Float, angleDeg: Double) {
        val a = Math.toRadians(angleDeg)
        val l = 22.0
        for (side in listOf(-1, 1)) {
            val b = a + Math.PI + side * Math.PI / 5
            c.drawLine(x, y, x + (Math.sin(b) * l).toFloat(), y - (Math.cos(b) * l).toFloat(), p)
        }
    }
}

/** Draws the SafeRoute map on the car display (MapLibre view on a virtual display). */
class CarMapRenderer(private val carContext: CarContext) : SurfaceCallback {
    private var display: VirtualDisplay? = null
    private var presentation: Presentation? = null
    private var mapView: MapView? = null
    private var map: MapLibreMap? = null
    private var loadedStyle: String? = null
    private var shownRoute = -1
    private var visible: Rect? = null

    override fun onSurfaceAvailable(container: SurfaceContainer) {
        val surface = container.surface ?: return
        release()
        MapLibre.getInstance(carContext.applicationContext)
        val dm = carContext.getSystemService(DisplayManager::class.java)
        val vd = dm.createVirtualDisplay(
            "SafeRouteCarMap", container.width, container.height, container.dpi, surface,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY
        )
        display = vd
        val pres = Presentation(carContext, vd.display)
        val options = MapLibreMapOptions.createFromAttributes(pres.context).textureMode(true)
        val view = MapView(pres.context, options)
        pres.setContentView(view)
        pres.show()
        presentation = pres
        mapView = view
        view.onCreate(null)
        view.onStart()
        view.onResume()
        view.getMapAsync { m ->
            map = m
            m.uiSettings.isAttributionEnabled = false
            m.uiSettings.isLogoEnabled = false
            m.uiSettings.isCompassEnabled = false
            loadedStyle = null
            update()
        }
    }

    override fun onVisibleAreaChanged(visibleArea: Rect) {
        visible = visibleArea
        update()
    }

    override fun onSurfaceDestroyed(container: SurfaceContainer) {
        release()
    }

    fun release() {
        try {
            mapView?.onPause()
            mapView?.onStop()
            mapView?.onDestroy()
        } catch (_: Throwable) {
        }
        try {
            presentation?.dismiss()
        } catch (_: Throwable) {
        }
        display?.release()
        mapView = null
        presentation = null
        display = null
        map = null
        loadedStyle = null
        shownRoute = -1
    }

    /** Applies the latest phone state: style, route line, car position, camera. */
    fun update() {
        val m = map ?: return
        val s = CarState
        val wanted = s.stylePath ?: "https://tiles.openfreemap.org/styles/liberty"
        if (wanted != loadedStyle) {
            loadedStyle = wanted
            shownRoute = -1
            val uri = if (wanted.startsWith("http")) wanted else "file://$wanted"
            m.setStyle(Style.Builder().fromUri(uri)) { style ->
                style.addSource(GeoJsonSource("sr-route"))
                style.addSource(GeoJsonSource("sr-car"))
                style.addLayer(
                    LineLayer("sr-route-casing", "sr-route").withProperties(
                        PropertyFactory.lineColor("#0D47A1"),
                        PropertyFactory.lineWidth(12f),
                        PropertyFactory.lineCap(Property.LINE_CAP_ROUND),
                        PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
                    )
                )
                style.addLayer(
                    LineLayer("sr-route-line", "sr-route").withProperties(
                        PropertyFactory.lineColor("#1E88E5"),
                        PropertyFactory.lineWidth(8f),
                        PropertyFactory.lineCap(Property.LINE_CAP_ROUND),
                        PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
                    )
                )
                style.addLayer(
                    CircleLayer("sr-car-dot", "sr-car").withProperties(
                        PropertyFactory.circleRadius(11f),
                        PropertyFactory.circleColor("#1E88E5"),
                        PropertyFactory.circleStrokeColor("#FFFFFF"),
                        PropertyFactory.circleStrokeWidth(4f),
                    )
                )
                update()
            }
            return
        }
        val style = m.style ?: return
        if (!style.isFullyLoaded) return
        if (s.routeVersion != shownRoute) {
            shownRoute = s.routeVersion
            val src = style.getSourceAs<GeoJsonSource>("sr-route")
            src?.setGeoJson(
                if (s.navigating && s.routeGeoJson != null) s.routeGeoJson!!
                else """{"type":"FeatureCollection","features":[]}"""
            )
        }
        if (!s.lat.isNaN() && !s.lon.isNaN()) {
            style.getSourceAs<GeoJsonSource>("sr-car")?.setGeoJson(
                """{"type":"Point","coordinates":[${s.lon},${s.lat}]}"""
            )
            // Keep the car low on the screen, clear of the turn card.
            visible?.let { r ->
                val h = mapView?.height ?: 0
                m.setPadding(r.left, r.top + (r.height() / 3), 0, (h - r.bottom).coerceAtLeast(0))
            }
            m.easeCamera(
                CameraUpdateFactory.newCameraPosition(
                    CameraPosition.Builder()
                        .target(LatLng(s.lat, s.lon))
                        .zoom(if (s.navigating) 16.5 else 15.0)
                        .bearing(if (s.navigating) s.heading else 0.0)
                        .tilt(if (s.navigating) 45.0 else 0.0)
                        .build()
                ),
                900
            )
        }
    }
}
