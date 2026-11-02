using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
namespace TimesFrame.Core;
public sealed record UserSession(long UserId, string Token, string Email, string Nickname) {
    public JsonObject Fields() => new() { ["UserId"] = UserId, ["Token"] = long.TryParse(Token, out var n) ? JsonValue.Create(n) : JsonValue.Create(Token) };
}
public sealed record Clock(int Id, string Name) { public override string ToString() => $"{Name} · #{Id}"; }
public static class CloudClient {
    public static async Task<JsonObject> Request(string path, JsonObject fields, CancellationToken ct = default) {
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        using var content = new StringContent(fields.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await client.PostAsync("https://appin.divoom-gz.com/" + path, content, ct); response.EnsureSuccessStatusCode();
        var root = Json.Parse(await response.Content.ReadAsStringAsync(ct));
        if (root.Int("ReturnCode", -1) != 0) throw new FrameException("Divoom 云端：" + root.Str("ReturnMessage", "请求失败，请重新登录。")); return root;
    }
    public static async Task<UserSession> Login(string email, string password, CancellationToken ct = default) {
        email = email.Trim(); if (email.Length == 0 || password.Length == 0) throw new FrameException("请输入邮箱与密码。");
        var root = await Request("UserLogin", new() { ["Email"] = email, ["Password"] = Convert.ToHexStringLower(MD5.HashData(Encoding.UTF8.GetBytes(password))) }, ct);
        if (!long.TryParse(root.Str("UserId"), out var id) || id <= 0 || root.Str("Token").Length == 0) throw new FrameException("登录响应缺少会话凭据。");
        return new(id, root.Str("Token"), email, root.Str("Nickname", email));
    }
    public static async Task<List<Clock>> Clocks(int deviceId, UserSession? session, CancellationToken ct = default) {
        var result = new Dictionary<int, Clock>();
        for (var page = 0; page < 30; page++) {
            var fields = session?.Fields() ?? new JsonObject(); fields["DeviceId"] = deviceId; fields["DeviceType"] = "Frame"; fields["StartNum"] = page * 100 + 1; fields["EndNum"] = (page + 1) * 100;
            var root = await Request("Channel/MyClockGetList", fields, ct);
            if (root["ClockList"] is not JsonArray rows) throw new FrameException("云端没有返回表盘列表。");
            var added = 0; foreach (var row in rows.OfType<JsonObject>()) if (result.TryAdd(row.Int("ClockId"), new(row.Int("ClockId"), row.Str("ClockName")))) added++;
            if (rows.Count < 100) return result.Values.ToList();
            if (added == 0) throw new FrameException("云端重复返回同一页。");
        }
        throw new FrameException("云端列表过大。");
    }
}
