import AppKit
import SwiftUI

struct MCPInstructionsPane: View {
    var embedded = false
    @State private var claudeInstallError: String?
    @State private var showingPluginInfo = false

    private var mcpEndpoint: String { "http://127.0.0.1:\(MCPService.port)/mcp" }

    private var claudeCodeCommand: String {
        "claude mcp add --transport http voxstudio \(mcpEndpoint)"
    }

    private var codexCommand: String {
        "codex mcp add voxstudio-direct --url \(mcpEndpoint)"
    }

    private let pluginDownloadURL = URL(string: "https://assets.voxstudio.me/downloads/voxstudio/plugins/voxstudio/0.1.0/f116e011f1e6abe2550901c1fa345733a805f3633c2b7f18f7098120db29a539/VoxStudio-OpenAI-Plugin.zip")!
    private let pluginInstallCommand = "bash \"$HOME/Downloads/VoxStudio-OpenAI-Plugin/install.sh\""
    private var usesOpenAIPlugin: Bool { client == .chatgpt || client == .codex }

    private var cursorJSONConfig: String {
        """
        {
          "mcpServers": {
            "voxstudio": {
              "type": "http",
              "url": "\(mcpEndpoint)"
            }
          }
        }
        """
    }

    private var cursorDeepLink: URL? {
        let config: [String: String] = ["type": "http", "url": mcpEndpoint]
        guard
            let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
            let encoded = data.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=voxstudio&config=\(encoded)")
    }

    private enum Client: String, CaseIterable {
        case chatgpt = "ChatGPT Work", claudeDesktop = "Claude Desktop", claudeCode = "Claude Code", codex = "Codex", cursor = "Cursor"

        var agent: SkillExternalAgent {
            switch self {
            case .claudeDesktop, .claudeCode: .claude
            case .chatgpt, .codex: .codex
            case .cursor: .cursor
            }
        }
    }

    @State private var client: Client = .codex
    @State private var presentedSkill: SkillLink?
    @State private var installing: Set<String> = []
    @State private var skillError: String?
    @Bindable private var catalog = SkillCatalog.shared
    @Bindable private var store = SkillStore.shared

    private struct SkillLink: Identifiable { let id: String }
    private var running: Bool { AppState.shared.mcpService?.isRunning ?? false }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                ScrollView {
                    content
                        .frame(maxWidth: AppTheme.Settings.contentMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(AppTheme.Spacing.xlXxl)
                }
                .appScrollEdgeEffect(.top)
            }
        }
        .task {
            await store.reloadInBackground()
            await catalog.refresh()
        }
        .sheet(item: $presentedSkill) { item in
            SkillDetailSheet(skillID: item.id)
                .appZoomEnvironment(presentationBoundary: true)
        }
        .alert(L10n.string("Unable to complete setup"), isPresented: Binding(
            get: { claudeInstallError != nil || skillError != nil },
            set: { if !$0 { claudeInstallError = nil; skillError = nil } }
        )) {
            Button(L10n.string("Dismiss")) { claudeInstallError = nil; skillError = nil }
        } message: {
            Text((claudeInstallError ?? skillError).map(L10n.display) ?? L10n.string("Try again."))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xlXxl) {
            if !embedded { hero }
            connection
            workflows
            Label(L10n.string("Keep VoxStudio open while your agent works."), systemImage: "info.circle")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Button(L10n.string("Browse all skills")) {
                SettingsWindowController.shared.show(tab: .skills)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Accent.link)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            HStack {
                Label("MCP", systemImage: "network")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(AppTheme.Accent.link)
                Spacer()
                Label(L10n.string(running ? "Server running" : "Server stopped"),
                      systemImage: running ? "circle.inset.filled" : "circle")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(running ? AppTheme.Status.successColor : AppTheme.Text.tertiaryColor)
            }
            Text(L10n.string("Your workspace. Your favorite agent."))
                .font(.system(size: AppTheme.FontSize.title2, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.string("Transcribe media, create voiceovers, and edit your Mac app timeline from your favorite AI agent."))
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.sm) {
                capability("Knowledge & search", icon: "books.vertical")
                capability("Transcription & voiceover", icon: "waveform")
                capability("Video editing", icon: "timeline.selection")
            }
            if !running {
                Button(L10n.string("Open MCP settings")) {
                    SettingsWindowController.shared.show(tab: .agent)
                }
                .buttonStyle(.capsule(.secondary))
            }
        }
        .padding(AppTheme.Spacing.lgXl)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .fill(LinearGradient(colors: [AppTheme.Accent.link.opacity(0.14), AppTheme.Background.raisedColor],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Accent.link.opacity(0.2), lineWidth: 1)
        }
    }

    private func capability(_ title: String, icon: String) -> some View {
        Label(L10n.string(title), systemImage: icon)
            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(AppTheme.Background.surfaceColor.opacity(0.6), in: Capsule())
    }

    private func sectionHeading(_ number: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
            Text(number)
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.Accent.link)
                .padding(AppTheme.Spacing.sm)
                .background(AppTheme.Accent.link.opacity(0.1), in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(L10n.string(title))
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(L10n.string(subtitle))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            sectionHeading("01", title: "Connect your agent", subtitle: "Choose a client. Set it up once.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: AppTheme.zoomed(125)), spacing: AppTheme.Spacing.sm)], spacing: AppTheme.Spacing.sm) {
                ForEach(Client.allCases, id: \.self) { item in
                    Button { client = item } label: {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            ExternalAgentLogo(agent: item.agent, size: AppTheme.IconSize.lg)
                            Text(item.rawValue)
                                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(client == item ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                        .padding(AppTheme.Spacing.smMd)
                        .themedSurface(client == item ? AppTheme.Accent.link.opacity(0.12) : AppTheme.Background.raisedColor,
                                       cornerRadius: AppTheme.Radius.sm,
                                       border: client == item ? AppTheme.Accent.link.opacity(0.6) : AppTheme.Border.subtleColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(client == item ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                clientInstructions
                Divider().overlay(AppTheme.Border.subtleColor)
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(L10n.string("Server URL"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(mcpEndpoint)
                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    CopyButton(value: mcpEndpoint)
                }
            }
            .padding(AppTheme.Spacing.mdLg)
            .themedSurface(AppTheme.Background.raisedColor, cornerRadius: AppTheme.Radius.md)
        }
    }

    @ViewBuilder private var clientInstructions: some View {
        switch client {
        case .claudeDesktop:
            setupDescription("Install the connector, then enable it in Claude Desktop.")
            Button(action: openClaudeDesktopBundle) {
                Label(L10n.string("Install in Claude Desktop"), systemImage: "arrow.up.right")
            }
            .buttonStyle(.capsule(.prominent))
        case .claudeCode:
            setupDescription("Run this command in Terminal, then start a new Claude Code session.")
            CodeBlockView(content: claudeCodeCommand)
        case .chatgpt, .codex:
            openAIPluginInstructions
        case .cursor:
            setupDescription("Add the server to Cursor, then enable it in MCP settings.")
            Button(action: openCursor) {
                Label(L10n.string("Install in Cursor"), systemImage: "arrow.up.right")
            }
            .buttonStyle(.capsule(.prominent))
            ManualFallback(intro: "Add this configuration to ~/.cursor/mcp.json.", code: cursorJSONConfig)
        }
    }

    private var openAIPluginInstructions: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("VoxStudio plugin"))
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                Text("0.1.0 · ZIP")
                    .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Spacer()
                Button { showingPluginInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: AppTheme.IconSize.md))
                        .frame(width: AppTheme.zoomed(28), height: AppTheme.zoomed(28))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Accent.link)
                .accessibilityLabel(L10n.string("About the OpenAI plugin"))
                .help(L10n.string("About the OpenAI plugin"))
                .popover(isPresented: $showingPluginInfo) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        Text(L10n.string("About the OpenAI plugin"))
                            .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                        setupDescription("The ZIP contains a local marketplace, plugin manifests, workflow skills and an installer. VoxStudio provides the MCP server and panels.")
                        setupDescription("Use a desktop client with local plugin support on this Mac. ChatGPT web and cloud sessions cannot connect to this local server. Client versions may offer different plugin features.")
                        setupDescription("Disable any old direct MCP connection named voxstudio before enabling this plugin. A same-name connection can hide the plugin tools.")
                        setupDescription("Panels use English. Video edits run in the native VoxStudio timeline; there is no HTML video editor.")
                        Link(L10n.string("Official plugin guide"), destination: URL(string: "https://developers.openai.com/plugins/build/plugins")!)
                    }
                    .padding(AppTheme.Spacing.lg)
                    .frame(width: AppTheme.zoomed(360))
                }
            }
            setupDescription("Recommended for ChatGPT Work and Codex on this Mac. Keep VoxStudio running and MCP enabled.")
            pluginStep("1", title: "Download and extract", detail: "Download the ZIP and extract it in Downloads. Keep the extracted folder in place after installation.") {
                HStack(spacing: AppTheme.Spacing.md) {
                    Button { NSWorkspace.shared.open(pluginDownloadURL) } label: {
                        Label(L10n.string("Download plugin"), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.capsule(.prominent))
                    CopyButton(value: pluginDownloadURL.absoluteString, label: "Copy download URL")
                }
            }
            pluginStep("2", title: "Install from Terminal", detail: "Run this after extracting the ZIP. If you chose another folder, use its install.sh path. The installer registers VoxStudio Local and installs the plugin.") {
                CodeBlockView(content: pluginInstallCommand)
            }
            pluginStep("3", title: "Enable and start a new chat", detail: "In your desktop client's Plugins page, enable VoxStudio under VoxStudio Local. Restart the client if it is missing, then open a new chat.") {
                HStack {
                    Text(L10n.string("Open my VoxStudio sessions."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .textSelection(.enabled)
                    Spacer()
                    CopyButton(value: L10n.string("Open my VoxStudio sessions."), label: "Copy prompt")
                }
            }
            if client == .codex {
                DisclosureGroup(L10n.string("Advanced: MCP tools only")) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        setupDescription("Use this instead of the plugin for a direct tool connection. This does not install plugin skills or panel entry points. Do not enable both setups.")
                        CodeBlockView(content: codexCommand)
                    }
                    .padding(.top, AppTheme.Spacing.sm)
                }
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
    }

    private func pluginStep<Content: View>(_ number: String, title: String, detail: String,
                                           @ViewBuilder action: () -> Content) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
            Text(number)
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.Accent.link)
                .frame(width: AppTheme.zoomed(24), height: AppTheme.zoomed(24))
                .background(AppTheme.Accent.link.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string(title))
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                setupDescription(detail)
                action()
            }
        }
    }

    private func setupDescription(_ text: String) -> some View {
        Text(L10n.string(text))
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var workflows: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            sectionHeading("02", title: "Try a workflow", subtitle: usesOpenAIPlugin
                           ? "The plugin includes workflow skills. Copy a prompt into a new chat."
                           : "Copy a prompt into your agent. Add a skill for a guided workflow.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: AppTheme.zoomed(245)), spacing: AppTheme.Spacing.md)], spacing: AppTheme.Spacing.md) {
                ForEach(workflowExamples) { workflow in
                    workflowCard(workflow)
                }
            }
            Text(L10n.string(usesOpenAIPlugin
                            ? "Use separate panels for sessions, transcription and voiceover. Describe video edits in chat to update the Mac app timeline."
                            : "Skills install in VoxStudio. Open a skill and choose Add to External Agent to use it in Claude Code, Codex, or Cursor."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workflowExamples: [MCPWorkflow] {
        guard usesOpenAIPlugin else { return MCPWorkflow.examples }
        return [
            .init(id: "plugin-sessions", icon: "rectangle.stack", title: "Open your sessions",
                  scope: "Session library", prompt: "Open my VoxStudio sessions.", skillID: ""),
            .init(id: "plugin-transcription", icon: "text.bubble", title: "Transcribe media",
                  scope: "Transcription panel", prompt: "Open the VoxStudio transcription panel so I can choose an audio or video file and review the options before starting.", skillID: ""),
            .init(id: "plugin-voiceover", icon: "waveform.and.person.filled", title: "Create a voiceover",
                  scope: "Voiceover panel", prompt: "Open the VoxStudio voiceover panel so I can choose a voice and enter my script.", skillID: ""),
            .init(id: "plugin-timeline", icon: "timeline.selection", title: "Edit the Mac timeline",
                  scope: "Open a video project", prompt: "Inspect the active project in the VoxStudio Mac app. Tell me what is on its timeline, then help me edit it from this chat.", skillID: "")
        ]
    }

    private func workflowCard(_ workflow: MCPWorkflow) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Image(systemName: workflow.icon)
                    .font(.system(size: AppTheme.FontSize.mdLg))
                    .foregroundStyle(AppTheme.Accent.link)
                Spacer()
                Text(L10n.string(workflow.scope))
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Text(L10n.string(workflow.title))
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(L10n.string(workflow.prompt))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: AppTheme.zoomed(80), alignment: .topLeading)
            HStack {
                CopyButton(value: L10n.string(workflow.prompt), label: "Copy prompt")
                Spacer(minLength: AppTheme.Spacing.xs)
                if !usesOpenAIPlugin { Button {
                    openSkill(workflow.skillID)
                } label: {
                    if installing.contains(workflow.skillID) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L10n.string(store.skills.contains { $0.id == workflow.skillID } ? "Open skill" : "Get skill"), systemImage: "book.closed")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Accent.link)
                .disabled(installing.contains(workflow.skillID))
                .help(workflow.skillID)
                }
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .themedSurface(AppTheme.Background.raisedColor, cornerRadius: AppTheme.Radius.md)
    }

    private func openSkill(_ id: String) {
        if store.skills.contains(where: { $0.id == id }) {
            presentedSkill = SkillLink(id: id)
            return
        }
        installing.insert(id)
        Task {
            defer { installing.remove(id) }
            if catalog.entry(id: id) == nil { await catalog.refresh() }
            guard let entry = catalog.entry(id: id), await store.install(entry) else {
                skillError = "Unable to download this skill. Check your connection and try again."
                return
            }
            presentedSkill = SkillLink(id: id)
        }
    }

    private func openCursor() {
        guard let cursorDeepLink else { return }
        NSWorkspace.shared.open(cursorDeepLink, configuration: .init(), completionHandler: nil)
    }

    private func openClaudeDesktopBundle() {
        guard let bundleURL = claudeDesktopBundleURL else {
            claudeInstallError = "The VoxStudio connector could not be found. Reinstall VoxStudio, then try again."
            return
        }
        guard let claudeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            claudeInstallError = "Install Claude Desktop, then try again."
            return
        }

        NSWorkspace.shared.open(
            [bundleURL],
            withApplicationAt: claudeURL,
            configuration: .init()
        ) { _, error in
            guard error != nil else { return }
            Task { @MainActor in
                claudeInstallError = "Claude Desktop could not open the VoxStudio connector. Update Claude Desktop, then try again."
            }
        }
    }

    private var claudeDesktopBundleURL: URL? {
        BundledResource.url("voxstudio.mcpb")
    }
}

private struct CodeBlockView: View {
    let content: String
    var fontSize = AppTheme.FontSize.xs
    var foreground = AppTheme.Text.secondaryColor
    var verticalPadding = AppTheme.Spacing.md

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
            Text(content)
                .font(.system(size: fontSize, weight: AppTheme.FontWeight.regular, design: .monospaced))
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            CopyButton(value: content)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, verticalPadding)
        .themedSurface(AppTheme.Background.raisedColor, cornerRadius: AppTheme.Radius.sm)
    }
}

private struct ManualFallback: View {
    let intro: String
    let code: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Button(action: toggle) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.regular))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Manual setup")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
                }
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(L10n.string(key: intro))
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    CodeBlockView(content: code)
                }
            }
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: AppTheme.Anim.hover)) {
            expanded.toggle()
        }
    }
}

private struct CopyButton: View {
    private static let feedbackDuration: Duration = .seconds(1.4)

    let value: String
    var label: String? = nil
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                if let label { Text(L10n.string(copied ? "Copied" : label)) }
            }
            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            .foregroundStyle(copied ? AppTheme.Status.successColor : AppTheme.Text.secondaryColor)
            .frame(minWidth: AppTheme.IconSize.lg, minHeight: AppTheme.IconSize.lg)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(L10n.string(copied ? "Copied" : "Copy"))
        .accessibilityLabel(L10n.string(copied ? "Copied" : (label ?? "Copy")))
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: Self.feedbackDuration)
            copied = false
        }
    }
}

#Preview {
    MCPInstructionsPane()
        .frame(width: AppTheme.Settings.contentMaxWidth, height: AppTheme.Settings.skillDetailMinHeight)
        .background(AppTheme.Background.surfaceColor)
}
