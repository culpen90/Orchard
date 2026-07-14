# Orchard

Orchard is a native macOS voice assistant powered by [OpenRouter](https://openrouter.ai) with on-device text-to-speech adapted from [SpeakPad](https://github.com/culpen90/SpeakPad).

It is built as a real menu-bar and desktop app, not a browser wrapper.

## What it does

- Opens instantly from anywhere with **Option-Space**.
- Transcribes microphone audio with Apple's Speech framework.
- Streams multi-turn answers from a configurable OpenRouter chat model.
- Can research current information through a paired Chrome extension and use the returned titles, snippets, URLs, and visible result-page text in its answer.
- Reads completed answers aloud with SpeakPad's `AVSpeechSynthesizer` engine.
- Stores the OpenRouter API key only in macOS Keychain.
- Lives in both a full conversation window and the menu bar.
- Can propose a small set of allowlisted Mac actions:
  - open an installed application;
  - open an HTTPS website;
  - research the web in the user's visible Chrome browser;
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
- Google Chrome 116 or later for browser research

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

## Connect the Chrome extension

The extension is bundled inside every Orchard build and also lives in [`ChromeExtension`](ChromeExtension) for development.

1. Run Orchard and open **Orchard > Settings > Browser**.
2. Choose **Reveal Extension**.
3. Open `chrome://extensions` in Chrome and enable **Developer mode**.
4. Choose **Load unpacked** and select the revealed `ChromeExtension` folder.
5. Open **Orchard Browser Search**, paste the pairing token shown in Orchard Settings, and choose **Connect**. Allow Chrome's local-network prompt if it appears; the extension connects only to Orchard at `127.0.0.1`.
6. Ask Orchard a current-information question. When Orchard proposes browser research, approve it. Chrome opens a visible Google results tab, and Orchard uses the returned evidence in the model's next response round.

The popup shows whether Chrome is connected. Search tabs remain open so the user can inspect exactly what was read. Consent, CAPTCHA, unexpected, and error pages are reported as failures instead of being passed to the model as results.

## Privacy

- Typed prompts, recent conversation context, and approved browser-search evidence go to OpenRouter and the chosen model provider.
- The API key is stored as a generic password in macOS Keychain. It is not written to `UserDefaults`, source code, or logs.
- Speech output is generated locally on the Mac.
- Speech input uses Apple's Speech framework. Depending on the language and system support, macOS may send audio to Apple. Enable **Require on-device recognition** in Settings to prevent that fallback.
- Orchard is sandboxed. Its browser bridge listens only on `127.0.0.1:38476`, mutually authenticates with a random pairing token kept in Orchard's sandboxed preferences, and accepts only the fixed browser-search protocol. Challenge-response proofs keep the token itself off the socket. The bridge does not expose a general browsing or code-execution API.
- The Chrome extension requests access only to Google search/consent pages, local extension storage, script injection on those pages, and Orchard's loopback bridge. It does not request history, cookies, arbitrary-site access, or the broad `tabs` permission.
- Browser text is length-limited, URL-validated, marked as untrusted, and wrapped with non-editable prompt-injection safety instructions before model synthesis.
- The model receives no action tools while synthesizing an answer from browser evidence. Any later action in that conversation requires confirmation, even if general action confirmations are disabled.
- Within Orchard's conversation context, raw browser evidence is included only in the request that synthesizes the answer; later turns keep the resulting assistant answer, not the hidden search-page transcript. Orchard can search again when a follow-up needs fresh source detail.

## Architecture

```text
Option-Space / menu bar / conversation window
                     |
               AssistantStore
          /          |             \
 Apple Speech   OpenRouter SSE     SpeakPad TTS
                     |
             allowlisted tools
               /           \
      Mac actions       search_web
            |               |
    user confirmation   loopback WebSocket
                            |
                   paired Chrome extension
                            |
                  visible Google results tab
                            |
                 bounded evidence returned
                            |
                  next OpenRouter round
```

The OpenRouter client uses `URLSession` directly and handles SSE keepalives, usage-only chunks, tool-call argument fragments, mid-stream errors, cancellation, and `[DONE]`. The browser bridge uses Apple's Network framework and an authenticated WebSocket. No third-party networking, browser automation, or AI SDK is required.

## SpeakPad attribution

The files under `Sources/SpeakPadSpeech` are adapted from SpeakPad v0.2.0 at commit `4759c090eac120947fd785d32c60aeb41a6bbcde`. SpeakPad's MIT license is preserved in [`ThirdParty/SpeakPad/LICENSE`](ThirdParty/SpeakPad/LICENSE).
The built app also includes `Resources/ThirdPartyNotices.txt`, containing the SpeakPad MIT notice and Orchard's PolyForm license URL.

## License

Orchard is distributed under the [PolyForm Noncommercial License 1.0.0](LICENSE).
