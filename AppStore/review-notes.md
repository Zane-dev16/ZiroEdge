# App Store Review Notes — ZiroEdge 1.0.0

## How ZiroEdge Works

ZiroEdge performs **all AI inference locally on the device** using llama.cpp, an open-source C++ inference engine. No data is transmitted to any server for model processing. The app ships with no hardcoded models — users choose which models to download from a catalog, and those models are stored and run entirely on device.

## Key Points for Reviewers

### 1. Local Inference Only

- **No cloud AI processing.** The app uses llama.cpp (MIT-licensed, bundled as an xcframework) to run models directly on the device CPU. The model files (.gguf format) are downloaded on-demand from HuggingFace CDN and stored in the app's sandboxed Documents/Models directory.
- **No internet required for chat.** Once a model is downloaded, all chat functionality works fully offline. Put the device in airplane mode to verify this.
- **Vision models run locally too.** When a user selects a photo, the image is processed on-device through the same llama.cpp pipeline — pixels never leave the device.

### 2. No Account Required

- There is no sign-up, sign-in, or account creation flow anywhere in the app.
- No user identifiers are generated, stored, or transmitted.
- The app has no concept of a "user account."

### 3. No In-App Purchases or Subscriptions

- All features are available without payment.
- There is no StoreKit integration, no IAP catalog, and no subscription management.
- The app's model catalog is free and open — users download models directly from public HuggingFace repositories.

### 4. No Data Collection

- No analytics, no crash reporting SDKs, no tracking frameworks. The app performs no data collection of any kind.
- Conversations are stored exclusively in a local Core Data database (SQLite) inside the app sandbox.
- The app declares `NSPrivacyTracking: false` and `NSPrivacyCollectedDataTypes: []` in its PrivacyInfo.xcprivacy manifest.
- The only network requests are: (a) downloading model files from HuggingFace CDN when the user explicitly chooses to download a model, and (b) resolving the privacy policy URL from Settings if the user taps it.

### 5. How to Test the App

1. **First launch:** The app shows an onboarding screen and a welcome view. Tap "Browse Models" to open the model catalog.
2. **Download a model:** Choose "Gemma 4 E2B Text" (the smallest, ~3.4 GB) or any other model. The download progresses with a progress bar.
3. **Start a conversation:** Once downloaded, tap "New Conversation." The model loads into memory (this may take a few seconds on first load).
4. **Chat:** Type a message and tap send. The model streams its response token by token with markdown rendering.
5. **Test offline:** Enable airplane mode after the model is loaded. Chat continues to work.
6. **Vision (if testing Gemma vision models):** Tap the camera/photo button in the chat bar, select an image, and ask a question about it.

### 6. Required Device Capabilities

- iOS 18.0 or later
- At least 4 GB RAM recommended for the smallest model (Gemma 4 E2B Text ~3.4 GB download, ~3.7 GB loaded)
- Sufficient free storage for model downloads (models range from ~1.6 GB to ~54 GB)

### 7. Known Limitations (Not Blockers)

- **Model download size**: Larger models (e.g., Gemma 4 E4B at ~8 GB) may exceed cellular download limits. The app recommends Wi-Fi but does not enforce it — this is intentional to respect user choice.
- **Memory management**: Under extreme memory pressure, iOS may terminate the app. This is expected behavior — the app restores state on relaunch.
- **First-load time**: The first model load after download takes 4–10 seconds depending on model size, as the engine performs a one-time initialization.

---

## App Store Connect Configuration Reference

- **Bundle ID:** com.zanish-labs.ziroedge
- **SKU:** ziroedge-ios
- **Primary Category:** Productivity
- **Secondary Category:** Utilities
- **Privacy Policy URL:** <https://zane-dev16.github.io/ZiroEdge/privacy.html>
- **Support URL:** <https://github.com/Zane-dev16/ZiroEdge/issues>
- **Marketing URL:** <https://ziroedge.app>
- **Content Rights:** Contains no third-party copyrighted content beyond properly licensed open-source software (MIT License, Gemma Terms, Llama 3.2 Community License).

---

*Generated for App Store submission. This document explains the technical architecture for App Review. It is not user-facing.*
