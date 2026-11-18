import AppKit
import SwiftUI

@main
struct CopilotBridgeApp: App {
  @NSApplicationDelegateAdaptor(CopilotBridgeApplicationDelegate.self) private var appDelegate
  @StateObject private var model: BridgeAppModel

  init() {
    let model = BridgeAppModel()
    _model = StateObject(wrappedValue: model)
    appDelegate.bind(model: model)
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarContent(model: model)
    } label: {
      Label(
        "CopilotBridge",
        systemImage: model.isRunning
          ? "point.3.connected.trianglepath.dotted" : "point.3.filled.connected.trianglepath.dotted"
      )
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsView(model: model)
        .frame(minWidth: 680, minHeight: 560)
    }
  }
}

private struct MenuBarContent: View {
  @ObservedObject var model: BridgeAppModel

  var body: some View {
    Text(model.isRunning ? "运行中 · 127.0.0.1:\(model.port)" : "已停止")
    Button(model.isRunning ? "停止代理" : "启动代理") { model.toggleServer() }
      .disabled(model.isBusy || (!model.isRunning && !model.isCredentialStoreReady))
    Divider()
    Button("复制 OpenAI Base URL") { BridgeAppModel.copy(model.openAIBaseURL) }
    Button("复制本地 API key") { BridgeAppModel.copy(model.localAPIKey) }
      .disabled(!model.isCredentialStoreReady)
    Divider()
    SettingsLink { Text("设置…") }
    Button("退出") {
      NSApplication.shared.terminate(nil)
    }
  }
}
