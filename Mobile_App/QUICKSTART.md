# Guide de Démarrage Rapide - BabyCare Alert System

## 🚀 Installation et Premier Lancement

### 1. Installation des dépendances

Ouvrez un terminal dans le dossier du projet et exécutez :

```bash
flutter pub get
```

### 2. Vérification de votre environnement

```bash
flutter doctor
```

Assurez-vous que :
- ✅ Flutter est installé
- ✅ Android Studio / Xcode est configuré
- ✅ Au moins un appareil est connecté ou un émulateur est disponible

### 3. Ajout du fichier audio (Important!)

L'application nécessite un fichier audio pour l'alarme :

1. Créez le dossier `assets` s'il n'existe pas déjà
2. Téléchargez un son d'alarme MP3 (suggestions dans `assets/README.md`)
3. Nommez-le `alarm.mp3` et placez-le dans `assets/alarm.mp3`

**Sans ce fichier, l'alarme n'émettra que des vibrations!**

### 4. Lancement de l'application

#### Sur Android :
```bash
flutter run --release
# ou en mode debug
flutter run
```

#### Sur iOS :
```bash
cd ios
pod install
cd ..
flutter run --release
```

## 📱 Test de l'Application

### Option 1 : Avec un Arduino/ESP32

1. **Téléversez le code suivant sur votre ESP32:**

```cpp
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>

void setup() {
  Serial.begin(115200);
  Serial.println("Démarrage du beacon BabyCare...");
  
  BLEDevice::init("ALERT_BabyCare");
  BLEServer *pServer = BLEDevice::createServer();
  
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  
  // Crée les données de broadcast
  BLEAdvertisementData advertisementData;
  advertisementData.setName("ALERT_BabyCare");
  advertisementData.setManufacturerData("ALERT_2024");
  
  pAdvertising->setAdvertisementData(advertisementData);
  pAdvertising->start();
  
  Serial.println("Beacon actif!");
}

void loop() {
  delay(1000);
}
```

2. **Alimentez l'ESP32**
3. **Lancez l'application BabyCare sur votre téléphone**
4. **Appuyez sur "Démarrer la surveillance"**
5. **L'alarme devrait se déclencher automatiquement!**

### Option 2 : Avec l'application nRF Connect

1. **Téléchargez "nRF Connect for Mobile"** (gratuit sur Play Store/App Store)
2. **Ouvrez nRF Connect** et allez dans l'onglet "Advertiser"
3. **Créez un nouveau profil d'advertising:**
   - Name: `ALERT_BabyCare`
   - Dans "Add Record" → "Complete Local Name" → `ALERT_2024`
4. **Activez l'advertising**
5. **Lancez BabyCare et démarrez la surveillance**
6. **L'alarme se déclenche quand les appareils se détectent**

### Option 3 : Simulation avec 2 téléphones

Vous pouvez utiliser 2 téléphones avec l'app pour tester la connectivité Bluetooth :

1. **Tel 1** : Lance BabyCare en mode surveillance
2. **Tel 2** : Utilise une app Bluetooth pour émettre un signal avec "ALERT" dans le nom
3. Les deux appareils doivent être à moins de 600m l'un de l'autre

## 🔧 Résolution de Problèmes Courants

### ❌ Erreur "Bluetooth non supporté"
**Solution** : Utilisez un appareil physique, pas un émulateur

### ❌ "Permission denied" au lancement
**Solution** : 
1. Ouvrez les paramètres de l'app
2. Accordez toutes les permissions (Bluetooth, Localisation, Notifications)
3. Relancez l'app

### ❌ Pas de son d'alarme
**Solution** :
1. Vérifiez que `assets/alarm.mp3` existe
2. Relancez `flutter pub get`
3. Recompilez l'app
4. Vérifiez le volume de votre téléphone

### ❌ L'app ne détecte aucun signal
**Solution** :
1. Activez le Bluetooth sur votre téléphone
2. Activez la localisation (obligatoire sur Android)
3. Assurez-vous que l'émetteur est allumé et à proximité (< 100m pour tester)
4. Redémarrez l'app

### ❌ Erreur de compilation Android
**Solution** :
```bash
cd android
./gradlew clean
cd ..
flutter clean
flutter pub get
flutter run
```

## 📊 Vérification du Fonctionnement

Quand l'app fonctionne correctement, vous devriez voir :

1. **Au lancement** :
   - Demandes de permissions (acceptez toutes)
   - Interface avec le statut "Inactif"

2. **Après "Démarrer la surveillance"** :
   - Statut passe à "Surveillance active 🟢"
   - Icône Bluetooth animée

3. **Quand un signal est détecté** :
   - Notification push immédiate
   - Alarme sonore qui se déclenche
   - Vibration continue
   - Texte "🚨 ALARME ACTIVE 🚨" en rouge
   - Bouton "ARRÊTER L'ALARME" apparaît

4. **Après arrêt de l'alarme** :
   - Son et vibration s'arrêtent
   - Notification persistante disparaît
   - Surveillance continue (si toujours active)

## 🎓 Pour votre Présentation Scolaire

### Points clés à mentionner :

1. **Multi-plateforme** : Un seul code pour Android et iOS
2. **Sécurité** : Validation du signal avec code
3. **Portée** : Bluetooth LE peut atteindre jusqu'à 600m (selon conditions)
4. **Temps réel** : Détection quasi-instantanée (< 1 seconde)
5. **Fiabilité** : Fonctionne en arrière-plan

### Démonstration suggérée :

1. Montrez l'interface de l'app
2. Expliquez le système de permissions
3. Démarrez la surveillance
4. Déclenchez l'alarme avec votre émetteur
5. Montrez la notification et l'alarme
6. Arrêtez l'alarme

### Améliorations possibles à discuter :

- Connexion à un serveur cloud
- Historique persistant des alertes
- Géolocalisation des alertes
- Réglage du volume d'alarme
- Mode "ne pas déranger" avec horaires
- Envoi de SMS d'urgence

## 📞 Support

Si vous rencontrez des problèmes :

1. Vérifiez les logs : `flutter logs`
2. Inspectez les erreurs dans la console
3. Testez sur différents appareils
4. Consultez le README.md principal

## 🎯 Checklist avant présentation

- [ ] L'app compile sans erreur
- [ ] Toutes les permissions sont accordées
- [ ] Le fichier alarm.mp3 est présent
- [ ] Vous avez un émetteur Bluetooth fonctionnel
- [ ] Vous avez testé le cycle complet (surveillance → détection → alarme → arrêt)
- [ ] Le téléphone n'est pas en mode silencieux
- [ ] La batterie est chargée (le Bluetooth consomme!)

Bon courage pour votre projet! 🚀
