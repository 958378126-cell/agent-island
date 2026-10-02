import AppKit
import Combine
import SwiftUI
import Darwin

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let notifier = Notifier()
    private var store: TaskStore!
    private var watcher: TaskFileWatcher?
    private var processProbe: ProcessProbe?
    private var liveActivityProbe: LiveActivityProbe?
    private var configuredConnectorProbe: ConfiguredConnectorProbe?
    private var capsulePanel: FloatingPanel!
    private var capsuleHost: CapsuleHostingView<CapsuleView>!
    private var detailPanel: FloatingPanel!
    private var attentionPanel: FloatingPanel?
    private var addAgentPanel: AddAgentPanel?
    private var tickTimer: Timer?
    private var soakTimer: Timer?
    private var soakCPUTimer: Timer?
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var groupsCancellable: AnyCancellable?
    private var attentionCancellable: AnyCancellable?
    private var isDetailVisible = false
    private var soakStartedAt = Date()
    private var soakTick = 0
    private var soakCPUSamples: [Double] = []
    private var liveObservedTasks: [ObservedTask] = []
    private var configuredObservedTasks: [ObservedTask] = []

    override init() {
        super.init()
        let fixtureRoot = Self.fixtureRoot()
        store = TaskStore(
            dataPath: TaskFilePath.resolve(root: fixtureRoot, demo: LaunchOptions.isDemo),
            notifier: notifier
        )
    }

    private static func fixtureRoot() -> URL? {
        let raw = CommandLine.arguments.first ?? ""
        let absolute = raw.hasPrefix("/") ? raw : FileManager.default.currentDirectoryPath + "/" + raw
        var url = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !LaunchOptions.isSmoke && !LaunchOptions.isSoak { notifier.requestAuthorization() }
        store.reload()
        installCapsule()
        installDetailPanel()
        installMonitors()
        startWatching()
        startProcessProbe()
        startLiveActivityProbe()
        startConfiguredConnectorProbe()
        startTicking()
        if LaunchOptions.isSoak { startSoak() }
        print("[AgentIsland] 已启动｜数据文件：\(store.dataPath)")
        if LaunchOptions.isSmoke {
            DispatchQueue.main.asyncAfter(deadline: .now() + LaunchOptions.smokeSeconds) { [weak self] in self?.finishSmoke() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveCapsulePosition()
        watcher?.stop(); processProbe?.stop(); liveActivityProbe?.stop(); configuredConnectorProbe?.stop()
        addAgentPanel?.close()
        tickTimer?.invalidate(); soakTimer?.invalidate(); soakCPUTimer?.invalidate()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        attentionPanel?.orderOut(nil)
    }

    private func installCapsule() {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: capsuleWidth(), height: capsuleHeight()))
        let origin = PositionStore.load() ?? defaultOrigin(width: panel.frame.width, height: panel.frame.height)
        panel.setFrameOrigin(origin)
        let host = CapsuleHostingView(rootView: CapsuleView(store: store))
        host.onClick = { [weak self] in self?.toggleDetail() }
        host.onDragEnd = { [weak self] in
            self?.saveCapsulePosition()
            self?.layoutDetailPanel()
            self?.layoutAttentionPanel()
        }
        host.onRightClick = { [weak self] event in self?.showCapsuleMenu(with: event) }
        panel.contentView = host
        panel.orderFrontRegardless()
        capsulePanel = panel; capsuleHost = host
        groupsCancellable = store.$groups.sink { [weak self] _ in
            self?.resizeCapsule()
            if self?.isDetailVisible == true { self?.layoutDetailPanel() }
            self?.layoutAttentionPanel()
        }
        attentionCancellable = store.$attentionTask.sink { [weak self] task in
            guard let self, let task else { return }
            self.showAttention(for: task)
        }
    }

    private func capsuleWidth() -> CGFloat {
        let rows = Array(store.capsuleTasks.prefix(3))
        return CapsuleMetrics.width(for: rows, extraCount: max(0, store.capsuleTasks.count - rows.count))
    }

    private func capsuleHeight() -> CGFloat {
        let rows = Array(store.capsuleTasks.prefix(3))
        let count = rows.isEmpty ? 0 : rows.count + (store.capsuleTasks.count > rows.count ? 1 : 0)
        return CapsuleMetrics.height(rowCount: count)
    }

    private func defaultOrigin(width: CGFloat, height: CGFloat) -> CGPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: visible.midX - width / 2, y: visible.maxY - height - 2)
    }

    private func resizeCapsule() {
        guard let panel = capsulePanel else { return }
        let newSize = CGSize(width: capsuleWidth(), height: capsuleHeight())
        guard abs(panel.frame.width - newSize.width) >= 1 || abs(panel.frame.height - newSize.height) >= 1 else { return }
        var frame = panel.frame; let top = frame.maxY
        frame.size = newSize; frame.origin.y = top - newSize.height
        panel.setFrame(frame, display: true)
        layoutDetailPanel()
        layoutAttentionPanel()
    }

    private func saveCapsulePosition() { if let panel = capsulePanel { PositionStore.save(panel.frame.origin) } }

    private func installDetailPanel() {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width, height: PanelLayout.height(groups: store.groups)))
        panel.contentView = NSHostingView(rootView: DetailView(store: store, onAddAgent: { [weak self] in self?.showAddAgentPanel() }, onOpenTask: { TerminalLauncher.open() }))
        panel.orderOut(nil); detailPanel = panel
    }

    /// 显示“需要二次确认”的应用内提醒。提醒只说明任务并提供回到 Agent 的入口，
    /// 不在看板内替用户批准任何操作。
    private func showAttention(for task: TaskItem) {
        let content = AttentionView(
            task: task,
            onOpenAgent: { [weak self] in
                AgentLauncher.open(for: task.agentKey)
                self?.dismissAttention()
            },
            onDismiss: { [weak self] in self?.dismissAttention() }
        )

        if let panel = attentionPanel {
            panel.contentView = NSHostingView(rootView: content)
            layoutAttentionPanel()
            panel.orderFrontRegardless()
            return
        }

        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 190))
        panel.contentView = NSHostingView(rootView: content)
        attentionPanel = panel
        layoutAttentionPanel()
        panel.orderFrontRegardless()
    }

    private func layoutAttentionPanel() {
        guard let capsule = capsulePanel, let panel = attentionPanel else { return }
        var frame = panel.frame
        frame.origin.x = capsule.frame.midX - frame.width / 2
        frame.origin.y = capsule.frame.minY - 12 - frame.height
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = max(frame.origin.y, visible.minY + 8)
        panel.setFrame(frame, display: true)
    }

    private func dismissAttention() {
        attentionPanel?.orderOut(nil)
        store.dismissAttention()
    }

    private func layoutDetailPanel() {
        guard let capsule = capsulePanel, let detail = detailPanel else { return }
        var frame = detail.frame
        frame.size.height = PanelLayout.height(groups: store.groups)
        frame.origin.x = capsule.frame.midX - PanelLayout.width / 2
        frame.origin.y = capsule.frame.minY - 10 - frame.height
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = max(frame.origin.y, visible.minY + 8)
        detail.setFrame(frame, display: true)
    }

    private func toggleDetail() {
        guard let capsule = capsulePanel, let detail = detailPanel else { return }
        if isDetailVisible { detail.orderOut(nil); isDetailVisible = false }
        else { layoutDetailPanel(); detail.makeKeyAndOrderFront(nil); isDetailVisible = true }
        capsule.orderFrontRegardless()
    }

    private func installMonitors() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in Task { @MainActor in self?.handleOutsideClick() } }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.closeDetail() }; return nil }
            return event
        }
    }

    private func handleOutsideClick() {
        guard isDetailVisible, let capsule = capsulePanel, let detail = detailPanel else { return }
        let point = NSEvent.mouseLocation
        guard !capsule.frame.contains(point), !detail.frame.contains(point) else { return }
        detail.orderOut(nil); isDetailVisible = false
    }
    private func closeDetail() { if isDetailVisible { detailPanel.orderOut(nil); isDetailVisible = false } }

    private func startWatching() {
        watcher = TaskFileWatcher(path: store.dataPath) { [weak self] in Task { @MainActor [weak self] in self?.handleFileChange() } }
        watcher?.start()
    }
    private func handleFileChange() { store.reload(); resizeCapsule(); if isDetailVisible { layoutDetailPanel() } }

    private func startProcessProbe() {
        processProbe = ProcessProbe { [weak self] current, ended in
            self?.store.applyProcessSnapshot(current: current, ended: ended)
            self?.resizeCapsule()
        }
        processProbe?.start()
    }

    private func startLiveActivityProbe() {
        liveActivityProbe = LiveActivityProbe { [weak self] current in
            let summary = current.map { "\($0.agentKey):\($0.id)" }.joined(separator: ",")
            print("[AgentIsland] live activities=\(current.count) \(summary)")
            self?.liveObservedTasks = current
            self?.publishObservedTasks()
            self?.resizeCapsule()
            if self?.isDetailVisible == true { self?.layoutDetailPanel() }
        }
        liveActivityProbe?.start()
    }

    private func startConfiguredConnectorProbe() {
        guard let manifest = ConnectorManifestLoader.load() else { return }
        configuredConnectorProbe = ConfiguredConnectorProbe(manifest: manifest) { [weak self] snapshot in
            let summary = snapshot.tasks.map { "\($0.agentKey):\($0.id):\($0.status.rawValue)" }.joined(separator: ",")
            let health = snapshot.health.map { "\($0.connectorID):\($0.state.rawValue)" }.joined(separator: ",")
            print("[AgentIsland] configured activities=\(snapshot.tasks.count) \(summary) health=\(health)")
            self?.configuredObservedTasks = snapshot.tasks
            self?.publishObservedTasks()
            self?.resizeCapsule()
            if self?.isDetailVisible == true { self?.layoutDetailPanel() }
        }
        configuredConnectorProbe?.start()
        print("[AgentIsland] configured connectors=\(manifest.connectors.filter(\.isEnabled).map(\.id).joined(separator: ","))")
    }

    private func reloadConfiguredConnectors() {
        configuredConnectorProbe?.stop()
        configuredConnectorProbe = nil
        configuredObservedTasks = []
        publishObservedTasks()
        startConfiguredConnectorProbe()
        resizeCapsule()
        if isDetailVisible { layoutDetailPanel() }
    }

    /// 保存表单提交的连接器；同一个 id 视为编辑已有配置。
    private func saveConnector(_ spec: ConnectorSpec) -> String? {
        var connectors = ConnectorManifestLoader.load()?.connectors ?? []
        if let index = connectors.firstIndex(where: { $0.id == spec.id }) {
            connectors[index] = spec
        } else {
            connectors.append(spec)
        }
        do {
            try ConnectorManifestLoader.save(ConnectorManifest(schemaVersion: 1, connectors: connectors))
            reloadConfiguredConnectors()
            addAgentPanel?.close()
            print("[AgentIsland] connector saved id=\(spec.id) path=\(ConnectorManifestLoader.configurationPath)")
            return nil
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
    }

    private func publishObservedTasks() {
        store.applyObservedSnapshot(liveObservedTasks + configuredObservedTasks)
    }

    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isDetailVisible else { return }
            self.store.refreshClock()
        }
    }

    private func startSoak() {
        soakStartedAt = Date(); soakTick = 0; soakCPUSamples.removeAll()
        soakTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.soakStep() }
        soakCPUTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sampleSoakCPU() }
        DispatchQueue.main.asyncAfter(deadline: .now() + LaunchOptions.soakSeconds) { [weak self] in self?.finishSoak() }
    }

    private func soakStep() {
        soakTick += 1
        let all = (0..<8).map { i in ProcessTask(id: "soak-\(i)", pid: Int32(9000 + i), agentKey: i.isMultiple(of: 2) ? "codex" : "claude", title: "soak task \(i)", command: "soak", startedAt: soakStartedAt.addingTimeInterval(-Double(i))) }
        let current = all.filter { (soakTick + Int($0.pid)) % 6 != 0 }
        let ids = Set(current.map { $0.id })
        let ended = all.filter { !ids.contains($0.id) }
        store.applyProcessSnapshot(current: current, ended: ended)
        store.refreshClock(); resizeCapsule()
    }

    private func sampleSoakCPU() {
        let pid = ProcessInfo().processIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps"); process.arguments = ["-p", String(pid), "-o", "%cpu="]
            let pipe = Pipe(); process.standardOutput = pipe
            try? process.run(); process.waitUntilExit()
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            DispatchQueue.main.async { self?.soakCPUSamples.append(value) }
        }
    }

    private func finishSoak() {
        soakTimer?.invalidate(); soakCPUTimer?.invalidate()
        let average = soakCPUSamples.isEmpty ? 0 : soakCPUSamples.reduce(0, +) / Double(soakCPUSamples.count)
        let code = average < 2 ? 0 : 1
        print("[AgentIsland] soak finished seconds=\(Int(Date().timeIntervalSince(soakStartedAt))) samples=\(soakCPUSamples.count) avgCPU=\(String(format: "%.2f", average)) exit=\(code)")
        Darwin.exit(Int32(code))
    }

    private func showCapsuleMenu(with event: NSEvent) {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开 tasks.jsonl", action: #selector(openDataFile), keyEquivalent: ""); open.target = self; menu.addItem(open)
        let reload = NSMenuItem(title: "立即重新读取", action: #selector(reloadNow), keyEquivalent: "r"); reload.target = self; menu.addItem(reload)
        let reset = NSMenuItem(title: "复位胶囊到顶部居中", action: #selector(resetPosition), keyEquivalent: ""); reset.target = self; menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Agent Island", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: capsuleHost)
    }
    @objc private func openDataFile() { NSWorkspace.shared.open(URL(fileURLWithPath: store.dataPath)) }
    @objc private func reloadNow() { store.reload(); resizeCapsule() }
    @objc private func resetPosition() { guard let panel = capsulePanel else { return }; panel.setFrameOrigin(defaultOrigin(width: panel.frame.width, height: panel.frame.height)); saveCapsulePosition() }
    @objc private func quitApp() { saveCapsulePosition(); NSApp.terminate(nil) }

    private func showAddAgentPanel() {
        if let panel = addAgentPanel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = AddAgentPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 610))
        panel.contentView = NSHostingView(rootView: AddAgentView(
            onSave: { [weak self] spec in self?.saveConnector(spec) ?? "Agent Island 已退出" },
            onCancel: { [weak self] in self?.addAgentPanel?.close() }
        ))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        addAgentPanel = panel
    }
    private func finishSmoke() { saveCapsulePosition(); watcher?.stop(); processProbe?.stop(); liveActivityProbe?.stop(); configuredConnectorProbe?.stop(); print("[AgentIsland] 冒烟运行结束，退出码 0"); NSApp.terminate(nil) }
}
