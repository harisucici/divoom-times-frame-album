using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using SkiaSharp;
using TimesFrame.Core;
static class Tests
{
    static void Check(bool ok, string message)
    {
        if (!ok)
            throw new Exception(message);
    }
    static async Task Reject(Func<Task> work)
    {
        try
        {
            await work();
        }
        catch { return; }
        throw new Exception("Expected rejection");
    }
    static string Fixture(string path, int width, int height, bool transparent = false)
    {
        using var bitmap = new SKBitmap(width, height);
        bitmap.Erase(transparent ? SKColors.Transparent : SKColors.CornflowerBlue);
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        File.WriteAllBytes(path, data.ToArray());
        return path;
    }
    public static async Task<int> Main(string[] args)
    {
        var directory = Path.Combine(Path.GetTempPath(), "TimesFrameTests-" + Guid.NewGuid());
        Directory.CreateDirectory(directory);
        try
        {
            var image = Fixture(Path.Combine(directory, "透明图片.png"), 2500, 1200, true);
            var encoded = ImageTools.Encode(image);
            Check(encoded.Width == 2048 && encoded.Height == 983, "actual pixel scaling");
            using (var decoded = SKBitmap.Decode(encoded.Bytes))
            {
                Check(decoded.GetPixel(0, 0).Red > 250 && decoded.GetPixel(0, 0).Alpha == 255, "transparent image flattened white");
            }
            var bg = ImageTools.Encode(image, true);
            Check(bg.Width == 800 && bg.Height == 1280 && bg.Bytes.Length < 500 * 1024, "background format bounds");
            using (var bitmap = new SKBitmap(100, 50))
            {
                bitmap.Erase(SKColors.Red);
                using var sk = SKImage.FromBitmap(bitmap);
                using var jpeg = sk.Encode(SKEncodedImageFormat.Jpeg, 90);
                var raw = jpeg.ToArray();
                byte[] exif = [0xff, 0xe1, 0, 34, 0x45, 0x78, 0x69, 0x66, 0, 0, 0x49, 0x49, 0x2a, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0];
                var rotated = Path.Combine(directory, "rotate.jpg");
                File.WriteAllBytes(rotated, raw[..2].Concat(exif).Concat(raw[2..]).ToArray());
                var result = ImageTools.Encode(rotated);
                Check(result.Width == 50 && result.Height == 100, "EXIF orientation honored");
            }
            Console.WriteLine("PASS images: JPEG encoding, pixel dimensions, transparent white, background size and EXIF rotation");
            using var handler = new MockHandler();
            using var http = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
            using var frame = new FrameClient("127.0.0.1", 9000, 123, http);
            var album = new Album(800123, "Test", 0);
            await frame.Identify();
            Check((await frame.Albums()).Count == 1, "albums read");
            Check(handler.Commands.SequenceEqual(new[] { "Device/GetHardwareVersion", "Photo/GetLocalAlbumList" }), "local connection uses no cloud");
            await Reject(() => Task.Run(() => frame.MediaUri("https://example.com/image")));
            await Reject(() => Task.Run(() => frame.MediaUri("/userdata/../secret")));
            await Reject(() => Task.Run(() => new FrameClient("127.00.0.1")));
            var broken = Path.Combine(directory, "broken.jpg");
            File.WriteAllText(broken, "broken");
            await Reject(() => frame.Upload(album, [image, broken], p => Task.FromResult(ImageTools.Encode(p))));
            Check(handler.Uploads.Count == 0, "preflight failure sends no partial upload");
            await frame.Upload(album, [image, image], p => Task.FromResult(ImageTools.Encode(p)));
            Check(handler.Uploads.Count == 2, "two uploads");
            var first = handler.Uploads[0];
            var second = handler.Uploads[1];
            Check(first.Int("PhotoFlag") == second.Int("PhotoFlag") && second.Int("PhotoIndex") == 1 && second.Int("PhotoTotalCnt") == 2 && first.Int("UserId") == 123, "batch and owner metadata");
            Check(Encoding.UTF8.GetString(handler.LastBody).Contains("Content-Length:"), "multipart lengths");
            handler.Full = true;
            var encodeCalls = 0;
            await Reject(() => frame.Upload(album, [image], p => { encodeCalls++; return Task.FromResult(ImageTools.Encode(p)); }));
            Check(encodeCalls == 0, "capacity guard runs before conversion");
            handler.Full = false;
            var deletes = handler.Commands.Count(c => c == "Photo/DeletePhoto");
            await frame.DeletePhotos(album, Enumerable.Range(1, 13), false);
            Check(handler.Commands.Count(c => c == "Photo/DeletePhoto") == deletes + 2, "13 originals split into 10+3");
            Console.WriteLine("PASS albums: connection, strict paths, zero-write preflight, batch metadata, capacity and deletion chunks");
            var dial = new WatchfaceClient(frame);
            var config = Json.Parse("""{"ClockId":99,"ItemList":[{"item_id":"time","disp":5,"font":26,"size":56}],"ItemIdList":["time"]}""");
            var asset = new DialAsset(encoded.Bytes, false, "test.jpg");
            await Reject(() => dial.Upsert(config, asset, "Test", true));
            Check(handler.DialWrites.Count == 0, "missing slot rejects update");
            handler.Failure = "database busy";
            await Reject(() => dial.Upsert(config, asset, "Test", false));
            Check(handler.DialWrites.Count == 0, "unknown error is not absence");
            handler.Failure = null;
            handler.Hardware = 530;
            await Reject(() => dial.Upsert(config, asset, "Test", false));
            handler.Hardware = 510;
            var after = await dial.Upsert(config, asset, "Test", false);
            Check(after.Int("ClockId") == 60000 && handler.Routes.Contains("/create_local_clock"), "fixed managed slot and route");
            Check(Encoding.UTF8.GetString(handler.LastBody).Contains("filename=\"cmd.json\""), "dial metadata filename");
            config["ItemList"]![0]!["size"] = 64;
            await dial.Upsert(config, null, "Test", true);
            var patch = handler.DialWrites.Last();
            Check(patch["ItemList"] == null && patch["ItemPatchList"] is JsonArray, "minimal field diff");
            Check(patch["ItemPatchList"]![0]!["patch"]!["item_id"] == null, "stable IDs preserved");
            var writes = handler.DialWrites.Count;
            config["ItemList"]![0]!["font"] = 99999;
            await Reject(() => dial.Upsert(config, null, "Test", true));
            Check(handler.DialWrites.Count == writes, "uninstalled font rejected");
            await Reject(() => dial.Upsert(Json.Parse("""{"ItemPatchList":[{"index":99,"patch":{"x":1}}]}"""), null, "Test", true));
            Check(handler.DialWrites.Count == writes, "out-of-range patch rejected");
            Console.WriteLine("PASS watchfaces: hardware, missing/unknown state, managed slot, dedicated multipart, minimal patches, fonts and index bounds");
            var liveIndex = Array.IndexOf(args, "--read-live");
            if (liveIndex >= 0)
            {
                if (args.Length <= liveIndex + 1)
                    throw new Exception("--read-live <IPv4>");
                using var live = new FrameClient(args[liveIndex + 1]);
                var h = await live.Identify();
                var albums = await live.Albums();
                var fonts = await live.Command("Device/GetLocalFontList");
                var screenshot = await new WatchfaceClient(live).Snapshot();
                Check(screenshot.Length > 10, "live screenshot");
                Console.WriteLine($"PASS LIVE READ: hardware {h.Int("Hardware")}, firmware {h.Int("Software")}, {albums.Count} albums, {fonts.Rows("FontList").Count()} fonts, PNG screenshot {screenshot.Length} bytes");
            }
            var uploadIndex = Array.IndexOf(args, "--live-upload");
            if (uploadIndex >= 0)
            {
                if (args.Length <= uploadIndex + 1)
                    throw new Exception("--live-upload <IPv4>");
                using var live = new FrameClient(args[uploadIndex + 1]);
                await live.Identify();
                var test = await live.CreateAlbum("Windows验证-" + DateTimeOffset.UtcNow.ToUnixTimeSeconds());
                try
                {
                    await live.Upload(test, [image, image], p => Task.FromResult(ImageTools.Encode(p)));
                    var loaded = await live.Photos(test.Id);
                    Check(loaded.Count == 2, "live upload count");
                    Check(ImageTools.Png(await live.Download(loaded[0].Original)).Length > 0, "live original decodes");
                    await live.DeletePhotos(test, loaded.Select(p => p.Id), false);
                    await live.DeleteAlbum(test);
                    Console.WriteLine("PASS LIVE UPLOAD: temporary album, two converted images, list/download/decode, test originals and album removed");
                }
                catch
                {
                    try
                    {
                        var loaded = await live.Photos(test.Id);
                        if (loaded.Count > 0)
                            await live.DeletePhotos(test, loaded.Select(p => p.Id), false);
                        await live.DeleteAlbum(test);
                    }
                    catch (Exception cleanup) { Console.Error.WriteLine("Test album cleanup requires review: " + test.Id + " " + cleanup.Message); }
                    throw;
                }
            }
            Console.WriteLine("All Windows core regression tests passed.");
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
        finally { Directory.Delete(directory, true); }
    }
    sealed class MockHandler : HttpMessageHandler
    {
        public List<string> Commands = []; public List<string> Routes = []; public List<JsonObject> Uploads = []; public List<JsonObject> DialWrites = []; public JsonObject? Managed; public string? Failure; public int Hardware = 510; public bool Full; public byte[] LastBody = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var path = request.RequestUri!.AbsolutePath;
            Routes.Add(path);
            var data = request.Content == null ? [] : await request.Content.ReadAsByteArrayAsync(ct);
            JsonObject input;
            if (path != "/divoom_api")
                LastBody = data;
            if (path == "/divoom_api")
                input = Json.Parse(Encoding.UTF8.GetString(data));
            else
            {
                var text = Encoding.UTF8.GetString(data);
                var start = text.IndexOf("\r\n\r\n", StringComparison.Ordinal) + 4;
                var end = text.IndexOf("\r\n--", start, StringComparison.Ordinal);
                input = Json.Parse(text[start..end]);
            }
            var command = input.Str("Command");
            Commands.Add(command);
            JsonObject value = new()
            {
                ["ReturnCode"] = 0
            };
            switch (command)
            {
                case "Device/GetHardwareVersion":
                    value["Hardware"] = Hardware;
                    value["Software"] = 510177;
                    break;
                case "Photo/GetLocalAlbumList":
                    value["AlbumList"] = new JsonArray(new JsonObject { ["ClockId"] = 800123, ["ClockName"] = "Test", ["AlbumType"] = 0 });
                    break;
                case "Photo/GetPhotoList":
                    var count = Full ? 100 : Uploads.Count;
                    value["PhotoList"] = new JsonArray(Enumerable.Range(1, count).Select(i => (JsonNode?)new JsonObject { ["PhotoId"] = i }).ToArray());
                    break;
                case "Photo/LocalAddToAlbum":
                    Uploads.Add(input);
                    break;
                case "Photo/DeletePhoto":
                    Uploads.Clear();
                    break;
                case "Device/GetLocalFontList":
                    value["FontList"] = new JsonArray(new JsonObject { ["id"] = 26 });
                    break;
                case "Device/GetLocalClockInfo":
                    if (Failure != null)
                        value = new()
                        {
                            ["ReturnCode"] = 2,
                            ["ReturnMessage"] = Failure
                        };
                    else if (Managed != null)
                    {
                        value = Managed.DeepClone().AsObject();
                        value["ReturnCode"] = 0;
                    }
                    else
                        value = new()
                        {
                            ["ReturnCode"] = 1,
                            ["ReturnMessage"] = "no local sys clock file for ClockId 60000"
                        };
                    break;
                case "Device/CreateLocalClock":
                case "Device/PatchLocalClockInfo":
                    DialWrites.Add(input);
                    if (input["ItemList"] is JsonArray items)
                        Managed = new()
                        {
                            ["ClockId"] = 60000,
                            ["ItemList"] = items.DeepClone(),
                            ["ItemIdList"] = input["ItemIdList"]?.DeepClone()
                        };
                    if (input["ItemPatchList"] is JsonArray patches && Managed?["ItemList"] is JsonArray rows)
                    foreach (var patch in patches.OfType<JsonObject>())
                    foreach (var p in patch["patch"]!.AsObject())
                        rows[patch.Int("index")]![p.Key] = p.Value?.DeepClone();
                    break;
            }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(value.ToJsonString(), Encoding.UTF8, "application/json") };
        }
    }
}
