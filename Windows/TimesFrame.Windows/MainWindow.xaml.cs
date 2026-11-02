using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using TimesFrame.Core;
namespace TimesFrame.Windows;

public sealed class PhotoCard(Photo photo) : INotifyPropertyChanged
{
    public Photo Photo { get; } = photo; public string Label => $"#{Photo.Id}"; ImageSource? thumbnail;
    public ImageSource? Thumbnail
    {
        get => thumbnail; set
        {
            thumbnail = value;
            PropertyChanged?.Invoke(this, new(nameof(Thumbnail)));
        }
    }
    public event PropertyChangedEventHandler? PropertyChanged;
}
public partial class MainWindow : Window
{
    FrameClient? frame; int? deviceId; bool busy, changing; CancellationTokenSource? operation; CancellationTokenSource thumbnails = new();
    readonly ObservableCollection<PhotoCard> cards = [];
    Album? Current => Albums.SelectedItem as Album;
    FrameClient Api => frame ?? throw new FrameException("请先连接设备。");
    public MainWindow()
    {
        InitializeComponent();
        Photos.ItemsSource = cards;
        LoadAccountAddress();
        Closing += (_, _) => { operation?.Cancel(); thumbnails.Cancel(); frame?.Dispose(); };
    }
    void LoadAccountAddress()
    {
        var saved = AppState.LoadConnection();
        Ip.Text = saved.Ip;
        Port.Text = saved.Port.ToString();
    }
    async Task Run(string label, Func<CancellationToken, Task> action)
    {
        if (busy)
            return;
        busy = true;
        Toolbar.IsEnabled = Body.IsEnabled = false;
        Cancel.IsEnabled = true;
        Progress.Visibility = Visibility.Visible;
        Status.Foreground = Brushes.DimGray;
        Status.Text = label;
        operation = new();
        try
        {
            await action(operation.Token);
        }
        catch (OperationCanceledException) { Status.Text = "操作已取消。已发送的写入可能已生效，请刷新确认。"; }
        catch (Exception e) { Status.Foreground = Brushes.Firebrick; Status.Text = e.Message; }
        finally { operation.Dispose(); operation = null; busy = false; Toolbar.IsEnabled = Body.IsEnabled = true; Cancel.IsEnabled = false; Progress.Visibility = Visibility.Collapsed; }
    }
    void Cancel_Click(object sender, RoutedEventArgs e) => operation?.Cancel();
    async void Discover_Click(object sender, RoutedEventArgs e) => await Run("正在查找同一出口网络的设备…", async ct => { Found.ItemsSource = await FrameClient.Discover(ct); Status.Text = Found.Items.Count == 0 ? "未发现设备，可手动输入局域网 IP。" : $"发现 {Found.Items.Count} 台设备，请选择后连接。"; });
    void Found_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (Found.SelectedItem is Device d)
            Ip.Text = d.Ip;
    }
    async void Connect_Click(object sender, RoutedEventArgs e) => await Run("正在连接相框…", async ct =>
    {
        if (!int.TryParse(Port.Text, out var port))
            throw new FrameException("端口必须是整数。");
        var candidate = new FrameClient(Ip.Text, port, AppState.Session?.UserId ?? 0);
        try
        {
            var info = await candidate.Identify(ct);
            var albums = await candidate.Albums(ct);
            thumbnails.Cancel();
            frame?.Dispose();
            frame = candidate;
            deviceId = info.Int("DeviceId");
            Connected.Text = $"已连接 {candidate.Ip}:{candidate.Port} · Times Frame {info.Int("Hardware")} · 固件 {info.Int("Software")}";
            AppState.SaveConnection(candidate.Ip, candidate.Port);
            SetAlbums(albums);
            Status.Text = "本地连接已建立。";
            try
            {
                await LoadPhotos(ct);
            }
            catch (Exception ex) { Status.Text = "已连接，但照片列表读取失败，请刷新重试：" + ex.Message; }
        }
        catch { if (frame != candidate) candidate.Dispose(); throw; }
    });
    void SetAlbums(List<Album> albums, int? desired = null)
    {
        changing = true;
        Albums.ItemsSource = albums;
        Albums.SelectedItem = albums.FirstOrDefault(a => a.Id == desired) ?? albums.FirstOrDefault(a => a.Editable) ?? albums.FirstOrDefault();
        changing = false;
    }
    async Task LoadPhotos(CancellationToken ct, bool all = false)
    {
        if (Current is not Album album)
        {
            ShowPhotos([]);
            return;
        }
        var photos = all ? await Api.AllPhotos(album.Id, ct) : await Api.Photos(album.Id, ct: ct);
        ShowPhotos(photos);
        AlbumTitle.Text = $"{album.Name} · {photos.Count} 张";
        Status.Text = $"已读取 {album.Name}：{photos.Count} 张。";
    }
    void ShowPhotos(IEnumerable<Photo> photos)
    {
        thumbnails.Cancel();
        thumbnails.Dispose();
        thumbnails = new();
        cards.Clear();
        foreach (var p in photos.DistinctBy(p => p.Id))
            cards.Add(new(p));
        _ = FillThumbnails(cards.ToArray(), thumbnails.Token);
    }
    async Task FillThumbnails(PhotoCard[] list, CancellationToken ct)
    {
        if (frame == null)
            return;
        var api = frame;
        using var limiter = new SemaphoreSlim(6);
        await Task.WhenAll(list.Select(async card => { try { await limiter.WaitAsync(ct); try { var data = await api.Download(card.Photo.Thumbnail, ct); ct.ThrowIfCancellationRequested(); card.Thumbnail = Ui.Image(data); } finally { limiter.Release(); } } catch { /* Placeholder remains until next refresh. */ } }));
    }
    async void Album_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (changing || busy || frame == null)
            return;
        await Run("正在读取相册…", ct => LoadPhotos(ct));
    }
    async void Refresh_Click(object sender, RoutedEventArgs e) => await Run("正在刷新本地相册…", async ct => { var albums = await Api.Albums(ct); SetAlbums(albums, Current?.Id); await LoadPhotos(ct); });
    async void More_Click(object sender, RoutedEventArgs e) => await Run("正在加载更多…", async ct => { var album = Current ?? throw new FrameException("请选择相册。"); var next = await Api.Photos(album.Id, cards.Count + 1, ct); var known = cards.Select(c => c.Photo.Id).ToHashSet(); var added = next.Where(p => known.Add(p.Id)).Select(p => new PhotoCard(p)).ToArray(); foreach (var p in added) cards.Add(p); _ = FillThumbnails(added, thumbnails.Token); Status.Text = added.Length == 0 ? "没有更多照片。" : $"已加载 {cards.Count} 张。"; });
    Album EditableAlbum()
    {
        var album = Current ?? throw new FrameException("请选择相册。");
        if (!album.Editable)
            throw new FrameException("请选择普通相册，系统相册只读。");
        return album;
    }
    async void NewAlbum_Click(object sender, RoutedEventArgs e)
    {
        if (frame == null)
        {
            Status.Text = "请先连接设备。";
            return;
        }
        var name = Ui.Ask(this, "新建设备本地相册", "只在设备本地创建，手机不会自动显示。手机可见的相册请先在手机 App 创建后刷新。");
        if (name == null)
            return;
        await Run("正在新建本地相册…", async ct => { var created = await Api.CreateAlbum(name, ct); SetAlbums(await Api.Albums(ct), created.Id); await LoadPhotos(ct); Status.Text = "已创建本地相册；尚未同步至手机。"; });
    }
    async void Rename_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not Album album || !album.Editable)
            return;
        var name = Ui.Ask(this, "本地重命名", "只更改设备本地名称，手机云端名称不会改变。", album.Name);
        if (name == null)
            return;
        await Run("正在重命名…", async ct => { await Api.RenameAlbum(album, name, ct); SetAlbums(await Api.Albums(ct), album.Id); Status.Text = "已在设备本地重命名。"; });
    }
    async void DeleteAlbum_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not Album album || !album.Editable)
            return;
        if (!Ui.Confirm(this, $"删除设备本地相册“{album.Name}”？不会删除手机云端记录；原图保留情况取决于固件。操作不能撤销。"))
            return;
        await Run("正在删除本地相册…", async ct => { await Api.DeleteAlbum(album, ct); SetAlbums(await Api.Albums(ct)); await LoadPhotos(ct); });
    }
    async Task UploadFiles(string[] files) => await Run("正在准备上传…", async ct => { var album = EditableAlbum(); await Api.Upload(album, files, path => Task.FromResult(ImageTools.Encode(path)), text => Status.Text = text, ct); await LoadPhotos(ct); Status.Text = $"已上传 {files.Length} 张。"; });
    async void Upload_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "选择要上传的图片", Multiselect = true, Filter = "图片|*.jpg;*.jpeg;*.png;*.webp;*.gif;*.bmp" };
        if (dialog.ShowDialog(this) == true)
            await UploadFiles(dialog.FileNames);
    }
    async void Folder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "选择图片文件夹（包含子文件夹）" };
        if (dialog.ShowDialog(this) != true)
            return;
        try
        {
            var paths = ImageTools.FolderImages(dialog.FolderName);
            if (paths.Length == 0)
                throw new FrameException("文件夹中没有支持的图片。");
            await UploadFiles(paths);
        }
        catch (Exception ex) { Status.Text = ex.Message; }
    }
    void Photos_Changed(object sender, SelectionChangedEventArgs e) => Selection.Text = $"已选 {Photos.SelectedItems.Count} 张 · Ctrl 点击增减；拖动框选可累加";
    void Clear_Click(object sender, RoutedEventArgs e) => Photos.UnselectAll();
    async void SelectAll_Click(object sender, RoutedEventArgs e) => await Run("正在读取并全选相册…", async ct => { await LoadPhotos(ct, true); Photos.SelectAll(); });
    int[] SelectedIds() => Photos.SelectedItems.Cast<PhotoCard>().Select(p => p.Photo.Id).ToArray();
    async void Delete_Click(object sender, RoutedEventArgs e)
    {
        var ids = SelectedIds();
        if (ids.Length == 0)
            return;
        if (!Ui.Confirm(this, $"永久删除选中的 {ids.Length} 张设备原图？会影响其他相册，无法撤销。"))
            return;
        await Run("正在删除并回读确认…", async ct => { await Api.DeletePhotos(EditableAlbum(), ids, false, ct); await LoadPhotos(ct); });
    }
    async void Remove_Click(object sender, RoutedEventArgs e)
    {
        var ids = SelectedIds();
        if (ids.Length == 0)
            return;
        await Run("正在移出相册…", async ct => { await Api.DeletePhotos(EditableAlbum(), ids, true, ct); await LoadPhotos(ct); });
    }
    void Photos_Key(object sender, KeyEventArgs e)
    {
        if (busy)
            return;
        if (e.Key == Key.Delete)
        {
            e.Handled = true;
            Delete_Click(sender, e);
        }
        else if (e.Key == Key.A && Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            Photos.SelectAll();
            e.Handled = true;
        }
    }
    async void Download_Click(object sender, RoutedEventArgs e)
    {
        if (Photos.SelectedItems.Count != 1)
            return;
        var photo = ((PhotoCard)Photos.SelectedItems[0]!).Photo;
        var dialog = new SaveFileDialog { FileName = $"TimesFrame-{photo.Id}{Path.GetExtension(photo.Original)}" };
        if (dialog.ShowDialog(this) != true)
            return;
        await Run("正在下载原图…", async ct => { await File.WriteAllBytesAsync(dialog.FileName, await Api.Download(photo.Original, ct), ct); Status.Text = "原图已保存。"; });
    }
    async void Cloud_Click(object sender, RoutedEventArgs e) => await Run("正在核对手机端列表，本地连接不依赖此查询…", async ct => { if (deviceId is not int id) throw new FrameException("请先连接设备。"); var clocks = await CloudClient.Clocks(id, AppState.Session, ct); var ids = clocks.Select(c => c.Id).ToHashSet(); var local = (Albums.ItemsSource as List<Album> ?? []).Where(a => a.Editable && !ids.Contains(a.Id)).Select(a => a.Name).ToArray(); Status.Text = local.Length == 0 ? "已核对手机端列表。" : "仅在设备本地的相册：" + string.Join("、", local); });
    void Settings_Click(object sender, RoutedEventArgs e)
    {
        var previous = AppState.Session?.UserId;
        new SettingsWindow(frame, deviceId) { Owner = this }.ShowDialog();
        if (previous != AppState.Session?.UserId)
        {
            thumbnails.Cancel();
            frame?.Dispose();
            frame = null;
            deviceId = null;
            changing = true;
            Albums.ItemsSource = null;
            changing = false;
            ShowPhotos([]);
            LoadAccountAddress();
            Connected.Text = "";
            Status.Text = "账号已切换，请重新连接设备。";
        }
    }
    void Workbench_Click(object sender, RoutedEventArgs e)
    {
        if (frame == null)
        {
            Status.Text = "请先连接设备。";
            return;
        }
        new WorkbenchWindow(frame) { Owner = this }.ShowDialog();
    }
    async void Existing_Click(object sender, RoutedEventArgs e) => await Run("正在读取全部设备照片…", async ct =>
    {
        var target = EditableAlbum();
        var all = (await Api.Albums(ct)).FirstOrDefault(a => a.Type == 1) ?? throw new FrameException("没有全部照片相册。");
        var photos = await Api.AllPhotos(all.Id, ct);
        var items = photos.Select(p => new PhotoCard(p)).ToArray();
        _ = FillThumbnails(items, thumbnails.Token);
        var picker = new Window { Owner = this, Title = "从全部照片加入“" + target.Name + "”", Width = 820, Height = 620, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var dock = new DockPanel { Margin = new Thickness(12) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var grid = new PhotoGrid { ItemsSource = items, ItemsPanel = Photos.ItemsPanel, ItemTemplate = Photos.ItemTemplate, ItemContainerStyle = Photos.ItemContainerStyle };
        ScrollViewer.SetHorizontalScrollBarVisibility(grid, ScrollBarVisibility.Disabled);
        ScrollViewer.SetCanContentScroll(grid, false);
        var accept = new Button { Content = "加入选中照片" };
        accept.Click += (_, _) => { if (grid.SelectedItems.Count > 0) picker.DialogResult = true; };
        buttons.Children.Add(new TextBlock { Text = "Ctrl 点击或拖动框选", VerticalAlignment = VerticalAlignment.Center });
        buttons.Children.Add(accept);
        buttons.Children.Add(new Button { Content = "取消", IsCancel = true });
        DockPanel.SetDock(buttons, Dock.Bottom);
        dock.Children.Add(buttons);
        dock.Children.Add(grid);
        picker.Content = dock;
        if (picker.ShowDialog() != true)
            return;
        await Api.AddExisting(target, grid.SelectedItems.Cast<PhotoCard>().Select(c => c.Photo.Id), ct);
        await LoadPhotos(ct);
    });
}
