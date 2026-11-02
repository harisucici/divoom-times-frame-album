using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

namespace TimesFrame.Core;
public sealed record Album(int Id, string Name, int Type) { public bool Editable => Type == 0; public override string ToString() => Name + (Editable ? "" : " 🔒"); }
public sealed record Photo(int Id, string Thumbnail, string Original, string MediaType);
public sealed record Device(string Name, string Ip) { public override string ToString() => $"{Name} · {Ip}"; }
public sealed record EncodedImage(byte[] Bytes, int Width, int Height);
public sealed class FrameException(string message) : Exception(message);
public sealed class DeviceException(int code, string message) : Exception($"设备错误 {code}：{message}") { public int Code { get; } = code; public string DeviceMessage { get; } = message; }
public static class Json {
    public static int Int(this JsonObject obj, string key, int fallback = 0) => int.TryParse(obj[key]?.ToString(), out var n) ? n : fallback;
    public static string Str(this JsonObject obj, string key, string fallback = "") => obj[key]?.ToString() ?? fallback;
    public static IEnumerable<JsonObject> Rows(this JsonObject obj, string key) => obj[key] is JsonArray a ? a.OfType<JsonObject>() : [];
    public static JsonObject Parse(string text) => JsonNode.Parse(text) as JsonObject ?? throw new FrameException("需要 JSON 对象。");
    public static string Pretty(JsonNode? node) => node?.ToJsonString(new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) ?? "{}";
}
public sealed class FrameClient : IDisposable {
    public const int Capacity = 100;
    public string Ip { get; }
    public int Port { get; }
    public long UserId { get; }
    private readonly HttpClient http;
    private readonly bool owns;
    public Uri Root => new($"http://{Ip}:{Port}/");
    public static HttpClient CreateLocalHttp() => new(new SocketsHttpHandler { UseProxy = false, ConnectTimeout = TimeSpan.FromSeconds(8), MaxConnectionsPerServer = 6 }) { Timeout = Timeout.InfiniteTimeSpan };
    public FrameClient(string ip, int port = 9000, long userId = 0, HttpClient? transport = null) {
        var parts = ip.Trim().Split('.');
        if (parts.Length != 4 || parts.Any(p => !byte.TryParse(p, out var n) || p != n.ToString()) || port is < 1 or > 65535) throw new FrameException("请输入有效的 IPv4 地址和端口。");
        Ip = ip.Trim(); Port = port; UserId = userId; http = transport ?? CreateLocalHttp(); owns = transport == null;
    }
    public async Task<JsonObject> Command(string name, JsonObject? fields = null, CancellationToken ct = default) {
        var body = fields?.DeepClone().AsObject() ?? new JsonObject(); body["Command"] = name; body["ReturnCode"] = 0;
        return await Post("divoom_api", Encoding.UTF8.GetBytes(body.ToJsonString()), "application/json; charset=utf-8", ct);
    }
    public async Task<JsonObject> Post(string path, byte[] bytes, string type, CancellationToken ct = default, int seconds = 20) {
        using var content = new ByteArrayContent(bytes); content.Headers.ContentType = MediaTypeHeaderValue.Parse(type);
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(Root, path)) { Content = content };
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(seconds));
        try {
            using var response = await http.SendAsync(request, deadline.Token);
            if (!response.IsSuccessStatusCode) throw new FrameException($"相框返回 HTTP {(int)response.StatusCode}。");
            var obj = Json.Parse(await response.Content.ReadAsStringAsync(deadline.Token));
            if (obj.Int("ReturnCode", -1) != 0) throw new DeviceException(obj.Int("ReturnCode", -1), obj.Str("ReturnMessage", "未知原因"));
            return obj;
        } catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new FrameException($"连接 {Ip}:{Port} 超时；检查 IP、相框电源、同一局域网和防火墙。"); }
        catch (HttpRequestException e) { throw new FrameException($"无法连接 {Ip}:{Port}：{e.Message}。请检查同一局域网、VPN 和防火墙。"); }
    }
    public async Task<JsonObject> Identify(CancellationToken ct = default) {
        var hardware = await Command("Device/GetHardwareVersion", ct: ct);
        if (hardware.Int("Hardware") is not (510 or 511 or 512)) throw new FrameException("当前设备不是 Times Frame 510／511／512。");
        return hardware;
    }
    public async Task<List<Album>> Albums(CancellationToken ct = default) {
        var value = await Command("Photo/GetLocalAlbumList", ct: ct);
        if (value["AlbumList"] is not JsonArray) throw new FrameException("设备未返回相册列表。");
        return value.Rows("AlbumList").Select(r => new Album(r.Int("ClockId"), r.Str("ClockName"), r.Int("AlbumType", -1))).ToList();
    }
    public async Task<List<Photo>> Photos(int albumId, int start = 1, CancellationToken ct = default) {
        var value = await Command("Photo/GetPhotoList", new() { ["ClockId"] = albumId, ["StartNum"] = start, ["EndNum"] = start + 99 }, ct);
        if (value["PhotoList"] is not JsonArray) throw new FrameException("设备未返回照片列表。");
        return value.Rows("PhotoList").Select(r => new Photo(r.Int("PhotoId"), r.Str("FileId"), r.Str("OriginalFileId"), r.Str("MediaType", "photo"))).ToList();
    }
    public async Task<List<Photo>> AllPhotos(int albumId, CancellationToken ct = default) {
        var result = new Dictionary<int, Photo>();
        for (var page = 0; page < 100; page++) {
            var next = await Photos(albumId, page * 100 + 1, ct);
            var added = 0; foreach (var p in next) if (result.TryAdd(p.Id, p)) added++;
            if (next.Count < 100) return result.Values.ToList();
            if (added == 0) throw new FrameException("设备重复返回同一页，停止读取以避免死循环。");
        }
        throw new FrameException("相册过大，无法读取全部照片。");
    }
    public Uri MediaUri(string path) {
        if (!path.StartsWith("/userdata/", StringComparison.Ordinal) || path.Contains("..") || path.Contains('?') || path.Contains('#') || path.Contains('\\') || path.Any(char.IsControl)) throw new FrameException("设备返回了无效的本地媒体路径。");
        return new Uri(Root, string.Join('/', path.Split('/').Select(Uri.EscapeDataString)));
    }
    public async Task<byte[]> Download(string path, CancellationToken ct = default) {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(90));
        using var request = new HttpRequestMessage(HttpMethod.Get, MediaUri(path)); request.Headers.CacheControl = new() { NoCache = true };
        using var response = await http.SendAsync(request, deadline.Token); response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsByteArrayAsync(deadline.Token);
    }
    private static string Name(string raw) {
        var name = raw.Trim(); if (name.Length == 0 || Encoding.UTF8.GetByteCount(name) > 63) throw new FrameException("名称须为 1–63 个 UTF-8 字节。"); return name;
    }
    private static void Editable(Album album) { if (!album.Editable) throw new FrameException("系统相册只读，请选择普通相册。"); }
    private static async Task Verify(Func<Task<bool>> read, CancellationToken ct, int attempts = 10) {
        for (var i = 0; i < attempts; i++) { if (await read()) return; await Task.Delay(500, ct); }
        throw new FrameException("设备已接收请求，但回读未确认结果。请刷新核对，避免重复操作。");
    }
    public async Task<Album> CreateAlbum(string raw, CancellationToken ct = default) {
        var name = Name(raw); var before = await Albums(ct);
        if (before.Any(a => a.Name.Equals(name, StringComparison.OrdinalIgnoreCase))) throw new FrameException("已有同名相册。");
        int id; do { id = Random.Shared.Next(800000, 900000); } while (before.Any(a => a.Id == id));
        await Command("Photo/NewAlbum", new() { ["ClockId"] = id, ["ClockName"] = name }, ct);
        Album? created = null;
        await Verify(async () => (created = (await Albums(ct)).FirstOrDefault(a => a.Id == id && a.Name == name && a.Editable)) != null, ct);
        return created!;
    }
    public async Task RenameAlbum(Album album, string raw, CancellationToken ct = default) {
        Editable(album); var name = Name(raw);
        await Command("Photo/RenameAlbum", new() { ["ClockId"] = album.Id, ["ClockName"] = name }, ct);
        await Verify(async () => (await Albums(ct)).Any(a => a.Id == album.Id && a.Name == name), ct);
    }
    public async Task DeleteAlbum(Album album, CancellationToken ct = default) {
        Editable(album); await Command("Photo/DeleteAlbum", new() { ["ClockId"] = album.Id }, ct);
        await Verify(async () => (await Albums(ct)).All(a => a.Id != album.Id), ct);
    }
    public async Task AddExisting(Album album, IEnumerable<int> selected, CancellationToken ct = default) {
        Editable(album); var current = await Photos(album.Id, ct: ct); var old = current.Select(p => p.Id).ToHashSet(); var ids = selected.Distinct().Where(id => !old.Contains(id)).ToArray();
        if (current.Count + ids.Length > Capacity) throw new FrameException("相册最多 100 张，剩余容量不足。");
        foreach (var batch in ids.Chunk(10)) await Command("Photo/DevicePhotoToAlbum", new() { ["ToClockId"] = album.Id, ["ParentItemId"] = 0, ["ParentClockId"] = 0, ["PhotoList"] = new JsonArray(batch.Select(id => (JsonNode?)JsonValue.Create(id)).ToArray()) }, ct);
        await Verify(async () => ids.All((await Photos(album.Id, ct: ct)).Select(p => p.Id).ToHashSet().Contains), ct);
    }
    public async Task DeletePhotos(Album album, IEnumerable<int> selected, bool removeOnly, CancellationToken ct = default) {
        Editable(album); var ids = selected.Distinct().ToArray(); if (ids.Length == 0) return;
        foreach (var batch in ids.Chunk(10)) await Command(removeOnly ? "Photo/RemovePhotoFromAlbum" : "Photo/DeletePhoto", new() { ["ClockId"] = album.Id, ["ParentItemId"] = 0, ["ParentClockId"] = 0, ["PhotoList"] = new JsonArray(batch.Select(id => (JsonNode?)JsonValue.Create(id)).ToArray()) }, ct);
        var all = removeOnly ? null : (await Albums(ct)).FirstOrDefault(a => a.Type == 1);
        await Verify(async () => {
            var remaining = (await AllPhotos(album.Id, ct)).Select(p => p.Id).ToHashSet();
            if (all != null) remaining.UnionWith((await AllPhotos(all.Id, ct)).Select(p => p.Id));
            return !ids.Any(remaining.Contains);
        }, ct);
    }
    public async Task Upload(Album album, IReadOnlyList<string> paths, Func<string, Task<EncodedImage>> encoder, Action<string>? progress = null, CancellationToken ct = default) {
        Editable(album); if (paths.Count == 0) return;
        var before = await Photos(album.Id, ct: ct);
        if (before.Count + paths.Count > Capacity) throw new FrameException($"相册最多 100 张，已有 {before.Count} 张，本次 {paths.Count} 张。");
        var directory = Path.Combine(Path.GetTempPath(), "TimesFrame-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        try {
            var prepared = new List<(string Path, int W, int H)>();
            for (var i = 0; i < paths.Count; i++) {
                ct.ThrowIfCancellationRequested(); progress?.Invoke($"准备 {i + 1}/{paths.Count}：{Path.GetFileName(paths[i])}");
                var image = await encoder(paths[i]); var stage = Path.Combine(directory, i + ".jpg");
                await File.WriteAllBytesAsync(stage, image.Bytes, ct); prepared.Add((stage, image.Width, image.Height));
            }
            var flag = Random.Shared.Next(1, int.MaxValue); var time = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            for (var i = 0; i < paths.Count; i++) {
                ct.ThrowIfCancellationRequested(); progress?.Invoke($"上传 {i + 1}/{paths.Count}：{Path.GetFileName(paths[i])}");
                var image = prepared[i]; var filename = $"win-{Guid.NewGuid():N}.jpg";
                var metadata = new JsonObject { ["Command"] = "Photo/LocalAddToAlbum", ["ReturnCode"] = 0, ["ClockId"] = album.Id,
                    ["ParentItemId"] = 0, ["ParentClockId"] = 0, ["UserId"] = UserId, ["PhotoX"] = 0, ["PhotoY"] = 0,
                    ["PhotoWidth"] = image.W, ["PhotoHeight"] = image.H, ["PhotoIndex"] = i, ["PhotoTotalCnt"] = paths.Count, ["PhotoFlag"] = flag,
                    ["SendTime"] = time + i, ["TakingTime"] = time + i, ["FileName"] = filename, ["PreviewFileName"] = "", ["PhotoTitle"] = Path.GetFileNameWithoutExtension(paths[i])[..Math.Min(100, Path.GetFileNameWithoutExtension(paths[i]).Length)] };
                var boundary = "TimesFrameWindows-" + Guid.NewGuid().ToString("N");
                var bytes = Multipart(metadata, await File.ReadAllBytesAsync(image.Path, ct), filename, boundary, false);
                if (bytes.Length > 100 * 1024 * 1024) throw new FrameException("图片超过 100 MB 固件限制。");
                await Post("upload", bytes, "multipart/form-data; boundary=" + boundary, ct, 90);
            }
            var old = before.Select(p => p.Id).ToHashSet();
            await Verify(async () => (await Photos(album.Id, ct: ct)).Count(p => !old.Contains(p.Id)) >= paths.Count, ct, 60);
        } finally { Directory.Delete(directory, true); }
    }
    public static byte[] Multipart(JsonObject metadata, byte[] file, string filename, string boundary, bool dial) {
        using var output = new MemoryStream();
        void Add(string text) => output.Write(Encoding.UTF8.GetBytes(text));
        if (filename.IndexOfAny(['\r', '\n', '"']) >= 0) throw new FrameException("无效的文件名。");
        var json = Encoding.UTF8.GetBytes(metadata.ToJsonString());
        Add($"--{boundary}\r\nContent-Disposition: form-data; name=\"json\"{(dial ? "; filename=\"cmd.json\"" : "")}\r\nContent-Type: application/json\r\nContent-Length: {json.Length}\r\n\r\n"); output.Write(json);
        Add($"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"{(dial ? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString() : "file")}\"; filename=\"{filename}\"\r\nContent-Type: {(dial ? "application/octet-stream" : "image/jpeg")}\r\nContent-Length: {file.Length}\r\n\r\n"); output.Write(file); Add($"\r\n--{boundary}--\r\n"); return output.ToArray();
    }
    public static async Task<List<Device>> Discover(CancellationToken ct = default) {
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        var root = Json.Parse(await client.GetStringAsync("https://app.divoom-gz.com/Device/ReturnSameLANDevice", ct));
        return root.Rows("DeviceList").Where(r => r.Int("Hardware") is 510 or 511 or 512).Select(r => new Device(r.Str("DeviceName", "Times Frame"), r.Str("DevicePrivateIP"))).ToList();
    }
    public void Dispose() { if (owns) http.Dispose(); }
}
