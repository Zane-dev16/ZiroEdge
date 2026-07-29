# Privacy Policy — ZiroEdge

**Effective Date:** 2026

## Our Privacy Commitment

ZiroEdge processes all AI inference entirely on your device. We do not collect, store, or transmit any personal data, conversation content, or usage analytics to any server.

## Data Collection

**ZiroEdge collects no data.** There is:

- No account creation or sign-in
- No analytics or crash reporting SDKs
- No advertising or tracking frameworks
- No server-side processing of any kind
- No transmission of user content off-device

The only network requests ZiroEdge ever makes are:

1. **Model downloads**: When you choose to download a model, the app fetches the model file (.gguf) from HuggingFace CDN. These are anonymous HTTPS requests with no user identifiers attached.
2. **Privacy policy access**: Tapping "Privacy Policy" in Settings fetches this page.

## Data Stored on Your Device

- **Conversations**: Stored in a local Core Data (SQLite) database within the app sandbox. Accessible only to ZiroEdge.
- **Model files**: Downloaded GGUF model files stored in the app's Documents/Models directory.
- **Preferences**: Your chosen default system prompt and selected model are stored in UserDefaults.

All of this data stays on your device and is removed when you delete the app.

## Third-Party Code

ZiroEdge bundles llama.cpp (MIT License), an open-source inference engine. No third-party SDKs with data collection capabilities are included.

## Children's Privacy

ZiroEdge does not collect any personal information from anyone, including children under 13.

## Changes to This Policy

If this policy changes, the updated version will be available at this URL. The app will not track or notify you of changes — we recommend checking this page periodically.

## Contact

For privacy questions, open an issue at:
[https://github.com/Zane-dev16/ZiroEdge/issues](https://github.com/Zane-dev16/ZiroEdge/issues)

---

*ZiroEdge — Private AI, on your device, always.*
