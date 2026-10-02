import AppKit
import SwiftUI

// MARK: - 悬浮面板

/// 通用悬浮面板：borderless + nonactivating，不抢焦点、不进 Dock
///
/// SPEC 陷阱提示：borderless NSPanel 默认不接受鼠标事件，
/// 因此这里 `canBecomeKey = true`（可接收点击）但配 `.nonactivatingPanel`（不激活 App）。
final class FloatingPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
    }
}

/// 添加 Agent 表单窗口：允许输入文本，但保持为 Agent Island 的辅助窗口。
final class AddAgentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "添加 Agent 接口"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.98)
    }
}

// MARK: - 可拖拽的 Hosting View

/// 承载 SwiftUI 的 NSHostingView 子类：自己接管「点击 / 拖动 / 右键」
///
/// - 拖动：用屏幕坐标做增量位移，避免窗口移动后窗口内坐标漂移
/// - 点击：拖动距离小于 3px 才算点击，避免拖动结束误触发展开
final class CapsuleHostingView<Content: View>: NSHostingView<Content> {

    /// 单击回调（点击胶囊 = 展开/收起面板）
    var onClick: (() -> Void)?
    /// 拖动结束回调（用于持久化位置）
    var onDragEnd: (() -> Void)?
    /// 右键回调（弹出菜单）
    var onRightClick: ((NSEvent) -> Void)?

    private var screenStart: NSPoint = .zero
    private var originStart: NSPoint = .zero
    private var isDragging = false
    private var movedDistance: CGFloat = 0

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        screenStart = NSEvent.mouseLocation
        originStart = window.frame.origin
        isDragging = true
        movedDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - screenStart.x
        let dy = current.y - screenStart.y
        movedDistance = max(movedDistance, hypot(dx, dy))
        window.setFrameOrigin(NSPoint(x: originStart.x + dx, y: originStart.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        if movedDistance < 3 {
            onClick?()
        } else {
            onDragEnd?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}
