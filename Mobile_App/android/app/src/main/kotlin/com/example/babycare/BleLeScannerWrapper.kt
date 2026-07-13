package com.example.babycare

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.util.Locale

/**
 * Wrapper BLE Scanner qui capture directement les résultats BLE Low Energy.
 * Cela contourne la limitation de flutter_blue_plus qui ne livre pas les callbacks
 * depuis un isolate de background service écran éteint.
 *
 * Les résultats sont stockés dans SharedPreferences pour que le Dart les poll.
 */
class BleLeScannerWrapper(private val context: Context) {
    private var bluetoothLeScanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null
    private lateinit var prefs: SharedPreferences
    private var isScanning = false
    private var lastNativePopupAtMs: Long = 0
    private var alarmSilencedUntilMs: Long = 0
    private var lastValidBleCandidateAtMs: Long = 0
    private var nativeAlarmOwnedByBle: Boolean = false
    private var alarmWatchdogRunnable: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val TAG = "BleLeScannerWrapper"
        // SharedPreferences Flutter plugin stores values in this file and prefixes keys with "flutter."
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PREFS_KEY_SCAN_STATE = "flutter.ble_scan_active"
        private const val PREFS_KEY_RESULTS_COUNT = "flutter.ble_results_count"
        private const val EXPECTED_DEVICE_NAME = "ALERT_BABYCARE_ESP32"
        private const val PAYLOAD_PREFIX = "BABYCARE|"
        private const val ALERT_POPUP_COOLDOWN_MS = 12_000L
        private const val ALARM_NO_SIGNAL_TIMEOUT_MS = 1_500L
        private const val ALARM_WATCHDOG_PERIOD_MS = 500L
        private const val NATIVE_ALERT_CHANNEL_ID = "babycare_native_alert_popup_v1"
        private const val NATIVE_ALERT_NOTIFICATION_ID = 12001
        
        private var instance: BleLeScannerWrapper? = null

        fun getInstance(context: Context): BleLeScannerWrapper {
            return instance ?: BleLeScannerWrapper(context).also { instance = it }
        }
    }

    init {
        prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        initializeScanner()
    }

    private fun initializeScanner() {
        try {
            val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val bluetoothAdapter = bluetoothManager?.adapter ?: return
            bluetoothLeScanner = bluetoothAdapter.bluetoothLeScanner
            Log.d(TAG, "BluetoothLeScanner initialized")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize BLE scanner: $e")
        }
    }

    fun startScan(): Boolean {
        if (isScanning) {
            Log.i(TAG, "Scan already active")
            return true
        }

        if (bluetoothLeScanner == null) {
            // Re-try lazy initialization in case adapter state changed since init.
            initializeScanner()
        }

        if (bluetoothLeScanner == null) {
            Log.w(TAG, "Scanner not ready (bluetoothLeScanner is null)")
            return false
        }

        // Vérifier les permissions Android 12+ nécessaires au scan BLE.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.BLUETOOTH_SCAN
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                Log.w(TAG, "BLUETOOTH_SCAN permission not granted")
                return false
            }

            if (ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.BLUETOOTH_CONNECT
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                Log.w(TAG, "BLUETOOTH_CONNECT permission not granted")
                return false
            }
        }

        try {
            val filters = listOf(
                ScanFilter.Builder().setDeviceName("ALERT_BabyCare_ESP32").build(),
            )

            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .setReportDelay(0)
                .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
                .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
                .build()

            scanCallback = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, result: ScanResult) {
                    super.onScanResult(callbackType, result)
                    handleScanResult(result)
                }
            }

            bluetoothLeScanner!!.startScan(filters, settings, scanCallback)
            isScanning = true
            lastValidBleCandidateAtMs = 0
            nativeAlarmOwnedByBle = false
            startAlarmWatchdog()
            prefs.edit().putBoolean(PREFS_KEY_SCAN_STATE, true).apply()
            Log.i(TAG, "BLE LE scan started successfully (LOW_LATENCY, filters=${filters.size})")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start BLE LE scan: $e")
            isScanning = false
            return false
        }
    }

    fun stopScan(): Boolean {
        if (!isScanning || bluetoothLeScanner == null) {
            return false
        }

        return try {
            if (scanCallback != null) {
                bluetoothLeScanner!!.stopScan(scanCallback)
                scanCallback = null
            }
            isScanning = false
            stopAlarmWatchdog()
            lastValidBleCandidateAtMs = 0
            nativeAlarmOwnedByBle = false
            prefs.edit().putBoolean(PREFS_KEY_SCAN_STATE, false).apply()
            Log.i(TAG, "BLE LE scan stopped")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping BLE LE scan: $e")
            false
        }
    }

    private fun handleScanResult(result: ScanResult) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "Scan result ignored: BLUETOOTH_CONNECT not granted")
            return
        }

        val device = result.device
        val advName = result.scanRecord?.deviceName
        val name = try {
            advName ?: device.name ?: "Unknown"
        } catch (e: SecurityException) {
            Log.w(TAG, "Unable to read Bluetooth device name: ${e.message}")
            advName ?: "Unknown"
        }
        val address = device.address ?: "Unknown"
        val rssi = result.rssi
        val vehicleName = extractVehicleNameFromManufacturerData(result)

        val normalizedName = name.trim().uppercase(Locale.US)
        val isExpectedEmitterName = normalizedName == EXPECTED_DEVICE_NAME

        if (!isExpectedEmitterName) {
            Log.d(TAG, "BLE candidate rejected: unexpected emitter name=$name")
            return
        }

        if (vehicleName == null) {
            Log.d(TAG, "BLE candidate rejected: BABYCARE| payload not found ($name)")
            return
        }

        val now = System.currentTimeMillis()
        if (now < alarmSilencedUntilMs) {
            val remaining = alarmSilencedUntilMs - now
            Log.d(TAG, "BLE candidate ignored during silence window (${remaining}ms remaining)")
            return
        }
        lastValidBleCandidateAtMs = now

        val alertMessage =
            "URGENT: A child has been left in $vehicleName!\n" +
                "Return immediately to help your child!"

        Log.d(
            TAG,
            "BLE candidate: name=$name vehicle=$vehicleName address=$address rssi=$rssi",
        )
        showNativeAlertPopupIfNeeded(alertMessage)

        val nativeAlarmStarted = if (NativeAlarmController.isPlaying()) {
            true
        } else {
            NativeAlarmController.start(context)
        }
        if (nativeAlarmStarted) {
            nativeAlarmOwnedByBle = true
            Log.i(TAG, "Native alarm armed from BLE candidate: true")
        } else {
            Log.w(TAG, "Native alarm armed from BLE candidate: false")
        }

        // Stocker dans SharedPreferences pour que Dart la poll
        try {
            val timestamp = System.currentTimeMillis()
            val key = "flutter.ble_result_${timestamp}_${address.replace(":", "")}" 
            val safeEmitterName = name.replace("\"", "\\\"")
            val safeVehicleName = vehicleName.replace("\"", "\\\"")
            val safePayloadHint = ("$PAYLOAD_PREFIX$vehicleName").replace("\"", "\\\"")
            val value = """{"name":"$safeEmitterName","vehicle":"$safeVehicleName","address":"$address","rssi":$rssi,"ts":$timestamp,"payloadHint":"$safePayloadHint"}"""
            prefs.edit().putString(key, value).apply()

            // Incrémenter le compteur de résultats pour que Dart sache qu'il y a du neuf
            val currentCount = getResultsCountCompat()
            val nextCount = (currentCount + 1L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            prefs.edit().putInt(PREFS_KEY_RESULTS_COUNT, nextCount).apply()
        } catch (e: Exception) {
            Log.e(TAG, "Error storing BLE result: $e")
        }
    }

    private fun getResultsCountCompat(): Long {
        val value = prefs.all[PREFS_KEY_RESULTS_COUNT] as? Number
        return value?.toLong() ?: 0L
    }

    private fun showNativeAlertPopupIfNeeded(message: String) {
        val now = System.currentTimeMillis()
        if (now - lastNativePopupAtMs < ALERT_POPUP_COOLDOWN_MS) {
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "Native popup skipped: POST_NOTIFICATIONS not granted")
            return
        }

        try {
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    NATIVE_ALERT_CHANNEL_ID,
                    "BabyCare Alert Popup",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Urgent popup notifications for BabyCare BLE alerts"
                    enableVibration(true)
                    setBypassDnd(true)
                    lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
                }
                manager.createNotificationChannel(channel)
            }

            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntentFlags =
                PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        PendingIntent.FLAG_IMMUTABLE
                    } else {
                        0
                    }
            val pendingIntent = PendingIntent.getActivity(
                context,
                0,
                launchIntent,
                pendingIntentFlags,
            )

            val notification = NotificationCompat.Builder(context, NATIVE_ALERT_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentTitle("BabyCare Alert")
                .setContentText(message)
                .setStyle(NotificationCompat.BigTextStyle().bigText(message))
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setContentIntent(pendingIntent)
                .setFullScreenIntent(pendingIntent, true)
                .build()

            NotificationManagerCompat.from(context)
                .notify(NATIVE_ALERT_NOTIFICATION_ID, notification)
            lastNativePopupAtMs = now
            Log.i(TAG, "Native popup notification displayed from BLE candidate")
        } catch (e: Exception) {
            Log.e(TAG, "Native popup notification failed: $e")
        }
    }

    private fun extractVehicleNameFromManufacturerData(result: ScanResult): String? {
        return try {
            val scanRecord = result.scanRecord ?: return null
            val manufacturerData = scanRecord.manufacturerSpecificData
            for (index in 0 until manufacturerData.size()) {
                val manufacturerId = manufacturerData.keyAt(index)
                val bytes = manufacturerData.valueAt(index) ?: continue
                if (bytes.isEmpty()) {
                    continue
                }

                val directPayload = String(bytes, Charsets.UTF_8).trim()
                val resolvedPayload = if (directPayload.startsWith(PAYLOAD_PREFIX)) {
                    directPayload
                } else {
                    // Android exposes manufacturer id separately and may strip first 2 bytes from data.
                    val idLow = (manufacturerId and 0xFF).toByte()
                    val idHigh = ((manufacturerId shr 8) and 0xFF).toByte()
                    val merged = byteArrayOf(idLow, idHigh) + bytes
                    val reconstructedPayload = String(merged, Charsets.UTF_8).trim()
                    if (reconstructedPayload.startsWith(PAYLOAD_PREFIX)) {
                        reconstructedPayload
                    } else {
                        null
                    }
                }
                if (resolvedPayload == null) continue

                val vehicleName = resolvedPayload.removePrefix(PAYLOAD_PREFIX).trim()
                if (vehicleName.isNotEmpty()) {
                    return vehicleName
                }
            }

            // Fallback: certains devices exposent mal manufacturerSpecificData.
            extractVehicleNameFromRawBytes(scanRecord.bytes)
        } catch (_: Exception) {
            null
        }
    }

    private fun extractVehicleNameFromRawBytes(raw: ByteArray?): String? {
        if (raw == null || raw.isEmpty()) {
            return null
        }

        val prefixBytes = PAYLOAD_PREFIX.toByteArray(Charsets.UTF_8)
        val start = indexOfSubArray(raw, prefixBytes)
        if (start < 0) {
            return null
        }

        val nameStart = start + prefixBytes.size
        if (nameStart >= raw.size) {
            return null
        }

        val out = ArrayList<Byte>()
        for (i in nameStart until raw.size) {
            val b = raw[i].toInt() and 0xFF
            if (b == 0) {
                break
            }
            // Garde uniquement des caracteres imprimables pour eviter le bruit binaire.
            if (b < 32 || b > 126) {
                break
            }
            out.add(raw[i])
        }

        if (out.isEmpty()) {
            return null
        }

        return String(out.toByteArray(), Charsets.UTF_8).trim().ifEmpty { null }
    }

    private fun indexOfSubArray(haystack: ByteArray, needle: ByteArray): Int {
        if (needle.isEmpty() || haystack.size < needle.size) {
            return -1
        }

        for (i in 0..(haystack.size - needle.size)) {
            var found = true
            for (j in needle.indices) {
                if (haystack[i + j] != needle[j]) {
                    found = false
                    break
                }
            }
            if (found) {
                return i
            }
        }
        return -1
    }

    fun getIsScanning(): Boolean = isScanning

    fun silenceAlertsFor(durationMs: Long) {
        alarmSilencedUntilMs = System.currentTimeMillis() + durationMs.coerceAtLeast(0)
        nativeAlarmOwnedByBle = false
        Log.i(TAG, "BLE alert silence window set for ${durationMs}ms")
    }

    private fun startAlarmWatchdog() {
        if (alarmWatchdogRunnable != null) {
            return
        }

        alarmWatchdogRunnable = object : Runnable {
            override fun run() {
                if (!isScanning) {
                    return
                }

                val now = System.currentTimeMillis()
                val lastCandidateAt = lastValidBleCandidateAtMs
                val lostSignal =
                    lastCandidateAt > 0 &&
                        now - lastCandidateAt >= ALARM_NO_SIGNAL_TIMEOUT_MS

                if (lostSignal && nativeAlarmOwnedByBle && NativeAlarmController.isPlaying()) {
                    val stopped = NativeAlarmController.stop()
                    nativeAlarmOwnedByBle = false
                    Log.i(
                        TAG,
                        "Native alarm auto-stop on BLE signal loss: $stopped (timeout=${ALARM_NO_SIGNAL_TIMEOUT_MS}ms)",
                    )
                }

                mainHandler.postDelayed(this, ALARM_WATCHDOG_PERIOD_MS)
            }
        }

        mainHandler.postDelayed(alarmWatchdogRunnable!!, ALARM_WATCHDOG_PERIOD_MS)
    }

    private fun stopAlarmWatchdog() {
        alarmWatchdogRunnable?.let { mainHandler.removeCallbacks(it) }
        alarmWatchdogRunnable = null
    }
}
