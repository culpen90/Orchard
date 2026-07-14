# Orchard

Orchard is a native macOS voice assistant powered by [OpenRouter](https://openrouter.ai), with on-device text-to-speech adapted from [SpeakPad](https://github.com/culpen90/SpeakPad).

It is a real menu-bar and desktop app, not a browser wrapper. A paired Chrome extension gives its LLM a deliberately bounded way to inspect and operate the browser.

## What it does

- Opens instantly from anywhere with **Option-Space**.
- Transcribes microphone audio with Apple's Speech framework.
- Streams multi-turn answers from a configurable OpenRouter chat model.
- Reads completed answers aloud with SpeakPad's `AVSpeechSynthesizer` engine.
- Stores the OpenRouter API key only in macOS Keychain.
- Lives in both a full conversation window and the menu bar.
- Can propose allowlisted Mac actions to open an app, open an HTTPS URL, or copy text.
- Can use a paired Chrome extension to:
  - list, activate, and close tabs;
  - navigate and use back, forward, or reload;
  - inspect bounded visible page text and interactive controls;
  - click controls, type or submit text, and choose options;
  - scroll the page;
  - inspect a fresh snapshot after each action when Chrome permits it and continue a multi-step task.
- Shows a native confirmation card before actions by default.
- Supports on-device-only recognition when the current language provides it.

Orchard does not give the model a shell, AppleScript, arbitrary file access, Accessibility automation, cookies, saved passwords, file-input contents, or arbitrary JavaScript. Browser control uses fixed bundled commands with validated arguments. Chrome internal pages and other extensions remain unavailable.

Actions require an OpenRouter model that supports tool calling. If a selected model does not, turn off **Let the model propose Mac actions** in Settings.

## Requirements

- macOS 14 or later
- Xcode 26 or another Xcode version with Swift 6 support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An [OpenRouter API key](https://openrouter.ai/settings/keys)
- Google Chrome 116 or later for browser control

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
4. If an older Orchard extension is already loaded, choose **Reload**. Otherwise choose **Load unpacked** and select the revealed `ChromeExtension` folder.
5. Open **Orchard Browser Control** and choose **Enable** under **Website control**. This grants the optional HTTP/HTTPS page permission that browser operation needs.
6. Paste the pairing token from Orchard Settings and choose **Connect**. Allow Chrome's local-network prompt if it appears; the extension connects only to Orchard at `127.0.0.1`.
7. Ask Orchard to do something in Chrome, then approve its proposed browser actions. For example: “Use Chrome to find the weather tomorrow, open a reliable result, and tell me the forecast.”

The popup shows both connection and website-permission status. Website access can be revoked there at any time. Browser tasks are iterative: Orchard lists and binds an explicit tab, inspects the page, acts using opaque element IDs from that snapshot, and decides the next step from a fresh observation. If an action succeeds but Chrome blocks the follow-up inspection, Orchard reports that distinction and inspects again before using page controls.

Some websites may reject synthetic interactions, hide controls inside unsupported closed shadow roots, require CAPTCHA or trusted user gestures, or otherwise prevent automation. Orchard reports those failures instead of bypassing the site.

## Privacy and safety

- Typed prompts, recent conversation context, approved browser snapshots, and browser action results go to OpenRouter and the selected model provider.
- The API key is stored as a generic password in macOS Keychain. It is not written to `UserDefaults`, source code, or logs.
- Speech output is generated locally on the Mac.
- Speech input uses Apple's Speech framework. Depending on the language and system support, macOS may send audio to Apple. Enable **Require on-device recognition** in Settings to prevent that fallback.
- Orchard is sandboxed. Its browser bridge listens only on `127.0.0.1:38476` and mutually authenticates with a random pairing token kept in Orchard's sandboxed preferences. Challenge-response proofs keep the token itself off the socket.
- Chrome website control is an explicit, optional, revocable permission covering HTTP and HTTPS pages. The extension does not request browsing history, cookies, downloads, the `debugger` permission, or required broad website access.
- The extension injects only its fixed bundled page controller. The LLM cannot send JavaScript or CSS selectors. It acts through short-lived opaque tab, snapshot, and element IDs. Every approved existing-tab command is also bound to the exact observed URL and is rejected if that tab changes before execution.
- Visible page content is bounded, URL-validated, marked as untrusted, and wrapped in prompt-injection safety instructions. Page text never authorizes another action.
- Password and file inputs are redacted and cannot be interacted with through Orchard. Chrome internal pages, extension pages, and non-HTTP(S) URLs are rejected.
- Browser tools stay available across bounded model rounds so Orchard can complete and verify multi-step tasks. The final round is tool-free so it must explain the outcome instead of looping indefinitely.

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
      Mac actions       browser commands
                              |
                  authenticated loopback WebSocket
                              |
                     paired Chrome extension
                              |
                  fixed isolated page controller
                              |
                semantic snapshot + action result
                              |
                  next bounded OpenRouter round
```

The OpenRouter client uses `URLSession` directly and handles SSE keepalives, usage-only chunks, tool-call argument fragments, mid-stream errors, cancellation, and `[DONE]`. The browser bridge uses Apple's Network framework and protocol v2 authenticated WebSockets. No third-party networking, browser-automation, or AI SDK is required.

## SpeakPad attribution

The files under `Sources/SpeakPadSpeech` are adapted from SpeakPad v0.2.0 at commit `4759c090eac120947fd785d32c60aeb41a6bbcde`. SpeakPad's MIT license is preserved in [`ThirdParty/SpeakPad/LICENSE`](ThirdParty/SpeakPad/LICENSE).
The built app also includes `Resources/ThirdPartyNotices.txt`, containing the SpeakPad MIT notice and Orchard's PolyForm license URL.

## License

Orchard is distributed under the [PolyForm Noncommercial License 1.0.0](LICENSE).
