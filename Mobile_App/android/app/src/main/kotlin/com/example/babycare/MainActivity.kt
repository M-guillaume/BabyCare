package com.example.babycare

import android.content.Context
import android.content.Intent
import android.os.PowerManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	companion object {
		private const val POWER_CHANNEL = "babycare/power"
		private const val BLE_SCAN_CHANNEL = "babycare/ble_scan"
		private const val ALARM_CHANNEL = "babycare/alarm"
		private const val CONFIG_CHANNEL = "babycare/config"
		private const val WAKELOCK_TAG = "BabyCare:BleMonitoringWakeLock"
		private const val WAKELOCK_TIMEOUT_MS = 8 * 60 * 60 * 1000L
		private var wakeLock: PowerManager.WakeLock? = null
		private var bleScanner: BleLeScannerWrapper? = null
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		// Power management
		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			POWER_CHANNEL,
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"acquirePartialWakeLock" -> {
					result.success(acquirePartialWakeLock())
				}
				"releasePartialWakeLock" -> {
					result.success(releasePartialWakeLock())
				}
				"isPartialWakeLockHeld" -> {
					result.success(wakeLock?.isHeld == true)
				}
				else -> result.notImplemented()
			}
		}

		// BLE native scanning control
		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			BLE_SCAN_CHANNEL,
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"startNativeBLEScan" -> {
					if (bleScanner == null) {
						bleScanner = BleLeScannerWrapper(applicationContext)
					}
					val success = bleScanner?.startScan() ?: false
					result.success(success)
				}
				"stopNativeBLEScan" -> {
					val success = bleScanner?.stopScan() ?: false
					result.success(success)
				}
				"isNativeBLEScanning" -> {
					val scanning = bleScanner?.getIsScanning() ?: false
					result.success(scanning)
				}
				else -> result.notImplemented()
			}
		}

		// Native alarm playback for lock-screen reliability
		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			ALARM_CHANNEL,
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"startNativeAlarm" -> {
					result.success(NativeAlarmController.start(applicationContext))
				}
				"stopNativeAlarm" -> {
					bleScanner = bleScanner ?: BleLeScannerWrapper.getInstance(applicationContext)
					bleScanner?.silenceAlertsFor(5_000)
					result.success(NativeAlarmController.stop())
				}
				"isNativeAlarmPlaying" -> {
					result.success(NativeAlarmController.isPlaying())
				}
				else -> result.notImplemented()
			}
		}

		// Open native vehicle configuration screen from Flutter settings
		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			CONFIG_CHANNEL,
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"openVehicleConfiguration" -> {
					try {
						val intent = Intent(this, VehicleConfigurationActivity::class.java)
						startActivity(intent)
						result.success(true)
					} catch (e: Exception) {
						result.error("OPEN_CONFIG_FAILED", e.message, null)
					}
				}
				else -> result.notImplemented()
			}
		}
	}

	private fun acquirePartialWakeLock(): Boolean {
		val powerManager =
			getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false

		val lock = wakeLock ?: powerManager.newWakeLock(
			PowerManager.PARTIAL_WAKE_LOCK,
			WAKELOCK_TAG,
		).also {
			it.setReferenceCounted(false)
			wakeLock = it
		}

		if (!lock.isHeld) {
			lock.acquire(WAKELOCK_TIMEOUT_MS)
		}

		return lock.isHeld
	}

	private fun releasePartialWakeLock(): Boolean {
		val lock = wakeLock ?: return true
		if (lock.isHeld) {
			lock.release()
		}
		return lock.isHeld.not()
	}
}
