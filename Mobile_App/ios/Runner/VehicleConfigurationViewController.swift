import UIKit
import CoreBluetooth

class VehicleConfigurationViewController: UIViewController, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    // MARK: - Constants
    private static let TARGET_DEVICE_NAME = "BabyCare_ESP32"
    private static let MAX_NAME_LEN = 15
    private static let PAYLOAD_PREFIX = "BABYCARE|"
    private static let SCAN_TIMEOUT_MS = 12.0
    
    private static let SERVICE_UUID = CBUUID(string: "4fafc201-1fb5-459e-8fcc-c5c9c331914b")
    private static let WRITE_CHAR_UUID = CBUUID(string: "beb5483e-36e1-4688-b7f5-ea07361b26a8")
    
    // MARK: - UI Elements
    private let scrollView = UIScrollView()
    private let containerView = UIView()
    private let titleLabel = UILabel()
    private let infoLabel = UILabel()
    private let vehicleNameTextField = UITextField()
    private let counterLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    
    // MARK: - BLE Properties
    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var scanning = false
    private var pendingVehicleNameAck: String?
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScan()
        closePeripheral()
    }
    
    // MARK: - UI Setup
    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.027, green: 0.165, blue: 0.227, alpha: 1.0) // #072A3A
        
        // Gradient background
        let gradientLayer = CAGradientLayer()
        gradientLayer.colors = [
            UIColor(red: 0.027, green: 0.165, blue: 0.227, alpha: 1.0).cgColor, // #072A3A
            UIColor(red: 0.043, green: 0.561, blue: 0.475, alpha: 1.0).cgColor,  // #0B8F7A
            UIColor(red: 0.965, green: 0.718, blue: 0.235, alpha: 1.0).cgColor   // #F6B73C
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        gradientLayer.frame = view.bounds
        view.layer.insertSublayer(gradientLayer, at: 0)
        
        // ScrollView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        // Container
        containerView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
            containerView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16),
            containerView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            containerView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            containerView.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -32)
        ])
        
        // Panel background
        let panelView = UIView()
        panelView.backgroundColor = UIColor(white: 1.0, alpha: 0.2)
        panelView.layer.cornerRadius = 24
        panelView.layer.borderWidth = 1
        panelView.layer.borderColor = UIColor(white: 1.0, alpha: 0.22).cgColor
        panelView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(panelView)
        NSLayoutConstraint.activate([
            panelView.topAnchor.constraint(equalTo: containerView.topAnchor),
            panelView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            panelView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])
        
        // Title Label
        titleLabel.text = "Vehicle Configuration"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.boldSystemFont(ofSize: 22)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -18)
        ])
        
        // Info Label
        infoLabel.text = "Maximum vehicle name length: 15 characters"
        infoLabel.textColor = UIColor(white: 1.0, alpha: 0.85)
        infoLabel.font = UIFont.systemFont(ofSize: 14)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(infoLabel)
        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            infoLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 18),
            infoLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -18)
        ])
        
        // Vehicle Name TextField
        vehicleNameTextField.placeholder = "Example: Blue Clio Dad"
        vehicleNameTextField.textColor = UIColor.black
        vehicleNameTextField.backgroundColor = .white
        vehicleNameTextField.borderStyle = .roundedRect
        vehicleNameTextField.font = UIFont.systemFont(ofSize: 16)
        vehicleNameTextField.autocapitalizationType = .words
        vehicleNameTextField.delegate = self
        vehicleNameTextField.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(vehicleNameTextField)
        NSLayoutConstraint.activate([
            vehicleNameTextField.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 14),
            vehicleNameTextField.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 18),
            vehicleNameTextField.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -18),
            vehicleNameTextField.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        // Counter Label
        counterLabel.text = "0/15"
        counterLabel.textColor = UIColor(white: 0.2, alpha: 1.0)
        counterLabel.font = UIFont.systemFont(ofSize: 14)
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(counterLabel)
        NSLayoutConstraint.activate([
            counterLabel.topAnchor.constraint(equalTo: vehicleNameTextField.bottomAnchor, constant: 6),
            counterLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 18)
        ])
        
        // Save Button
        if #available(iOS 15.0, *) {
            var buttonConfig = UIButton.Configuration.filled()
            buttonConfig.title = "Save to ESP32"
            buttonConfig.baseBackgroundColor = UIColor(red: 0.034, green: 0.306, blue: 0.345, alpha: 1.0) // #094E58
            buttonConfig.baseForegroundColor = .white
            saveButton.configuration = buttonConfig
        } else {
            saveButton.setTitle("Save to ESP32", for: .normal)
            saveButton.setTitleColor(.white, for: .normal)
            saveButton.backgroundColor = UIColor(red: 0.034, green: 0.306, blue: 0.345, alpha: 1.0)
            saveButton.layer.cornerRadius = 10
        }
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.addTarget(self, action: #selector(onSavePressed), for: .touchUpInside)
        panelView.addSubview(saveButton)
        NSLayoutConstraint.activate([
            saveButton.topAnchor.constraint(equalTo: counterLabel.bottomAnchor, constant: 16),
            saveButton.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 18),
            saveButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -18),
            saveButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        // Status Label
        statusLabel.text = "Ready"
        statusLabel.textColor = UIColor.black
        statusLabel.font = UIFont.boldSystemFont(ofSize: 14)
        statusLabel.textAlignment = .left
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: saveButton.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -18),
            statusLabel.bottomAnchor.constraint(lessThanOrEqualTo: panelView.bottomAnchor, constant: -18)
        ])
        
        // Navigation
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closePressed))
    }
    
    // MARK: - Actions
    @objc private func closePressed() {
        dismiss(animated: true)
    }
    
    @objc private func onSavePressed() {
        let vehicleName = vehicleNameTextField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let validationError = validateVehicleName(vehicleName) else {
            ensurePermissionsAndStart(with: vehicleName)
            return
        }
        showStatus(validationError)
    }
    
    private func validateVehicleName(_ name: String) -> String? {
        if name.isEmpty {
            return "Please enter a vehicle name"
        }
        if name.count > Self.MAX_NAME_LEN {
            return "Vehicle name is too long (max \(Self.MAX_NAME_LEN) characters)"
        }
        if name.contains("|") {
            return "Vehicle name cannot contain '|' character"
        }
        return nil
    }
    
    // MARK: - Permissions
    private func ensurePermissionsAndStart(with vehicleName: String) {
        if #available(iOS 13.1, *) {
            if CBCentralManager.authorization == .denied || CBCentralManager.authorization == .restricted {
                showStatus("Bluetooth permissions denied")
                return
            }
        }
        startConfigFlow(with: vehicleName)
    }
    
    private func startConfigFlow(with vehicleName: String) {
        guard let centralManager = centralManager, centralManager.state == .poweredOn else {
            showStatus("Bluetooth is disabled")
            return
        }
        startScan(targetName: vehicleName)
    }
    
    // MARK: - BLE Scan & Connect
    private func startScan(targetName: String) {
        guard !scanning else { return }
        scanning = true
        showStatus("Scanning for BLE device...")
        
        centralManager?.scanForPeripherals(withServices: nil, options: nil)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.SCAN_TIMEOUT_MS) { [weak self] in
            guard let self = self, self.scanning else { return }
            self.stopScan()
            self.showStatus("ESP32 not found (timeout)")
        }
    }
    
    private func stopScan() {
        scanning = false
        centralManager?.stopScan()
    }
    
    // MARK: - Peripheral Connection
    private func connectGatt(_ peripheral: CBPeripheral) {
        stopScan()
        showStatus("ESP32 found, connecting...")
        self.peripheral = peripheral
        peripheral.delegate = self
        centralManager?.connect(peripheral, options: nil)
    }
    
    private func closePeripheral() {
        if let peripheral = peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        writeCharacteristic = nil
    }
    
    private func writeVehicleName(_ name: String) {
        guard let peripheral = peripheral, let characteristic = writeCharacteristic else {
            showStatus("Not connected to ESP32")
            return
        }
        
        pendingVehicleNameAck = name
        let payload = "\(Self.PAYLOAD_PREFIX)\(name)"
        
        if let data = payload.data(using: .utf8) {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            showStatus("Sending vehicle name...")
        }
    }
    
    private func showStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = message
        }
    }
    
    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            showStatus("Ready")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name == Self.TARGET_DEVICE_NAME {
            connectGatt(peripheral)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        showStatus("Connected, discovering services...")
        peripheral.discoverServices([Self.SERVICE_UUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        showStatus("Connection failed: \(error?.localizedDescription ?? "unknown error")")
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral == self.peripheral {
            self.peripheral = nil
            writeCharacteristic = nil
            showStatus("Disconnected")
        }
    }
    
    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            showStatus("Service discovery failed: \(error!.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == Self.SERVICE_UUID {
                peripheral.discoverCharacteristics([Self.WRITE_CHAR_UUID], for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            showStatus("Characteristic discovery failed: \(error!.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == Self.WRITE_CHAR_UUID {
                writeCharacteristic = characteristic
                showStatus("ESP32 ready for configuration")
                
                if let name = vehicleNameTextField.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    writeVehicleName(name)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            showStatus("Write failed: \(error.localizedDescription)")
        } else {
            showStatus("Vehicle name saved to ESP32!")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.dismiss(animated: true)
            }
        }
    }
}

// MARK: - UITextFieldDelegate
extension VehicleConfigurationViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let newText = (textField.text ?? "") as NSString
        let fullText = newText.replacingCharacters(in: range, with: string)
        
        if fullText.count > Self.MAX_NAME_LEN {
            textField.text = String(fullText.prefix(Self.MAX_NAME_LEN))
            counterLabel.text = "\(Self.MAX_NAME_LEN)/\(Self.MAX_NAME_LEN)"
            return false
        }
        
        counterLabel.text = "\(fullText.count)/\(Self.MAX_NAME_LEN)"
        return true
    }
}
