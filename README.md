# Brainless

**說話，不要打字。** macOS 語音聽寫 App：按一下快捷鍵說話，再按一下，整理好的文字就出現在游標那裡。語音辨識用 Whisper large-v3（whisper.cpp，Metal），在本機跑；潤稿用你電腦上已登入的 AI agent CLI（Claude Code 的 `claude -p` 或 Codex 的 `codex exec`），想完全離線也可以改用 Ollama 跑 Qwen。

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
- 硬碟空間約 3.5 GB（Whisper 模型 3.1 GB）；改用 Ollama 潤稿的話再加約 7.6 GB（Qwen 3.5 9B）。
- 潤稿需要下列其中一個：已登入的 [Claude Code](https://code.claude.com/docs/en/quickstart) 或 [Codex CLI](https://github.com/openai/codex)，或 [Ollama](https://ollama.com/download)。

## 安裝

1. 到 [Releases](../../releases) 下載 `Brainless-x.y.z.zip`，解壓縮後把 `Brainless.app` 拖進「應用程式」。
2. 第一次打開：在 Finder 對 Brainless.app **按右鍵 › 打開**（這個版本沒有 Apple 開發者簽章，直接雙擊會被擋）。
3. 依照系統提示允許**麥克風**，並到 系統設定 › 隱私權與安全性 › **輔助使用** 打開 Brainless。
4. 主視窗會列出還缺什麼：
   - 安裝 whisper.cpp：在終端機執行 `brew install whisper-cpp`（需要 [Homebrew](https://brew.sh)）。
   - 按「下載 Whisper 模型」（3.1 GB）。
   - 潤稿：裝好 Claude Code 或 Codex CLI 並登入一次，App 會自動偵測；兩個都沒有的話，安裝 [Ollama](https://ollama.com/download) 並按「下載 qwen3.5:9b」（約 7.6 GB）。
5. 燈都綠了，游標點到任何可以打字的地方，按一下快捷鍵（預設右 Option），說話，再按一下。

## 快捷鍵

預設右 Option（Windows 鍵盤上是右邊的 Alt）。設定頁可以改成右 Command、右 Control、Fn、F18、F19，或按「自訂」然後按下任何你想用的鍵。按一下開始、再按一下結束；按住說完放開也可以；說話中按 Esc 取消。

## 麥克風保持喚醒

USB 麥克風閒置幾分鐘就會被 macOS 休眠，醒來的前兩三秒是靜音。設定頁的「麥克風保持喚醒」預設「一直開著」，隨按隨有聲音；代價是選單列會有橘色麥克風點（沒按快捷鍵時不存、不送任何聲音）。可以改成「用完後再撐 10 分鐘」或「用完就關」。

## 潤稿後端

設定頁「潤稿後端」預設「自動」，依序用偵測到的第一個：Claude Code → Codex → Ollama。偵測方式比照 `ollama launch`：先找 PATH（App 會向你的登入 shell 要 PATH，所以 nvm、`~/.local/bin` 裡的也找得到），再找各家的預設安裝位置。

- **Claude Code**：`claude -p`，預設模型 `haiku`，不開任何工具、不讀你的設定檔與 MCP、不留 session。一次約 3–8 秒。
- **Codex**：`codex exec`，唯讀沙箱、不留 session、reasoning effort 設為 low；模型留空就用 `~/.codex/config.toml` 的設定。一次約 5–8 秒。
- **Ollama**：本機跑 Qwen，模型常駐的話不到一秒，完全不連網。

agent 在一個空資料夾（`~/Library/Application Support/Whispry/agent-workdir`）裡執行，讀不到任何專案檔。用量算在你自己的 Claude／ChatGPT 帳號上。

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

程式結構：`Sources/` 下 `AppController`（狀態機與選單）、`HotkeyMonitor`（CGEventTap）、`AudioRecorder`（AVAudioEngine → 16 kHz WAV）、`WhisperServer`（whisper-server 子程序 + HTTP）、`RefineService`（潤稿後端切換）、`AgentCLI`（偵測與呼叫 claude／codex）、`OllamaClient`、`TextInserter`（剪貼簿 + ⌘V）、`OverlayPanel`（浮條）、`HubView` / `SetupViews`（SwiftUI 主視窗）、`Stores`（歷史、詞典）、`ModelSetup`（下載）、`VolumeManager`。

內部識別碼是 `app.whispry.mac`（專案原名 Whispry，為了不弄掉已授權的權限而保留）。簽章是 ad-hoc 加固定的 designated requirement，重新編譯不會讓輔助使用權限失效。

## 隱私

- 聲音只送到本機的 `127.0.0.1:8178`（whisper-server），只聽本機。錄音檔辨識完就刪掉。
- **潤稿用 Claude Code 或 Codex 時，辨識出來的文字（以及「問任何事」選取的文字）會透過該 CLI 送到 Anthropic／OpenAI 的雲端模型。** 要完全不離開這台電腦，請在設定頁把潤稿後端改成 Ollama（`127.0.0.1:11434`）。
- 歷史紀錄與詞典存在 `~/Library/Application Support/Whispry/`，檔案權限 600。
- 記錄檔不存逐字稿內容，只記字數與耗時。
- App 本身沒有任何網路回報、沒有帳號、沒有訂閱。

## 已知限制

- 單次最長 10 分鐘。
- 不吃 ⌘V 的 App（例如某些終端機）貼不上，可從選單「複製上一次的結果」手動貼。
- 沒有 Apple 開發者簽章，第一次要右鍵打開。

---

## English

**Speak, don't type.** A voice dictation app for macOS. Press a hotkey, talk, press again, and polished text lands at your cursor. Speech recognition runs locally on Whisper large-v3 (whisper.cpp, Metal). Cleanup, translation and "ask anything" run through a locally installed AI agent CLI (`claude -p` or `codex exec`, auto-detected the same way `ollama launch` finds integrations), or fully offline on Qwen via Ollama.

**Features**: dictation with filler-word removal and punctuation, translation (zh → en/ja/ko), "ask anything" on selected text, a personal dictionary that steers both Whisper and the LLM, local history, a menu-bar app plus a dashboard window (insights, history, dictionary, settings), configurable hotkey (including "press any key to learn"), Esc to cancel, keep-mic-awake option for USB mics.

**Requirements**: Apple Silicon, macOS 14+, 16 GB RAM (32 GB recommended), a microphone, ~3.5 GB disk, plus a signed-in Claude Code or Codex CLI — or Ollama (+7.6 GB) for fully offline use.

**Install**: download the zip from Releases, drag `Brainless.app` to Applications, right-click › Open the first time (ad-hoc signed), grant Microphone and Accessibility, then follow the setup card in the main window: `brew install whisper-cpp`, download the Whisper model (3.1 GB), then install and sign in to Claude Code or Codex — or install [Ollama](https://ollama.com/download) and pull `qwen3.5:9b` (~7.6 GB). Pick the backend under Settings › 潤稿後端 (default: first one detected, Claude Code → Codex → Ollama).

**Build**: `./build.sh` with Xcode Command Line Tools only. See `Sources/` for the structure described above.

**Privacy**: audio goes only to local whisper-server (127.0.0.1:8178). With the Claude Code or Codex backend, the transcript (and any selected text in "ask" mode) is sent to Anthropic/OpenAI through that CLI; choose Ollama (127.0.0.1:11434) to keep everything on-device. History and dictionary live in `~/Library/Application Support/Whispry/` with 600 permissions; logs never contain transcripts; no telemetry, no account.

MIT License.
