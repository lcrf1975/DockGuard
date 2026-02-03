import SwiftUI
import AppKit
import ServiceManagement

@main
struct DockGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    
    // A janela agora é persistente, não a destruímos.
    var ghostWindow: NSWindow?
    
    // Controle de Debounce
    var refreshWorkItem: DispatchWorkItem?
    
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("isDebugMode") var isDebugMode: Bool = false
    
    let fallbackHeight: CGFloat = 70.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        setupMenuBar()
        
        // Autocorreção do Login
        if launchAtLogin { try? SMAppService.mainApp.register() }
        
        // Inicializa a janela uma única vez (vazia por enquanto)
        initGhostWindow()
        
        // Configura a tela com atraso
        scheduleBarrierUpdate(delay: 2.0)
        
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        
        checkPermissions()
        startGuardian()
    }
    
    // Cria a janela na memória uma vez só.
    func initGhostWindow() {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.ghostWindow = window
    }
    
    @objc func screenConfigChanged() {
        refreshWorkItem?.cancel()
        
        // Quando a tela muda, escondemos a barreira imediatamente para evitar conflitos visuais
        ghostWindow?.orderOut(nil)
        
        print("DockGuard: Screen layout changed. Updating...")
        scheduleBarrierUpdate(delay: 2.0)
    }
    
    func scheduleBarrierUpdate(delay: TimeInterval) {
        let task = DispatchWorkItem { [weak self] in
            self?.updateBarrierFrame()
        }
        self.refreshWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        
        if let originalIcon = NSImage(named: "MenuBarIcon") {
            let cleanIcon = resizeImage(image: originalIcon, w: 18, h: 18)
            cleanIcon.isTemplate = true
            button.image = cleanIcon
            button.imagePosition = .imageOnly
        } else {
            button.image = NSImage(systemSymbolName: "dock.arrow.up.rectangle", accessibilityDescription: "Dock Guard")
        }
        updateMenu()
    }
    
    func updateMenu() {
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "DockGuard", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())
        
        let debugItem = NSMenuItem(title: "Show Protected Area", action: #selector(toggleDebugClick), keyEquivalent: "d")
        debugItem.target = self
        debugItem.state = isDebugMode ? .on : .off
        menu.addItem(debugItem)
        
        menu.addItem(NSMenuItem.separator())
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchClick), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = launchAtLogin ? .on : .off
        menu.addItem(launchItem)
        
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }
    
    func resizeImage(image: NSImage, w: CGFloat, h: CGFloat) -> NSImage {
        let destSize = NSSize(width: w, height: h)
        let newImage = NSImage(size: destSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: destSize), from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
    
    // MARK: - Logic: Update Frame (REUSE instead of Recreate)
    func updateBarrierFrame() {
        let screens = NSScreen.screens
        
        // Validação básica
        guard screens.count >= 2,
              let mainScreen = screens.first,
              let secondaryScreen = screens.first(where: { $0 != mainScreen }),
              let window = ghostWindow else {
            // Se não tiver condições de proteger, esconde a janela
            ghostWindow?.orderOut(nil)
            return
        }
        
        // 1. Verificar se o Dock está no segundo monitor
        let bottomInset = secondaryScreen.visibleFrame.origin.y - secondaryScreen.frame.origin.y
        if bottomInset > 24 {
            print("DockGuard: Dock detected on secondary. Hiding barrier.")
            window.orderOut(nil) // Esconde a janela
            return
        }
        
        // 2. Calcular altura alvo
        var maxDockHeight: CGFloat = 0
        for screen in screens {
            let gap = screen.visibleFrame.origin.y - screen.frame.origin.y
            if gap > maxDockHeight { maxDockHeight = gap }
        }
        let targetHeight = maxDockHeight > 24 ? maxDockHeight : fallbackHeight
        
        // 3. Definir o Retângulo
        let newFrame = NSRect(
            x: secondaryScreen.frame.origin.x,
            y: secondaryScreen.frame.origin.y,
            width: secondaryScreen.frame.width,
            height: targetHeight
        )
        
        // 4. Validação Geométrica
        if !isSafeRect(newFrame) {
            window.orderOut(nil)
            return
        }
        
        // 5. ATUALIZAR A JANELA EXISTENTE (O segredo da estabilidade)
        // Em vez de recriar, apenas mudamos o frame e a cor.
        window.setFrame(newFrame, display: true)
        window.backgroundColor = isDebugMode ? NSColor.darkGray.withAlphaComponent(0.5) : NSColor.clear
        
        // Garante que ela está visível e na frente
        if !window.isVisible {
            window.orderFront(nil)
        }
        
        print("DockGuard: Barrier updated to \(newFrame)")
    }
    
    func isSafeRect(_ rect: NSRect) -> Bool {
        if rect.width.isNaN || rect.height.isNaN || rect.origin.x.isNaN || rect.origin.y.isNaN { return false }
        if rect.isInfinite || rect.isEmpty { return false }
        if rect.width <= 0 || rect.height <= 0 { return false }
        return true
    }
    
    // MARK: - Guardian
    func startGuardian() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            self.checkCollisions()
        }
    }
    
    func checkCollisions() {
        // Só processa se a janela estiver visível
        guard let ghost = ghostWindow, ghost.isVisible else { return }
        
        guard let mainScreen = NSScreen.screens.first else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        if frontApp.bundleIdentifier == "com.apple.finder" { return }
        
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedWindow: AnyObject?
        
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) != .success { return }
        guard let windowElement = focusedWindow as! AXUIElement? else { return }
        
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue)
        AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue)
        
        var pt = CGPoint.zero
        var sz = CGSize.zero
        if let pos = positionValue { AXValueGetValue(pos as! AXValue, .cgPoint, &pt) } else { return }
        if let s = sizeValue { AXValueGetValue(s as! AXValue, .cgSize, &sz) } else { return }
        
        let mainScreenHeight = mainScreen.frame.height
        let windowBottomY_AX = pt.y + sz.height
        let ghostVisualTop_Cocoa = ghost.frame.origin.y + ghost.frame.height
        let forbiddenLine_AX = mainScreenHeight - ghostVisualTop_Cocoa
        
        let windowCenterX = pt.x + (sz.width / 2)
        let isHorizontallyAligned = windowCenterX >= ghost.frame.minX && windowCenterX <= ghost.frame.maxX
        let overlap = windowBottomY_AX - forbiddenLine_AX
        
        if isHorizontallyAligned && overlap > 3.0 {
            let newHeight = sz.height - overlap
            if newHeight > 100 {
                var newSize = CGSize(width: sz.width, height: newHeight)
                if let sizeVal = AXValueCreate(.cgSize, &newSize) {
                    _ = AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeVal)
                }
            }
        }
    }
    
    @objc func toggleDebugClick() {
        isDebugMode.toggle()
        updateMenu()
        // Atualiza apenas a cor, sem destruir a janela
        if let window = ghostWindow, window.isVisible {
            window.backgroundColor = isDebugMode ? NSColor.darkGray.withAlphaComponent(0.5) : NSColor.clear
        }
    }
    
    @objc func toggleLaunchClick() {
        launchAtLogin.toggle()
        updateMenu()
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { print("Login Error: \(error)") }
    }
    
    @objc func quitApp() { NSApp.terminate(nil) }
    
    func checkPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
