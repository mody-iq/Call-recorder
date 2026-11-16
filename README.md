# CallRecorder (RootHide / iOS 15.0 – 18.7 / arm64e)

Full-stack iOS Call Recorder tweak engineered for the **Relaxin RootHide** jailbreak environment on **iOS 18.7** (`arm64e` / PAC, e.g., iPhone XS Max).

## Features
- **RootHide Native (`jbroot`)**: Dynamically resolves all jailbreak storage paths via `<roothide.h>` and `jbroot(@"/var/mobile/Library/CallRecordings")`.
- **Real-Time Safe WAV Engine (`AudioRecorderEngine`)**: Lock-free state checks on the real-time `AudioUnitRender` thread with asynchronous PCM conversion and 44-byte RIFF/WAVE header writing on a dedicated serial I/O queue (`com.callrecorder.ioqueue`).
- **Draggable Floating Call Overlay (`InCallServiceUI`)**: Sleek floating pill control with pulsing red indicator, live `00:00` timer, Darwin notification IPC (`com.relaxin.callrecorder/start` & `stop`), and automatic stop on call disconnect (`TUCallCenterCallStatusChangedNotification`).
- **Settings Recordings Manager (`CallRecorderPrefs`)**: Native iOS Settings preference bundle to browse recordings sorted by date, play/stop via `AVAudioPlayer`, swipe-to-delete, and share/export `.wav` files via `UIActivityViewController` (WhatsApp, Telegram, Files, AirDrop).
- **Automated RootHide CI/CD**: GitHub Actions `macos-latest` pipeline compiling `iphoneos-arm64e` RootHide `.deb` artifacts automatically.
