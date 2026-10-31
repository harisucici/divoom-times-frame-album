import AppKit

@main struct Lifecycle {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = MainWindowObserver(frame: window.contentView!.bounds)
        window.contentView?.addSubview(observer)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            panel.close()
            print("PASS auxiliary panel close did not terminate application")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                print("Closing primary content window; process must terminate successfully")
                window.close()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            fputs("FAIL primary window closed but application is still resident\n", stderr)
            exit(2)
        }
        app.run()
    }
}
