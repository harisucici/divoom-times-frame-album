import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class MockProtocol: URLProtocol {
    static var commands = [String]()
    static var uploads = 0
    static var metadata = [[String: Any]]()
    static var bodies = [Data]()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var value: [String: Any] = ["ReturnCode": 0]
        var requestBody = request.httpBody
        if requestBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            requestBody = data
        }
        if request.url?.path == "/upload", let body = requestBody {
            Self.uploads += 1
            Self.bodies.append(body)
            let separator = Data("\r\n\r\n".utf8)
            let start = body.range(of: separator)!.upperBound
            let end = body.range(of: Data("\r\n--".utf8), in: start..<body.endIndex)!.lowerBound
            Self.metadata.append(try! JSONSerialization.jsonObject(with: body[start..<end]) as! [String: Any])
        } else if let body = requestBody,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let command = object["Command"] as? String {
            Self.commands.append(command)
            if command == "Device/GetHardwareVersion" {
                value["Hardware"] = 510; value["Software"] = 510177
            } else if command == "Photo/GetLocalAlbumList" {
                value["AlbumList"] = [["ClockId": 800123, "ClockName": "Test", "AlbumType": 0]]
            } else if command == "Photo/GetPhotoList" {
                value["PhotoList"] = (0..<Self.uploads).map { ["PhotoId": 900 + $0] }
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
    static func reset() { commands = []; uploads = 0; metadata = []; bodies = [] }
}

@main struct Regression {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func makeImage(_ url: URL, type: CFString = UTType.png.identifier as CFString, orientation: Int = 1) {
        let context = CGContext(data: nil, width: 2400, height: 1200, bitsPerComponent: 8, bytesPerRow: 2400 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        expect(CGImageDestinationFinalize(destination), "fixture write")
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameRegression-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = directory.appendingPathComponent("透明图片.png")
        makeImage(png)
        let encoded = try PhotoEncoder.encode(png)
        expect(encoded.width == 2048 && encoded.height == 1024, "pixel scaling")
        let jpeg = directory.appendingPathComponent("旋转.jpg")
        makeImage(jpeg, type: UTType.jpeg.identifier as CFString, orientation: 6)
        let rotated = try PhotoEncoder.encode(jpeg)
        expect(rotated.width == 1024 && rotated.height == 2048, "EXIF orientation")
        print("PASS encoder: pixel dimensions, JPEG conversion, orientation")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let api = try AlbumAPI(ip: "127.0.0.1", userID: 123, session: URLSession(configuration: config))
        let album = Album(id: 800123, name: "Test", type: 0)
        MockProtocol.reset()
        let state = try await api.connectionState()
        expect(state.albums.count == 1 && state.albums[0].id == album.id, "local connection returns albums")
        expect(MockProtocol.commands == ["Device/GetHardwareVersion", "Photo/GetLocalAlbumList"], "connection makes exactly two local requests")
        let lan = FrameNetwork.configuration()
        let first = FrameNetwork.configuration(waitForConnectivity: true, resourceTimeout: 25)
        expect(lan.connectionProxyDictionary?.isEmpty == true && !lan.waitsForConnectivity && lan.timeoutIntervalForResource >= 90, "LAN transfers bypass proxies and retain upload time budget")
        expect(first.waitsForConnectivity && first.timeoutIntervalForResource == 25, "first connection waits for permission with bounded timeout")
        let diagnostic = FrameNetwork.message(for: URLError(.notConnectedToInternet), target: "127.0.0.1:9000")
        expect(diagnostic.contains("本地网络") && diagnostic.contains("-1009") && diagnostic.contains("127.0.0.1:9000"), "offline failure has actionable local-network diagnostic")
        print("PASS connection: two local requests, proxy isolation, permission waiting, media timeout budget, -1009 diagnostic")
        MockProtocol.reset()
        let broken = directory.appendingPathComponent("损坏.jpg")
        try Data("broken".utf8).write(to: broken)
        do {
            try await api.upload([png, broken], to: album)
            fatalError("expected corrupt image rejection")
        } catch { expect(MockProtocol.uploads == 0, "failed preflight must send no uploads") }
        print("PASS preflight: second corrupt image causes zero uploads")
        MockProtocol.reset()
        try await api.upload([png, jpeg], to: album)
        expect(MockProtocol.uploads == 2, "batch upload count")
        let m = MockProtocol.metadata
        expect(m.count == 2 && m.allSatisfy { ($0["UserId"] as? Int) == 123 }, "account metadata")
        expect((m[0]["PhotoFlag"] as? Int) == (m[1]["PhotoFlag"] as? Int), "consistent batch")
        expect((m[1]["PhotoIndex"] as? Int) == 1 && (m[1]["PhotoTotalCnt"] as? Int) == 2, "batch indices")
        expect((m[1]["PhotoWidth"] as? Int) == 1024, "actual oriented upload width")
        expect(MockProtocol.bodies.allSatisfy { $0.range(of: Data("Content-Length:".utf8)) != nil }, "multipart lengths")
        print("PASS batch metadata, multipart, account owner and asynchronous verification")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = LibraryGridCanvas(frame: CGRect(x: 0, y: 0, width: 500, height: 1400))
        window.contentView = canvas
        canvas.entries = (0..<24).map { NativeLibraryEntry(id: $0) }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, command: Bool = false) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: x, y: y), to: nil),
                modifierFlags: command ? .command : [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func click(_ x: CGFloat, _ y: CGFloat, command: Bool = false) {
            canvas.mouseDown(with: event(.leftMouseDown, x, y, command: command))
            canvas.mouseUp(with: event(.leftMouseUp, x, y, command: command))
        }
        click(30, 30)
        expect(canvas.selection == [0], "single click")
        click(180, 30, command: true)
        expect(canvas.selection == [0,1], "command add")
        click(30, 30, command: true)
        expect(canvas.selection == [1], "command toggle")
        canvas.mouseDown(with: event(.leftMouseDown, 30, 30))
        canvas.mouseDragged(with: event(.leftMouseDragged, 330, 320))
        canvas.mouseUp(with: event(.leftMouseUp, 330, 320))
        expect(Set([0,1,2,3,4,5]).isSubset(of: canvas.selection), "drag from inside thumbnail")
        let before = canvas.selection
        canvas.mouseDown(with: event(.leftMouseDown, 5, 620))
        canvas.mouseDragged(with: event(.leftMouseDragged, 160, 770))
        canvas.mouseUp(with: event(.leftMouseUp, 160, 770))
        expect(before.isSubset(of: canvas.selection) && canvas.selection.contains(12), "later drag accumulates offscreen rows")
        canvas.isEnabled = false
        click(30,30)
        expect(canvas.selection.contains(12), "disabled grid cannot mutate selection")
        canvas.isEnabled = true
        var deleted = false
        canvas.deleteSelection = { deleted = true }
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!)
        expect(deleted, "delete key invokes confirmation callback")
        print("PASS native selection: click, command toggle, thumbnail drag, cross-row accumulation, disabled state, delete callback")

        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--live") {
            guard arguments.indices.contains(index + 1) else { throw FrameError.message("Usage: test.sh --live <IPv4>") }
            let live = try AlbumAPI(ip: arguments[index + 1])
            let hardware = try await live.command("Device/GetHardwareVersion")
            if let id = (hardware["DeviceId"] as? NSNumber)?.intValue {
                let clocks = try await DivoomCloud.clocks(deviceID: id, session: nil)
                expect(!clocks.isEmpty, "live cloud clocks")
                print("PASS LIVE cloud clock list: \(clocks.count) entries")
            }
            print(try await live.check())
            let test = try await live.createAlbum(named: "Mac验证-\(Int(Date().timeIntervalSince1970))")
            do {
                try await live.upload([png, jpeg], to: test)
                let photos = try await live.photos(albumID: test.id, start: 1)
                expect(photos.count == 2, "live upload count")
                let downloaded = try await live.download(photos[0])
                expect(CGImageSourceCreateWithData(downloaded as CFData, nil) != nil, "live original decode")
                try await live.delete(photos.map(\.id), from: test)
                try await live.deleteAlbum(test)
                print("PASS LIVE: create temporary album, upload PNG + EXIF JPEG, verify/download, delete test originals and album")
            } catch {
                if let photos = try? await live.photos(albumID: test.id, start: 1), !photos.isEmpty { try? await live.delete(photos.map(\.id), from: test) }
                try? await live.deleteAlbum(test)
                throw error
            }
        }
    }
}
