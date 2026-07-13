import 'package:flutter/material.dart';

/// APPLICATION DE TEST - ÉMETTEUR BLUETOOTH
/// 
/// Cette application peut être utilisée sur un second appareil pour
/// émettre des signaux Bluetooth que l'application BabyCare peut détecter.
/// 
/// Note: Flutter ne supporte pas directement le mode "advertising" Bluetooth.
/// Pour tester l'application, vous avez besoin:
/// - D'un Arduino/ESP32 avec Bluetooth
/// - D'une app tierce comme "nRF Connect" pour émettre des beacons
/// - D'un second appareil avec cette app qui se connecte et envoie des données

void main() {
  runApp(const TestEmitterApp());
}

class TestEmitterApp extends StatelessWidget {
  const TestEmitterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BabyCare - Test Émetteur',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        useMaterial3: true,
      ),
      home: const EmitterPage(),
    );
  }
}

class EmitterPage extends StatefulWidget {
  const EmitterPage({super.key});

  @override
  State<EmitterPage> createState() => _EmitterPageState();
}

class _EmitterPageState extends State<EmitterPage> {
  final String _status = "Prêt à émettre";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Émetteur de Test'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Icon(Icons.broadcast_on_home, size: 80, color: Colors.orange),
                    SizedBox(height: 16),
                    Text(
                      'Émetteur Bluetooth Test',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            Card(
              color: Colors.orange.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '⚠️ Information Importante',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Flutter ne permet pas facilement d\'émettre des signaux Bluetooth '
                      'en mode "advertising".\n\n'
                      'Pour tester l\'application BabyCare, utilisez plutôt :',
                    ),
                    const SizedBox(height: 16),
                    _buildTestOption(
                      '1. Arduino/ESP32',
                      'Utilisez un microcontrôleur avec le code fourni dans le README',
                    ),
                    const Divider(),
                    _buildTestOption(
                      '2. nRF Connect App',
                      'Installez "nRF Connect" et configurez un beacon avec le code ALERT_2024',
                    ),
                    const Divider(),
                    _buildTestOption(
                      '3. Simulateur intégré',
                      'Utilisez le bouton ci-dessous pour simuler une alerte (mode démo)',
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '📝 Code Arduino/ESP32 :',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '#include <BLEDevice.h>\n'
                      '#include <BLEUtils.h>\n'
                      '#include <BLEServer.h>\n\n'
                      'void setup() {\n'
                      '  BLEDevice::init("ALERT_Device");\n'
                      '  BLEServer *pServer = BLEDevice::createServer();\n'
                      '  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();\n'
                      '  pAdvertising->addServiceUUID("ALERT_2024");\n'
                      '  pAdvertising->start();\n'
                      '}\n\n'
                      'void loop() {\n'
                      '  delay(1000);\n'
                      '}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        backgroundColor: Colors.black12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            const Spacer(),
            
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestOption(String title, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}
