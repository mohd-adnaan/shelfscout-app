# ShelfScout <img src="src/assets/icons/shelfscout-rbg.png" alt="ShelfScout App Icon" width="60" style="vertical-align: middle; margin-left: 8px; border-radius: 11px;" />

**Status:** Active Development | **Platform:** Cross-Platform (iOS & Android) | **Focus:** Accessibility & Navigation

ShelfScout serves as the mobile companion to the [CyberSight AI Platform](https://github.com/Shared-Reality-Lab/cybersight), delivering computer vision, spatial awareness, and intelligent navigation assistance directly to iOS and Android devices.

---

## Overview

ShelfScout is the native mobile client for the CyberSight accessibility ecosystem, enabling users to:

-  Access real-time object detection and scene analysis on mobile devices
-  Navigate using voice commands and audio feedback
-  Receive spatial awareness and navigation assistance
-  Connect to the CyberSight SLIV backend for advanced AI services

### Relationship to CyberSight Platform

```
┌─────────────────────────────────────────┐
│     CyberSight AI Platform (SLIV)       │
│  ┌────────────┐  ┌──────────────┐       │
│  │ Vision API │  │ Speech (TTS) │       │
│  └────────────┘  └──────────────┘       │
│  ┌────────────┐  ┌──────────────┐       │
│  │  N8N Flow  │  │  PostgreSQL  │       │
│  └────────────┘  └──────────────┘       │
└─────────────────────────────────────────┘
              ↕ REST API / WebSocket
┌─────────────────────────────────────────┐
│      ShelfScout Mobile Client           │
│           (This Repository)             │
│  ┌─────────────────────────────────┐    │
│  │    React Native Application     │    │
│  │  • iOS (Swift native modules)   │    │
│  │  • Android (Kotlin/Java native) │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

## Architecture Comparison

### Web App Flow (Current)
```
User Speech → Speaches API (STT) → Workflow Webhook → n8n Backend → Speaches API (TTS) → User
                     ↓
              Camera Capture
```

### Mobile App Flow (Target)
```
User Speech → Native STT → Workflow Webhook → n8n Backend → Native TTS → User
                  ↓
          Native Camera (Double Tap)
```

### Installation

```bash
# Clone the repository
git clone https://github.com/Shared-Reality-Lab/shelfscout.git
cd shelfscout

# Install JavaScript dependencies
npm install

## Running the App

### Standard Development Cycle

# Terminal 1: Start Metro bundler
npm start

# Terminal 2: Run on iOS
npm run ios

# Terminal 3: Run on Android
npm run android

```
---

## 🐛 Troubleshooting

### iOS Build Failures

**Module map file errors:**
```bash
# Clean DerivedData and rebuild
rm -rf ~/Library/Developer/Xcode/DerivedData
cd ios
rm -rf Pods Podfile.lock build
bundle exec pod install
cd ..
```

**"Unable to find module dependency" errors:**
```bash
# Ensure you're opening .xcworkspace, not .xcodeproj
open ios/shelfscout.xcworkspace
```

### Android Build Failures

**Gradle sync issues:**
```bash
rm -rf ~/.gradle/caches/
or
rm -rf ~/.gradle/caches/
rm -rf ~/.gradle/wrapper/
rm -rf android/.gradle
rm -rf android/app/build
rm -rf android/build

cd android
./gradlew clean
cd ..
npx react-native run-android
```

### General Issues

**App not updating after changes:**
```bash
# Full reset
rm -rf node_modules
npm install
npm start -- --reset-cache
```

## License

This project is developed by the Shared Reality Lab at McGill University, focused on creating accessible AI technologies for users with visual impairments.


**Building accessible technology for everyone.**