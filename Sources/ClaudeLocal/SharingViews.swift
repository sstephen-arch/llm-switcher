import AppKit
import SwiftUI

/// Copy-ready setup for other computers, Windows and Mac.
enum SetupSnippets {
    enum Platform: String, CaseIterable, Identifiable {
        case windows = "Windows", mac = "Mac"
        var id: String { rawValue }
    }

    static func openCode(base: String, key: String, models: [String], platform: Platform) -> String {
        let entries = models.map { "        \"\($0)\": { \"name\": \"\($0)\" }" }.joined(separator: ",\n")
        let defaultModel = models.first.map { "  \"model\": \"claude-local/\($0)\",\n" } ?? ""
        let path = platform == .windows ? "%USERPROFILE%\\.config\\opencode\\opencode.json" : "~/.config/opencode/opencode.json"
        return """
        // Save as \(path)
        // (or opencode.json in a project folder). Then pick a model with /models.
        {
          "$schema": "https://opencode.ai/config.json",
        \(defaultModel)  "provider": {
            "claude-local": {
              "npm": "@ai-sdk/openai-compatible",
              "name": "LLM Switcher (\(LAN.computerName()))",
              "options": {
                "baseURL": "\(base)/v1",
                "apiKey": "\(key)"
              },
              "models": {
        \(entries)
              }
            }
          }
        }
        """
    }

    static func claudeCode(base: String, key: String, model: String, platform: Platform) -> String {
        switch platform {
        case .windows:
            return """
            # PowerShell, in the window where you'll run claude
            $env:ANTHROPIC_BASE_URL = "\(base)"
            $env:ANTHROPIC_AUTH_TOKEN = "\(key)"
            $env:ANTHROPIC_MODEL = "\(model)"
            $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "\(model)"
            $env:API_TIMEOUT_MS = "1800000"
            claude
            """
        case .mac:
            return """
            ANTHROPIC_BASE_URL="\(base)" \\
            ANTHROPIC_AUTH_TOKEN="\(key)" \\
            ANTHROPIC_MODEL="\(model)" \\
            ANTHROPIC_DEFAULT_HAIKU_MODEL="\(model)" \\
            API_TIMEOUT_MS=1800000 claude
            """
        }
    }

    static func codex(base: String, key: String, model: String, platform: Platform) -> String {
        let path = platform == .windows ? "%USERPROFILE%\\.codex\\config.toml" : "~/.codex/config.toml"
        let env = platform == .windows
            ? "# Then in PowerShell (once):  setx CLAUDE_LOCAL_KEY \"\(key)\"   and open a new window"
            : "# Then:  export CLAUDE_LOCAL_KEY=\"\(key)\""
        return """
        # Add to \(path), then run:  codex --profile claude-local
        [model_providers.claude-local]
        name = "LLM Switcher (\(LAN.computerName()))"
        base_url = "\(base)/v1"
        env_key = "CLAUDE_LOCAL_KEY"
        wire_api = "responses"

        [profiles.claude-local]
        model_provider = "claude-local"
        model = "\(model)"
        \(env)
        """
    }

    static func test(base: String, key: String, model: String, platform: Platform) -> String {
        switch platform {
        case .windows:
            return """
            # PowerShell: should print a short reply
            $h = @{ Authorization = "Bearer \(key)" }
            $b = '{"model":"\(model)","messages":[{"role":"user","content":"Say hi"}],"max_tokens":200}'
            (Invoke-RestMethod -Uri "\(base)/v1/chat/completions" -Method Post -Headers $h -ContentType "application/json" -Body $b).choices[0].message.content
            """
        case .mac:
            return """
            curl -s \(base)/v1/chat/completions \\
              -H "Authorization: Bearer \(key)" -H "Content-Type: application/json" \\
              -d '{"model":"\(model)","messages":[{"role":"user","content":"Say hi"}],"max_tokens":200}'
            """
        }
    }

    static func trustCertificate(pem: String, platform: Platform) -> String {
        switch platform {
        case .windows:
            return """
            # PowerShell (once per computer): trust this Mac's certificate
            $pem = @'
            \(pem.trimmingCharacters(in: .whitespacesAndNewlines))
            '@
            $f = "$env:USERPROFILE\\claude-local.pem"
            Set-Content -Path $f -Value $pem -Encoding ascii
            Import-Certificate -FilePath $f -CertStoreLocation Cert:\\CurrentUser\\Root
            # OpenCode, Claude Code and other Node-based tools also need this (then open a new window):
            setx NODE_EXTRA_CA_CERTS $f
            """
        case .mac:
            return """
            # Terminal (once per computer): trust this Mac's certificate
            cat > ~/claude-local.pem <<'PEM'
            \(pem.trimmingCharacters(in: .whitespacesAndNewlines))
            PEM
            security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db ~/claude-local.pem
            # Node-based tools (OpenCode, Claude Code) also need:
            echo 'export NODE_EXTRA_CA_CERTS=~/claude-local.pem' >> ~/.zshrc
            """
        }
    }

    static func generic(base: String, key: String) -> String {
        """
        Any OpenAI-compatible tool (Continue, Cursor, Cline, Open WebUI, …):
          Base URL:  \(base)/v1
          API key:   \(key)
        Anthropic-style tools (Claude Code, …):
          Base URL:  \(base)
          API key:   \(key)
        """
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Compact sharing row for the menu bar panel.
struct ShareRow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { state.config.shareEnabled }, set: { state.setSharing($0) })) {
                Text("Share on network").font(.subheadline.weight(.semibold))
            }
            .toggleStyle(.switch)
            if state.config.shareEnabled {
                HStack(spacing: 6) {
                    Circle().fill(state.shareRunning ? Color.green : Color.orange).frame(width: 7, height: 7)
                    if state.config.tlsEnabled { Image(systemName: "lock.fill").font(.caption2) }
                    Text(state.shareBaseURL).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Copy") { copyToPasteboard(state.shareBaseURL + "/v1") }.controlSize(.small)
                }
                let people = state.config.clients.filter(\.enabled).count
                HStack {
                    Text("\(state.sharedModelList.count) models · \(people) key\(people == 1 ? "" : "s") · \(state.activity.filter { $0.client != "Claude (this Mac)" }.count) recent")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("How to connect…") { SettingsWindow.open(openWindow, tab: "sharing") }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// The Sharing tab in Settings.
struct SharingSettings: View {
    @EnvironmentObject var state: AppState
    @State private var platform: SetupSnippets.Platform = .windows
    @State private var model: String = ""
    @State private var clientID: String = ""
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                Toggle("Share my models on the local network", isOn: Binding(
                    get: { state.config.shareEnabled }, set: { state.setSharing($0) }))
                Text("Other computers on your network (Windows or Mac) can use the models you tick below with OpenCode, Claude Code, Codex or any OpenAI-compatible tool. Each person gets their own key. Only private network addresses are accepted, and keys can't manage oMLX.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if state.config.shareEnabled {
                Section("Address") {
                    ForEach(state.addresses) { a in
                        CopyField(label: a.label, value: "\(state.scheme)://\(a.ip):\(state.config.sharePort)/v1")
                    }
                    CopyField(label: "By name", value: "\(state.scheme)://\(LAN.localHostName()):\(state.config.sharePort)/v1")
                    Toggle("Let other computers find this Mac automatically (Bonjour)", isOn: Binding(
                        get: { state.config.bonjour }, set: { state.setBonjour($0) }))
                    LabeledContent("Status", value: state.shareRunning ? "Running" : "Starting…")
                }

                Section("Encryption") {
                    Toggle("Encrypt connections (HTTPS)", isOn: Binding(get: { state.config.tlsEnabled }, set: { state.setTLS($0) }))
                    Text("Stops anyone else on the Wi-Fi reading prompts and replies. Each computer must trust this Mac's certificate once (steps below). Turning this on changes the address to https.")
                        .font(.caption).foregroundStyle(.secondary)
                    if state.config.tlsEnabled {
                        LabeledContent("Certificate fingerprint") {
                            Text(state.certFingerprint.prefix(47) + "…").font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Button("Make a new certificate") { state.newCertificate() }
                    }
                }

                Section("People and keys") {
                    ForEach(state.config.clients) { c in ClientRow(client: c) }
                    HStack {
                        TextField("Name, e.g. Dad's laptop", text: $newName)
                        Button("Add key") { state.addClient(named: newName); newName = "" }
                    }
                }

                Section("Shared models") {
                    if state.models.isEmpty { Text("No models are available yet (is oMLX or Splash running?).").foregroundStyle(.secondary) }
                    ForEach(state.models, id: \.self) { m in
                        Toggle(isOn: Binding(get: { state.isShared(m) }, set: { state.setShared(m, $0) })) {
                            HStack {
                                Text(m)
                                if let e = state.engineOf[m] { Badge(text: e.label, color: e == .splash ? .blue : .secondary) }
                            }
                        }
                    }
                    Text("Models from oMLX and Splash are both offered while each is running. A model disappears from this list while its engine is stopped.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Connect another computer") {
                    Picker("Their computer", selection: $platform) {
                        ForEach(SetupSnippets.Platform.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Key for", selection: $clientID) {
                        ForEach(state.config.clients) { Text($0.name).tag($0.id) }
                    }
                    Picker("Model", selection: $model) {
                        ForEach(state.sharedModelList, id: \.self) { Text($0).tag($0) }
                    }
                    let m = model.isEmpty ? (state.sharedModelList.first ?? "model-name") : model
                    let key = state.config.clients.first { $0.id == clientID }?.key ?? state.config.clients.first?.key ?? ""
                    let base = state.shareBaseURL
                    if state.config.tlsEnabled {
                        Snippet(title: "1. Trust this Mac (HTTPS)", text: SetupSnippets.trustCertificate(pem: TLSCert.pem(), platform: platform))
                    }
                    Snippet(title: "OpenCode", text: SetupSnippets.openCode(base: base, key: key, models: state.sharedModelList, platform: platform))
                    Snippet(title: "Claude Code", text: SetupSnippets.claudeCode(base: base, key: key, model: m, platform: platform))
                    Snippet(title: "Codex", text: SetupSnippets.codex(base: base, key: key, model: m, platform: platform))
                    Snippet(title: "Quick test", text: SetupSnippets.test(base: base, key: key, model: m, platform: platform))
                    Snippet(title: "Other tools", text: SetupSnippets.generic(base: base, key: key))
                }

                Section("Recent requests") {
                    let shared = state.activity.filter { $0.client != "Claude (this Mac)" }
                    if shared.isEmpty { Text("No requests from other computers yet.").foregroundStyle(.secondary) }
                    ForEach(shared.prefix(15)) { a in ActivityRow(a: a) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if model.isEmpty { model = state.sharedModelList.first ?? "" }
            if clientID.isEmpty { clientID = state.config.clients.first?.id ?? "" }
        }
    }
}

struct ClientRow: View {
    @EnvironmentObject var state: AppState
    let client: ShareClient
    @State private var showKey = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: Binding(get: { client.name }, set: { var c = client; c.name = $0; state.updateClient(c) }))
                    .textFieldStyle(.plain).font(.body.weight(.medium))
                Spacer()
                Toggle("On", isOn: Binding(get: { client.enabled }, set: { var c = client; c.enabled = $0; state.updateClient(c) }))
                    .toggleStyle(.switch).labelsHidden()
                Text(client.enabled ? "Active" : "Paused").font(.caption).foregroundStyle(.secondary).frame(width: 46)
            }
            HStack {
                Text(showKey ? client.key : String(repeating: "•", count: 18)).font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                Button(showKey ? "Hide" : "Show") { showKey.toggle() }.controlSize(.small)
                Button("Copy key") { copyToPasteboard(client.key) }.controlSize(.small)
                Button("New key") { state.newKey(for: client) }.controlSize(.small)
                Button("Remove", role: .destructive) { confirmRemove = true }.controlSize(.small)
            }
            HStack(spacing: 16) {
                Stepper(value: Binding(get: { client.maxConcurrent }, set: { var c = client; c.maxConcurrent = max(0, $0); state.updateClient(c) }), in: 0...16) {
                    Text("At once: \(client.maxConcurrent == 0 ? "no limit" : "\(client.maxConcurrent)")").font(.caption)
                }
                Stepper(value: Binding(get: { client.perMinute }, set: { var c = client; c.perMinute = max(0, $0); state.updateClient(c) }), in: 0...600, step: 5) {
                    Text("Per minute: \(client.perMinute == 0 ? "no limit" : "\(client.perMinute)")").font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Remove \(client.name)'s key?", isPresented: $confirmRemove) {
            Button("Remove key", role: .destructive) { state.removeClient(client) }
        } message: { Text("Anything using this key stops working.") }
    }
}

struct ActivityRow: View {
    let a: Gateway.Activity
    var body: some View {
        HStack(spacing: 8) {
            Text(a.date, style: .time).font(.caption.monospaced())
            Text(a.client).font(.caption.weight(.medium)).lineLimit(1)
            Text(a.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if a.outputTokens > 0 { Text("\(a.inputTokens)→\(a.outputTokens)").font(.caption2.monospaced()).foregroundStyle(.secondary) }
            Text("\(a.status)").font(.caption.monospaced())
                .foregroundStyle(a.status < 400 ? Color.secondary : Color.red)
        }
    }
}

struct CopyField: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.monospaced()).textSelection(.enabled)
            Button("Copy") { copyToPasteboard(value) }
        }
    }
}

struct Snippet: View {
    let title: String
    let text: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    copyToPasteboard(text); copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
            }
            ScrollView(.horizontal) {
                Text(text).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
        .padding(.vertical, 4)
    }
}
