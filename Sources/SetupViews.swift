import SwiftUI
import AppKit

/// 第一次使用的引擎設定卡：缺什麼就顯示什麼
struct SetupCard: View {
    @ObservedObject var model: HubModel
    @ObservedObject var downloader: ModelDownloader
    @ObservedObject var puller: OllamaPuller
    @State private var copied = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("第一次使用：把引擎備齊").font(.system(size: 15, weight: .bold))
                Text("語音辨識和潤稿都在這台電腦上跑，所以要先把兩個模型放到本機。").font(.system(size: 12)).foregroundColor(.secondary)

                row(ok: model.whisperServerPresent, title: "whisper.cpp（語音辨識引擎）") {
                    if !model.whisperServerPresent {
                        HStack(spacing: 8) {
                            Text("在「終端機」執行：").font(.system(size: 12)).foregroundColor(.secondary)
                            Text(ModelSetup.brewCommand).font(.system(size: 12, design: .monospaced))
                            Button(copied ? "已複製" : "複製指令") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ModelSetup.brewCommand, forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                            }
                        }
                        Text("沒有 Homebrew 的話先到 brew.sh 安裝。").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                row(ok: model.whisperModelPresent, title: "Whisper large-v3 模型（3.1 GB）") {
                    if !model.whisperModelPresent {
                        if downloader.running {
                            ProgressView(value: downloader.progress).frame(maxWidth: 320)
                            Text("下載中 \(Int(downloader.progress * 100))%").font(.system(size: 12)).foregroundColor(.secondary)
                        } else {
                            HStack(spacing: 8) {
                                Button("下載 Whisper 模型") { model.onDownloadWhisper?() }
                                if let e = downloader.error { Text(e).font(.system(size: 11)).foregroundColor(.red) }
                            }
                        }
                    }
                }
                row(ok: model.ollamaInstalled, title: "Ollama（跑潤稿模型的工具）") {
                    if !model.ollamaInstalled {
                        HStack(spacing: 8) {
                            Button("前往下載 Ollama") { NSWorkspace.shared.open(ModelSetup.ollamaDownloadURL) }
                            Text("裝好、打開一次之後回來這裡。").font(.system(size: 12)).foregroundColor(.secondary)
                        }
                    }
                }
                row(ok: model.ollamaOK, title: "潤稿模型 \(model.ollamaModel)（約 7 GB）") {
                    if !model.ollamaOK {
                        if puller.running {
                            ProgressView(value: puller.progress).frame(maxWidth: 320)
                            Text(puller.status).font(.system(size: 12)).foregroundColor(.secondary)
                        } else {
                            HStack(spacing: 8) {
                                Button("下載 \(model.ollamaModel)") { model.onPullModel?() }.disabled(!model.ollamaInstalled)
                                Text(model.ollamaStatus).font(.system(size: 12)).foregroundColor(.secondary)
                                if let e = puller.error { Text(e).font(.system(size: 11)).foregroundColor(.red) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func row<Content: View>(ok: Bool, title: String, @ViewBuilder _ c: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(ok ? Theme.green : Theme.orange).frame(width: 8, height: 8)
                Text(title).font(.system(size: 13, weight: .medium))
                if ok { Text("就緒").font(.system(size: 12)).foregroundColor(.secondary) }
            }
            c().padding(.leading, 18)
        }
    }
}
