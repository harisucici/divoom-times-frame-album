import AppKit
import Foundation

final class DialMock: URLProtocol {
    static var hardware = 510
    static var managed: [String: Any]?
    static var failure: String?
    static var writes = [[String: Any]]()
    static var routes = [String]()
    static var lastBody = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        var object: [String: Any]
        let path = request.url!.path
        Self.routes.append(path)
        if path != "/divoom_api" {
            Self.lastBody = data
            let start = data.range(of: Data("\r\n\r\n".utf8))!.upperBound
            let end = data.range(of: Data("\r\n--".utf8), in: start..<data.endIndex)!.lowerBound
            object = try! JSONSerialization.jsonObject(with: data[start..<end]) as! [String: Any]
        } else { object = try! JSONSerialization.jsonObject(with: data) as! [String: Any] }
        let command = object["Command"] as? String ?? ""
        var result: [String: Any] = ["ReturnCode": 0]
        switch command {
        case "Device/GetHardwareVersion": result["Hardware"] = Self.hardware
        case "Device/GetLocalFontList": result["FontList"] = [["id": 26]]
        case "Device/GetLocalClockInfo":
            if let failure = Self.failure { result = ["ReturnCode": 2, "ReturnMessage": failure] }
            else if let managed = Self.managed { result.merge(managed) { _, new in new } }
            else { result = ["ReturnCode": 1, "ReturnMessage": "no local sys clock file for ClockId 60000"] }
        case "Device/CreateLocalClock", "Device/PatchLocalClockInfo":
            Self.writes.append(object)
            if let items = object["ItemList"] { Self.managed = ["ClockId": 60000, "ItemList": items, "ItemIdList": object["ItemIdList"] ?? []] }
            if let patches = object["ItemPatchList"] as? [[String: Any]], var rows = Self.managed?["ItemList"] as? [[String: Any]] {
                for patch in patches { let index = patch["index"] as! Int; rows[index].merge(patch["patch"] as! [String: Any]) { _, new in new } }
                Self.managed?["ItemList"] = rows
            }
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
    static func reset() { hardware = 510; managed = nil; failure = nil; writes = []; routes = []; lastBody = Data() }
}

@main struct WatchfaceRegression {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
    static func rejects(_ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Expected operation to fail") } catch { }
    }
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DialMock.self]
        let service = WatchfaceService(api: try AlbumAPI(ip: "127.0.0.1", session: URLSession(configuration: config)))
        let draft = try FrameCatalog.object("example-minimal.json")
        let asset = DialAsset(data: Data([0xff,0xd8,0xff,0xd9]), bundle: false, sourceName: "test.jpg")
        DialMock.reset()
        await rejects { _ = try await service.upsert(draft, asset: asset, name: "Test", requireExisting: true) }
        expect(DialMock.writes.isEmpty, "missing slot must not accept update")
        DialMock.hardware = 530
        await rejects { _ = try await service.upsert(draft, asset: asset, name: "Test", requireExisting: false) }
        expect(DialMock.writes.isEmpty, "AstroToo must be rejected")
        DialMock.reset(); DialMock.failure = "database busy"
        await rejects { _ = try await service.upsert(draft, asset: asset, name: "Test", requireExisting: false) }
        expect(DialMock.writes.isEmpty, "unknown state is not a missing slot")
        DialMock.reset()
        _ = try await service.upsert(draft, asset: asset, name: "Test", requireExisting: false)
        expect(DialMock.writes.count == 1 && DialMock.routes.contains("/create_local_clock"), "new slot uses dedicated create route")
        expect((DialMock.writes[0]["ClockId"] as? Int) == 60000, "managed slot enforced")
        let body = String(decoding: DialMock.lastBody, as: UTF8.self)
        expect(body.contains("name=\"json\"; filename=\"cmd.json\"") && body.contains("Content-Length:"), "multipart headers")
        expect(body.range(of: "cmd.json")!.lowerBound < body.range(of: "clock_bg.jpg")!.lowerBound, "JSON part comes first")
        var modified = draft
        var items = draft["ItemList"] as! [[String: Any]]; items[0]["size"] = 64; modified["ItemList"] = items
        _ = try await service.upsert(modified, asset: nil, name: "Test", requireExisting: true)
        let patch = DialMock.writes.last!
        expect(patch["ItemList"] == nil && patch["ItemIdList"] == nil, "same row count sends field diff")
        let fields = (patch["ItemPatchList"] as! [[String: Any]])[0]["patch"] as! [String: Any]
        expect(fields["item_id"] == nil && fields["size"] as? Int == 64, "stable IDs preserved")
        let writeCount = DialMock.writes.count
        items[0]["font"] = 999999; modified["ItemList"] = items
        await rejects { _ = try await service.upsert(modified, asset: nil, name: "Test", requireExisting: true) }
        expect(DialMock.writes.count == writeCount, "uninstalled font rejected")
        await rejects { _ = try await service.upsert(["ItemPatchList": [["index": 99, "patch": ["x": 10]]]], asset: nil, name: "Test", requireExisting: true) }
        expect(DialMock.writes.count == writeCount, "out-of-range patch rejected")
        await rejects { _ = try await service.replaceBackground(DialAsset(data: Data(), bundle: true, sourceName: "bundle"), clockID: 60000) }
        print("PASS watchface: hardware gate, missing/unknown states, managed slot, JSON-first multipart, font validation, minimal patches, stable IDs, patch bounds")

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("DialAsset-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: fixture)
        let prepared = try DialAsset.load(fixture)
        let result = NSBitmapImageRep(data: prepared.data)!
        expect(!prepared.bundle && result.pixelsWide == 800 && result.pixelsHigh == 1280 && prepared.data.count < 500 * 1024,
               "background converts to firmware dimensions and size")
        print("PASS asset preparation: PNG to 800x1280 JPEG under 500 KiB")

        let templates = try FrameCatalog.object("templates-curated.json")["templates"] as! [[String: Any]]
        var valid = 0
        for template in templates {
            let draft = FrameCatalog.draft(template["watchface"] as! [String: Any])
            if (draft["ItemList"] as? [Any])?.isEmpty == true {
                await rejects { _ = try WatchfaceService.configuration(draft, complete: true) }
            } else { _ = try WatchfaceService.configuration(draft, complete: true); valid += 1 }
        }
        expect(templates.count == 20 && valid == 19, "official catalog: 19 complete drafts and one backdrop-only reference")
        let suggestion = try FrameCatalog.layout(disp: 5)
        expect(suggestion["suggestedItemFields"] != nil, "layout suggestion from official medians")
        print("PASS offline catalogs: 19 templates normalize to valid IDs, backdrop-only template rejected; layout guidance reads official typography")
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--read-live"), arguments.indices.contains(index+1) {
            let live = WatchfaceService(api: try AlbumAPI(ip: arguments[index+1]))
            let hardware = try await live.identify()
            let fonts = try await live.api.command("Device/GetLocalFontList")
            let market = try await live.api.command("Device/GetStoreClockMarketList")
            let managed = try await live.managed()
            let screenshot = try await live.snapshot()
            expect(NSImage(data: screenshot) != nil, "live screenshot decodes")
            print("PASS LIVE READ: Hardware \(hardware["Hardware"]!), fonts \((fonts["FontList"] as? [Any])?.count ?? 0), market cache \((market["MarketClockList"] as? [Any])?.count ?? 0), managed slot \(managed == nil ? "absent" : "present"), screenshot \(screenshot.count) bytes")
        }
    }
}
