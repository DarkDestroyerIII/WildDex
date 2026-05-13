package com.example.pokedex_animal_app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingLocationResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "wilddex/location"
        ).setMethodCallHandler { call, result ->
            if (call.method == "getRoundedLocation") {
                getLocation(result)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun getLocation(result: MethodChannel.Result) {
        if (!hasLocationPermission()) {
            pendingLocationResult = result
            requestPermissions(
                arrayOf(
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                    Manifest.permission.ACCESS_FINE_LOCATION
                ),
                LOCATION_PERMISSION_REQUEST
            )
            return
        }

        resolveLocation(result)
    }

    private fun hasLocationPermission(): Boolean {
        return checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != LOCATION_PERMISSION_REQUEST) return

        val result = pendingLocationResult ?: return
        pendingLocationResult = null
        if (hasLocationPermission()) {
            resolveLocation(result)
        } else {
            result.success(null)
        }
    }

    private fun resolveLocation(result: MethodChannel.Result) {
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val providers = listOf(
            LocationManager.NETWORK_PROVIDER,
            LocationManager.GPS_PROVIDER
        ).filter { provider ->
            runCatching { manager.isProviderEnabled(provider) }.getOrDefault(false)
        }

        if (providers.isEmpty()) {
            result.success(null)
            return
        }

        val lastKnown = providers
            .mapNotNull { provider ->
                runCatching { manager.getLastKnownLocation(provider) }.getOrNull()
            }
            .maxByOrNull { location -> location.time }

        if (lastKnown != null) {
            result.success(locationMap(lastKnown))
            return
        }

        var completed = false
        val handler = Handler(Looper.getMainLooper())
        lateinit var listener: LocationListener

        fun finish(location: Location?) {
            if (completed) return
            completed = true
            runCatching { manager.removeUpdates(listener) }
            result.success(location?.let { locationMap(it) })
        }

        listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                finish(location)
            }

            override fun onProviderDisabled(provider: String) = Unit
            override fun onProviderEnabled(provider: String) = Unit
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
        }

        runCatching {
            manager.requestSingleUpdate(providers.first(), listener, Looper.getMainLooper())
            handler.postDelayed({ finish(null) }, 8000)
        }.onFailure {
            finish(null)
        }
    }

    private fun locationMap(location: Location): Map<String, Double> {
        return mapOf(
            "latitude" to location.latitude,
            "longitude" to location.longitude,
            "accuracyMeters" to location.accuracy.toDouble()
        )
    }

    companion object {
        private const val LOCATION_PERMISSION_REQUEST = 4071
    }
}
