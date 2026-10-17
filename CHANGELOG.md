# Changelog

這個 fork 的版本紀錄。1.0.5 以前的版本見上游 [austin17022/brainless](https://github.com/austin17022/brainless/releases)。

## 1.2.0 — 2026-10-17

### 新增
- **遠端語音辨識**：設定 › 語音辨識 可改用 OpenAI 相容的 `/audio/transcriptions` 端點，留空就用 Groq。實測每句 0.4–0.9 秒（本機 large-v3 約 2 秒）。遠端模式不會啟動本機 whisper-server。
- **OpenAI 相容潤稿後端**：直接打 `/chat/completions`，不經過 `claude -p`。端點留空用 Groq，模型留空用 `llama-3.3-70b-versatile`。
- **短句不潤稿**：聽寫模式下少於門檻（預設 12 個字）的句子直接貼上，不送 AI。
- **本機模型可選 large-v3 或 large-v3-turbo**：換模型時會結束上次留下、跑舊模型的 whisper-server（只動命令列確實是這個 App 的那一個）。
- **錄音先切掉靜音**：頭尾靜音切掉、超過 0.6 秒的停頓壓成 0.3 秒，減少 Whisper 在靜音上憑空生字。
- API Key 存在 macOS 鑰匙圈，用量算在你自己的帳號上。

### 變更
- **按一下開始、再按一下結束**：「按住說話」改成設定選項，預設關閉，按久了也不會意外結束錄音。
- **Esc 隨時取消**：錄音、辨識、潤稿任一階段都能取消，進行中的請求和 claude／codex 程序會被中止，晚到的結果不會貼上。
- **結果一律留在剪貼簿**：不再還原原本的剪貼簿。還在開始錄音的那個視窗才自動貼上，切到別的視窗就只複製。
- 遠端端點、模型、API Key 停止打字就自動儲存，不用按 Enter。

### 修正
- 某組快捷鍵被另一組更長的快捷鍵包含時（例如 左 Shift＋左 Option 與 左 Shift＋左 Control＋左 Option），快速點一下會被吃掉，只能按住才觸發。
- 主視窗的文字框不能用 ⌘V／⌘C／⌘X／⌘A：選單列 App 沒有「編輯」選單，macOS 收不到這些快捷鍵。

### 安全
- 遠端請求改用不寫磁碟快取、不跟隨轉址的連線。原本系統預設的 HTTP 快取會把含 API Key 的 `Authorization` 標頭明文寫進 `Cache.db`。
- 上游錯誤內容不寫進記錄檔；顯示在畫面上前會把 API Key 遮成 `***`。網址不接受帳號密碼；用明文 http 送 key 時顯示警告。

## 1.1.0 — 2026-10-17

### 新增
- **用本機 AI agent 潤稿**：自動偵測已登入的 Claude Code（`claude -p`）或 Codex（`codex exec`），找不到才用 Ollama。
- **每個模式各自的快捷鍵**：聽寫、翻譯、問任何事各自可設多組，支援修飾鍵組合與修飾鍵＋一般鍵。
- **從 Typeless 匯入詞典**，也可從文字／CSV／JSON 檔匯入。
- 以 DMG 發佈（`./release.sh`）。

### 變更
- 重新設計主視窗，切換分頁從 35–60 ms 降到 23–33 ms。
