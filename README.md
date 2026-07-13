# Orchard

Orchard is a native macOS voice assistant powered by [OpenRouter](https://openrouter.ai) with on-device text-to-speech adapted from [SpeakPad](https://github.com/culpen90/SpeakPad).

It is built as a real menu-bar and desktop app, not a browser wrapper.

## What it does

- Opens instantly from anywhere with **Option-Space**.
- Transcribes microphone audio with Apple's Speech framework.
- Streams multi-turn answers from a configurable OpenRouter chat model.
- Reads completed answers aloud with SpeakPad's `AVSpeechSynthesizer` engine.
- Stores the OpenRouter API key only in macOS Keychain.
- Lives in both a full conversation window and the menu bar.
- Can propose a small set of allowlisted Mac actions:
  - open an installed application;
  - open an HTTPS website;
  - search the web;
  - copy text to the clipboard.
- Shows a native confirmation card before actions by default.
- Supports on-device-only recognition when the current language provides it.

Orchard never gives the model access to a shell, AppleScript, arbitrary files, messages, purchases, deletion, or Accessibility automation.

Mac actions require an OpenRouter model that supports tool calling. If a selected model does not, turn off **Let the model propose Mac actions** in Settings.

## Requirements

- macOS 14 or later
- Xcode 26 or another Xcode version with Swift 6 support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An [OpenRouter API key](https://openrouter.ai/settings/keys)

## Build and run

```sh
make run
```

The first build generates `Orchard.xcodeproj`, builds the app, and opens it. You can also open the generated project in Xcode.

To install a release build in `~/Applications`:

```sh
make install
```

Run the unit tests with:

```sh
make test
```

## First use

1. Launch Orchard.
2. Paste an OpenRouter API key into the welcome card or **Orchard > Settings > OpenRouter**.
3. Type a request, or press **Option-Space** and allow Microphone and Speech Recognition access when macOS asks.
4. Speak normally. Orchard sends after a short pause by default.

The default model is `~openai/gpt-latest`, OpenRouter's moving OpenAI flagship alias. Change the slug in Settings, or leave it empty to use the OpenRouter account default.

## Privacy

- Typed prompts and recent conversation context go to OpenRouter and the chosen model provider.
- The API key is stored as a generic password in macOS Keychain. It is not written to `UserDefaults`, source code, or logs.
- Speech output is generated locally on the Mac.
- Speech input uses Apple's Speech framework. Depending on the language and system support, macOS may send audio to Apple. Enable **Require on-device recognition** in Settings to prevent that fallback.
- Orchard is sandboxed and requests only outbound networking and microphone access.

## Architecture

```text
Option-Space / menu bar / conversation window
                     |
               AssistantStore
            /        |         \
 Apple Speech   OpenRouter SSE   SpeakPad TTS
                     |
             allowlisted actions
                     |
              user confirmation
```

The OpenRouter client uses `URLSession` directly and handles SSE keepalives, usage-only chunks, tool-call argument fragments, mid-stream errors, cancellation, and `[DONE]`. No third-party networking or AI SDK is required.

## SpeakPad attribution

The files under `Sources/SpeakPadSpeech` are adapted from SpeakPad commit `f6d97465a96e707ac3c3e168e0097195ec9ea65c`. SpeakPad's MIT license is preserved in [`ThirdParty/SpeakPad/LICENSE`](ThirdParty/SpeakPad/LICENSE).
The built app also includes `Resources/ThirdPartyNotices.txt`, containing the SpeakPad MIT notice and Orchard's PolyForm license URL.

## License

Orchard is distributed under the [PolyForm Noncommercial License 1.0.0](LICENSE).
