import AppKit
import WebKit

final class Renderer: NSObject, WKNavigationDelegate {
    let width: CGFloat = 1080
    let height: CGFloat = 1440
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    lazy var webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))

    func start() {
        webView.navigationDelegate = self
        webView.loadFileURL(directory.appendingPathComponent("cover.html"), allowingReadAccessTo: directory)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        configuration.snapshotWidth = NSNumber(value: Double(width))
        webView.takeSnapshot(with: configuration) { image, error in
            guard error == nil, let image,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                fputs("Could not render cover.html\n", stderr)
                exit(1)
            }
            do {
                try png.write(to: self.directory.appendingPathComponent("cover@2x.png"), options: .atomic)
                print("Rendered cover@2x.png")
                NSApp.terminate(nil)
            } catch {
                fputs("Could not write cover@2x.png: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer()
renderer.start()
app.run()
