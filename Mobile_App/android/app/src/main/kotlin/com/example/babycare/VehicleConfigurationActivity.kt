package com.example.babycare

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.TextWatcher
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import java.nio.charset.StandardCharsets
import java.util.UUID

class VehicleConfigurationActivity : ComponentActivity() {

    companion object {
        private const val TARGET_DEVICE_NAME = "BabyCare_ESP32"
        private const val MAX_NAME_LEN = 15
        private const val PAYLOAD_PREFIX = "BABYCARE|"
        private const val SCAN_TIMEOUT_MS = 12000L

        private val SERVICE_UUID: UUID = UUID.fromString("4fafc201-1fb5-459e-8fcc-c5c9c331914b")
        private val WRITE_CHAR_UUID: UUID = UUID.fromString("beb5483e-36e1-4688-b7f5-ea07361b26a8")
    }

    private lateinit var etVehicleName: EditText
    private lateinit var tvCounter: TextView
    private lateinit var tvStatus: TextView
    private lateinit var btnSave: Button

    private var bluetoothGatt: BluetoothGatt? = null
    private var pendingVehicleNameAck: String? = null
    private var scanning = false

    private val mainHandler = Handler(Looper.getMainLooper())

    private val bluetoothAdapter: BluetoothAdapter? by lazy {
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        manager.adapter
    }

    private val scanner
        get() = bluetoothAdapter?.bluetoothLeScanner

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            val granted = result.values.all { it }
            if (!granted) {
                showStatus("BLE permissions denied")
                return@registerForActivityResult
            }
            startConfigFlow()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_vehicle_configuration)

        etVehicleName = findViewById(R.id.etVehicleName)
        tvCounter = findViewById(R.id.tvCounter)
        tvStatus = findViewById(R.id.tvStatus)
        btnSave = findViewById(R.id.btnSaveVehicleName)

        etVehicleName.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}

            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                val value = s?.toString().orEmpty()
                if (value.length > MAX_NAME_LEN) {
                    etVehicleName.setText(value.substring(0, MAX_NAME_LEN))
                    etVehicleName.setSelection(MAX_NAME_LEN)
                    tvCounter.text = "$MAX_NAME_LEN/$MAX_NAME_LEN"
                } else {
                    tvCounter.text = "${value.length}/$MAX_NAME_LEN"
                }
            }

            override fun afterTextChanged(s: Editable?) {}
        })

        btnSave.setOnClickListener {
            val vehicleName = etVehicleName.text.toString().trim()
            val validationError = validateVehicleName(vehicleName)
            if (validationError != null) {
                toast(validationError)
                return@setOnClickListener
            }

            ensurePermissionsAndStart()
        }
    }

    private fun ensurePermissionsAndStart() {
        val needed = mutableListOf<String>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!hasPermission(Manifest.permission.BLUETOOTH_SCAN)) {
                needed += Manifest.permission.BLUETOOTH_SCAN
            }
            if (!hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) {
                needed += Manifest.permission.BLUETOOTH_CONNECT
            }
        } else {
            if (!hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)) {
                needed += Manifest.permission.ACCESS_FINE_LOCATION
            }
        }

        if (needed.isNotEmpty()) {
            permissionLauncher.launch(needed.toTypedArray())
        } else {
            startConfigFlow()
        }
    }

    private fun startConfigFlow() {
        if (bluetoothAdapter?.isEnabled != true) {
            showStatus("Bluetooth is disabled")
            return
        }
        startScan()
    }

    private fun startScan() {
        if (scanning) {
            return
        }

        val localScanner = scanner
        if (localScanner == null) {
            showStatus("BLE scanner unavailable")
            return
        }

        scanning = true
        showStatus("Scanning for BLE device...")

        val filters = listOf(ScanFilter.Builder().setDeviceName(TARGET_DEVICE_NAME).build())
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        localScanner.startScan(filters, settings, scanCallback)

        mainHandler.postDelayed({
            if (scanning) {
                stopScan()
                showStatus("ESP32 not found (timeout)")
            }
        }, SCAN_TIMEOUT_MS)
    }

    private fun stopScan() {
        if (!scanning) {
            return
        }

        scanning = false
        try {
            scanner?.stopScan(scanCallback)
        } catch (_: Exception) {
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val deviceName = result.device.name ?: result.scanRecord?.deviceName
            if (deviceName != TARGET_DEVICE_NAME) {
                return
            }

            stopScan()
            showStatus("ESP32 found, connecting...")
            connectGatt(result.device)
        }
    }

    private fun connectGatt(device: BluetoothDevice) {
        closeGatt()
        bluetoothGatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(this, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            @Suppress("DEPRECATION")
            device.connectGatt(this, false, gattCallback)
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            runOnUiThread {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    showStatus("GATT connection failed (status=$status)")
                    closeGatt()
                    return@runOnUiThread
                }

                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    showStatus("Connected, discovering services...")
                    gatt.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    showStatus("Disconnected")
                    closeGatt()
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            runOnUiThread {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    showStatus("Service discovery failed")
                    closeGatt()
                    return@runOnUiThread
                }

                val service: BluetoothGattService? = gatt.getService(SERVICE_UUID)
                val writeCharacteristic: BluetoothGattCharacteristic? =
                    service?.getCharacteristic(WRITE_CHAR_UUID)

                if (service == null || writeCharacteristic == null) {
                    showStatus("Service/characteristic not found")
                    closeGatt()
                    return@runOnUiThread
                }

                // Garde-fou: seule la characteristic UUID attendue doit etre writable.
                val writableCharacteristics = service.characteristics.filter { characteristic ->
                    val props = characteristic.properties
                    (props and BluetoothGattCharacteristic.PROPERTY_WRITE) != 0 ||
                        (props and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
                }
                if (writableCharacteristics.size != 1 ||
                    writableCharacteristics.first().uuid != WRITE_CHAR_UUID
                ) {
                    showStatus("Invalid BLE setup: unexpected writable UUID")
                    closeGatt()
                    return@runOnUiThread
                }

                val properties = writeCharacteristic.properties
                val isWritable =
                    (properties and BluetoothGattCharacteristic.PROPERTY_WRITE) != 0 ||
                        (properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
                if (!isWritable) {
                    showStatus("Characteristic is not writable")
                    closeGatt()
                    return@runOnUiThread
                }

                val value = etVehicleName.text.toString().trim()
                val validationError = validateVehicleName(value)
                if (validationError != null) {
                    showStatus(validationError)
                    closeGatt()
                    return@runOnUiThread
                }

                pendingVehicleNameAck = value
                writeVehicleName(gatt, writeCharacteristic, value)
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            runOnUiThread {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    val readStarted = gatt.readCharacteristic(characteristic)
                    if (!readStarted) {
                        showStatus("Write OK but ACK read failed")
                        closeGatt()
                    } else {
                        showStatus("Write OK, verifying ACK...")
                    }
                } else {
                    showStatus("Write failed (status=$status)")
                    closeGatt()
                }
            }
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            runOnUiThread {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    showStatus("ACK read failed (status=$status)")
                    closeGatt()
                    return@runOnUiThread
                }

                val readValue = String(characteristic.value ?: byteArrayOf(), StandardCharsets.UTF_8).trim()
                val expectedName = pendingVehicleNameAck
                val expectedAck = if (expectedName != null) "ACK|$expectedName" else null

                if (expectedAck != null && readValue == expectedAck) {
                    showStatus("Vehicle name saved on ESP32 (ACK confirmed)")
                    toast("Configuration sent")
                } else {
                    showStatus("Unexpected ACK: $readValue")
                }
                closeGatt()
            }
        }
    }

    private fun validateVehicleName(value: String): String? {
        if (value.isEmpty()) {
            return "Vehicle name cannot be empty"
        }
        if (value.length > MAX_NAME_LEN) {
            return "Maximum $MAX_NAME_LEN characters"
        }
        if (value.contains("|")) {
            return "Character | is not allowed"
        }
        if (value.uppercase().startsWith(PAYLOAD_PREFIX)) {
            return "Do not include the BABYCARE| prefix"
        }
        return null
    }

    private fun writeVehicleName(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: String,
    ) {
        val payload = value.toByteArray(StandardCharsets.UTF_8)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val writeStatus = gatt.writeCharacteristic(
                characteristic,
                payload,
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
            )
            if (writeStatus != BluetoothStatusCodes.SUCCESS) {
                showStatus("Unable to send write request")
                closeGatt()
            } else {
                showStatus("Writing...")
            }
            return
        }

        @Suppress("DEPRECATION")
        characteristic.value = payload
        @Suppress("DEPRECATION")
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        @Suppress("DEPRECATION")
        val ok = gatt.writeCharacteristic(characteristic)
        if (!ok) {
            showStatus("Unable to send write request")
            closeGatt()
        } else {
            showStatus("Writing...")
        }
    }

    private fun hasPermission(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun showStatus(value: String) {
        tvStatus.text = value
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun closeGatt() {
        try {
            bluetoothGatt?.close()
        } catch (_: Exception) {
        }
        bluetoothGatt = null
        pendingVehicleNameAck = null
    }

    override fun onStop() {
        super.onStop()
        stopScan()
    }

    override fun onDestroy() {
        super.onDestroy()
        stopScan()
        closeGatt()
    }
}
