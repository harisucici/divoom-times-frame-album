using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using TimesFrame.Core;
namespace TimesFrame.Windows;

public static class CredentialVault
{
    const string Target = "TimesFrameAlbum/Divoom/ActiveSession";
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Credential
    {
        public uint Flags, Type; public string TargetName; public string? Comment; public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist, AttributeCount; public IntPtr Attributes; public string? TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Write(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Read(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Delete(string target, uint type, uint flags);
    [DllImport("advapi32.dll")] static extern void CredFree(IntPtr pointer);
    public static UserSession? Load()
    {
        if (!Read(Target, 1, 0, out var pointer))
            return null;
        try
        {
            var c = Marshal.PtrToStructure<Credential>(pointer);
            var bytes = new byte[c.CredentialBlobSize];
            Marshal.Copy(c.CredentialBlob, bytes, 0, bytes.Length);
            return JsonSerializer.Deserialize<UserSession>(bytes);
        }
        catch { return null; }
        finally { CredFree(pointer); }
    }
    public static void Save(UserSession session)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(session);
        var pointer = Marshal.AllocCoTaskMem(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, pointer, bytes.Length);
            var credential = new Credential { Type = 1, TargetName = Target, UserName = session.Email, Persist = 2, CredentialBlobSize = (uint)bytes.Length, CredentialBlob = pointer };
            if (!Write(ref credential, 0))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法保存 Windows 凭据。");
        }
        finally { Marshal.FreeCoTaskMem(pointer); }
    }
    public static void Clear()
    {
        if (!Delete(Target, 1, 0) && Marshal.GetLastWin32Error() != 1168)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "无法清除 Windows 凭据。");
    }
}
public static class AppState
{
    public static UserSession? Session = CredentialVault.Load();
    static string SettingsPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TimesFrameAlbum", "settings.json");
    public sealed record Connection(string Ip, int Port);
    static string Key => Session?.UserId.ToString() ?? "guest";
    public static Connection LoadConnection()
    {
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, Connection>>(File.ReadAllText(SettingsPath))?.GetValueOrDefault(Key) ?? new("", 9000);
        }
        catch { return new("", 9000); }
    }
    public static void SaveConnection(string ip, int port)
    {
        Dictionary<string, Connection> settings;
        try
        {
            settings = JsonSerializer.Deserialize<Dictionary<string, Connection>>(File.ReadAllText(SettingsPath)) ?? [];
        }
        catch { settings = []; }
        settings[Key] = new(ip, port);
        Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        var temp = SettingsPath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(settings));
        File.Move(temp, SettingsPath, true);
    }
}
