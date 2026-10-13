# Brainless

**說話，不要打字。** 全本地的 macOS 語音聽寫 App：按一下快捷鍵說話，再按一下，整理好的文字就出現在游標那裡。語音辨識用 Whisper large-v3（whisper.cpp，Metal），潤稿用 Qwen（Ollama）。錄音與文字都不離開你的電腦。

[English below](#english)

![Brainless 主視窗](docs/hub.png)

## 它會做什麼

- **聽寫**：口語變成乾淨的文字，去掉「嗯」「那個」，補標點，簡體自動轉繁體。
- **翻譯**：說中文，貼出英文、日文或韓文。
- **問任何事**：先選一段文字，再用說的下指令（改客氣一點、縮短、翻成英文），結果直接取代選取的文字。
- **詞典**：把常講的專有名詞、人名、公司名放進去，辨識和潤稿會優先用這些寫法。
- **歷史紀錄**：每次聽寫的結果都在本機，可複製、重新潤稿、刪除。
- 任何 App 都能用（透過剪貼簿貼上，貼完會把原本的剪貼簿還原）。

## 需求

- Apple Silicon Mac，macOS 14 以上，記憶體 16 GB 以上（建議 32 GB）。
- 一個麥克風（Mac mini 沒有內建）。
- 硬碟空間約 11 GB（Whisper 模型 3.1 GB、Qwen 3.5 9B 約 7.6 GB）。

## 安裝

1. 到 [Releases](../../releases) 下載 `Brainless-x.y.z.zip`，解壓縮後把 `Brainless.app` 拖進「應用程式」。
2. 第一次打開：在 Finder 對 Brainless.app **按右鍵 › 打開**（這個版本沒有 Apple 開發者簽章，直接雙擊會被擋）。
3. 依照系統提示允許**麥克風**，並到 系統設定 › 隱私權與安全性 › **輔助使用** 打開 Brainless。
4. 主視窗會列出還缺什麼：
   - 安裝 whisper.cpp：在終端機執行 `brew install whisper-cpp`（需要 [Homebrew](https://brew.sh)）。
   - 按「下載 Whisper 模型」（3.1 GB）。
   - 安裝 [Ollama](https://ollama.com/download)，打開一次。
   - 按「下載 qwen3.5:9b」（約 7.6 GB）。
5. 四個燈都綠了，游標點到任何可以打字的地方，按一下快捷鍵（預設右 Option），說話，再按一下。

## 快捷鍵

預設右 Option（Windows 鍵盤上是右邊的 Alt）。設定頁可以改成右 Command、右 Control、Fn、F18、F19，或按「自訂」然後按下任何你想用的鍵。按一下開始、再按一下結束；按住說完放開也可以；說話中按 Esc 取消。

## 麥克風保持喚醒

USB 麥克風閒置幾分鐘就會被 macOS 休眠，醒來的前兩三秒是靜音。設定頁的「麥克風保持喚醒」預設「一直開著」，隨按隨有聲音；代價是選單列會有橘色麥克風點（沒按快捷鍵時不存、不送任何聲音）。可以改成「用完後再撐 10 分鐘」或「用完就關」。

## 模型放哪裡

預設在 `~/Library/Application Support/Whispry/models/`。硬碟不夠的話，可以把模型放在外接硬碟上的 APFS 磁碟映像裡（exFAT 硬碟直接放會很不穩），在終端機設定：

```
defaults write app.whispry.mac modelImagePath -string "/Volumes/你的硬碟/BrainlessModels.sparsebundle"
```

App 啟動時會自動掛載。Ollama 的模型目錄請自行用 symlink 指到同一個地方（`~/.ollama/models`）。

## 自己編譯

只需要 Xcode Command Line Tools（`xcode-select --install`），不需要 Xcode。

```
./build.sh
cp -R build/Brainless.app /Applications/
```

程式結構：`Sources/` 下 `AppController`（狀態機與選單）、`HotkeyMonitor`（CGEventTap）、`AudioRecorder`（AVAudioEngine → 16 kHz WAV）、`WhisperServer`（whisper-server 子程序 + HTTP）、`OllamaClient`、`TextInserter`（剪貼簿 + ⌘V）、`OverlayPanel`（浮條）、`HubView` / `SetupViews`（SwiftUI 主視窗）、`Stores`（歷史、詞典）、`ModelSetup`（下載）、`VolumeManager`。

內部識別碼是 `app.whispry.mac`（專案原名 Whispry，為了不弄掉已授權的權限而保留）。簽章是 ad-hoc 加固定的 designated requirement，重新編譯不會讓輔助使用權限失效。

## 隱私

- 聲音只送到本機的 `127.0.0.1:8178`（whisper-server）與 `127.0.0.1:11434`（Ollama），兩者都只聽本機。
- 歷史紀錄與詞典存在 `~/Library/Application Support/Whispry/`，檔案權限 600。
- 記錄檔不存逐字稿內容，只記字數與耗時。
- 沒有任何網路回報、沒有帳號、沒有訂閱。

## 已知限制

- 單次最長 10 分鐘。
- 不吃 ⌘V 的 App（例如某些終端機）貼不上，可從選單「複製上一次的結果」手動貼。
- 沒有 Apple 開發者簽章，第一次要右鍵打開。

---

## English

**Speak, don't type.** A fully local voice dictation app for macOS. Press a hotkey, talk, press again, and polished text lands at your cursor. Speech recognition runs on Whisper large-v3 (whisper.cpp, Metal); cleanup, translation and "ask anything" run on Qwen via Ollama. Nothing leaves your machine.

**Features**: dictation with filler-word removal and punctuation, translation (zh → en/ja/ko), "ask anything" on selected text, a personal dictionary that steers both Whisper and the LLM, local history, a menu-bar app plus a dashboard window (insights, history, dictionary, settings), configurable hotkey (including "press any key to learn"), Esc to cancel, keep-mic-awake option for USB mics.

**Requirements**: Apple Silicon, macOS 14+, 16 GB RAM (32 GB recommended), a microphone, ~11 GB disk.

**Install**: download the zip from Releases, drag `Brainless.app` to Applications, right-click › Open the first time (ad-hoc signed), grant Microphone and Accessibility, then follow the setup card in the main window: `brew install whisper-cpp`, download the Whisper model (3.1 GB), install [Ollama](https://ollama.com/download), pull `qwen3.5:9b` (~7.6 GB).

**Build**: `./build.sh` with Xcode Command Line Tools only. See `Sources/` for the structure described above.

**Privacy**: audio goes only to local whisper-server (127.0.0.1:8178) and Ollama (127.0.0.1:11434); history and dictionary live in `~/Library/Application Support/Whispry/` with 600 permissions; logs never contain transcripts; no telemetry, no account.

MIT License.
