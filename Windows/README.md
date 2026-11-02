# Times Frame 相册管理 · Windows x64 0.9.0

适用于 Windows 10／11 的 Intel／AMD 64 位桌面版本。WPF 原生界面，基于 .NET 10；发布目录自带 .NET 运行时，不需要另装 SDK。此版本不是 32 位 x86，也不是 Windows ARM64 原生版。

## 运行

1. 完整解压 `TimesFrame-0.9.0-windows-x64.zip` 到一个文件夹。
2. 双击 `TimesFrameAlbum.exe`。请保留同目录的 DLL、Resources 等文件，不要只复制 EXE。
3. Mac／Windows 和相框需处在可互通的同一局域网。输入设备当前 IPv4 地址，端口默认 9000；也可“查找设备”并选择后连接。DHCP 可能改变设备地址。
4. 客户端不要求管理员权限；不会自动修改防火墙。局域网请求直接连接设备，不使用系统 HTTP 代理；云端查询使用独立连接。
5. 关闭主窗口即退出，无托盘后台常驻。

## 功能

- 浏览本地相册、分页读取照片、全选整个相册、原图下载。
- 点击单选，Ctrl＋点击增减，Shift 范围选择，拖动框选累加；Delete 打开永久删除确认。
- 从文件或文件夹递归上传 JPG、PNG、WebP、GIF、BMP 静态图片。GIF 上传首帧；视频、HEIC／TIFF／RAW 和 Windows“照片”应用的云相册浏览不在本版支持范围。
- 整批图片先转换校验，再开始上传；自动纠正 EXIF 方向，透明背景铺白，JPEG 长边最大 2048 像素。相册容量上限 100 张。
- 新建／重命名／删除本地普通相册；从全部照片加入、移出相册、按每批最多 10 张删除原图并回读确认。系统相册只读。
- Divoom 邮箱登录、读取账号资料、退出登录。可选通过 Windows 凭据管理器保存会话，不保存密码；连接地址按账号分别保存在 `%LOCALAPPDATA%/TimesFrameAlbum/settings.json`。
- 屏幕开关、亮度读写、表盘／相册播放、镜像、12／24 小时制、设备重启确认；倒计时、秒表、记分牌、噪声工具。
- 表盘工作台：设备信息、实际字体、设备商店缓存、当前或指定表盘配置、截图与 PNG 保存、JSON 导出、本地管理表盘 60000 的创建／更新／播放、背景替换、云端恢复、高级命令。
- 官方 TimesFrame 表盘／字体／显示元素／模板目录、协议说明、字体说明、布局建议。官方 MIT 资源复用仓库的 Resources/TimesFrame，随发布包携带。

## 与手机 App 的边界

本地相册不会自动注册到手机云端。“核对手机端”只读取云端列表，不做双向同步。需要手机可见的新相册，请先在手机 App 创建，再回到 Windows 刷新并上传。删除设备原图会影响引用该图的其他相册；删除前有确认。

表盘编辑使用官方管理槽位 60000。完整配置有同数量元素时会转成局部字段补丁并保留 item_id；写入前检查 Hardware 与实际字体，写入后回读配置。模板不包含图片素材，复杂模板需要自行准备 tar.gz 素材包。恢复云端会先删除指定表盘的本地文件，再尝试刷新，网络失败时可能暂时不可用。

没有实现云端建相册、RGB、日程／闹钟、第三方登录、配网与社区编辑。新 Windows 实现不宣称完整复刻手机 App。

## 开发与构建

需要 .NET 10 SDK。Windows PowerShell 中：

```powershell
./Windows/build.ps1
```

默认输出 `Windows/artifacts/win-x64/TimesFrameAlbum.exe` 及自带运行时。

仅运行协议与图像回归：

```powershell
dotnet run --project Windows/TimesFrame.Tests -c Release
```

只读实机验证（不写入相框）：

```powershell
dotnet run --project Windows/TimesFrame.Tests -c Release -- --read-live <相框IPv4>
```

Windows 本机 UI 冒烟验证：

```powershell
./Windows/artifacts/win-x64/TimesFrameAlbum.exe --self-test
```

GitHub Actions 的 `Windows x64` 工作流在 windows-latest 上执行核心回归、发布、WPF 启动／关闭、图片显示和框选测试，上传便携 ZIP。CI 不连接私人局域网设备；需要硬件的效果仍应在用户的 Windows 与相框上复核。

## 依赖与许可

图像转换使用 SkiaSharp 3.119.4（MIT），包含 JPEG／PNG／WebP 解码与 EXIF 方向处理。相关许可证随包提供于 THIRD-PARTY-NOTICES；Divoom 参考资源的许可证在 Resources/TimesFrame/LICENSE。.NET 自带运行时的许可与第三方声明保留在发布目录。
