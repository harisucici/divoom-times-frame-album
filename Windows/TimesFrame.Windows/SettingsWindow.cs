using System.Windows;
using System.Windows.Controls;
using System.Text.Json.Nodes;
using TimesFrame.Core;
namespace TimesFrame.Windows;
public sealed class SettingsWindow : ToolWindow {
    readonly FrameClient? frame;readonly int? deviceId;readonly TextBox output=Ui.Editor();
    public SettingsWindow(FrameClient? api,int? id):base("账号与设备控制",940,700){frame=api;deviceId=id;Account();Device();Tools();}
    void Account(){
        var panel=Stack();var info=Note(AppState.Session is {} session?$"已登录：{session.Nickname} · {session.Email} · 用户 {session.UserId}":"使用与手机 App 相同的 Divoom 邮箱账号登录。");panel.Children.Add(info);
        var email=Field(AppState.Session?.Email??"",300);var password=new PasswordBox{Width=300,Padding=new Thickness(6)};var remember=new CheckBox{Content="在 Windows 凭据管理器保存会话（不保存密码）",IsChecked=true,Margin=new Thickness(4,8,4,8)};
        panel.Children.Add(Row(Note("邮箱"),email));panel.Children.Add(Row(Note("密码"),password));panel.Children.Add(remember);
        panel.Children.Add(Row(Button("登录 Divoom",async()=>{var secret=password.Password;password.Clear();await Run("登录 Divoom",async ct=>{var user=await CloudClient.Login(email.Text,secret,ct);if(remember.IsChecked==true)CredentialVault.Save(user);else CredentialVault.Clear();AppState.Session=user;info.Text=$"已登录 {user.Nickname} · {user.Email}。关闭此窗口后请重新连接。";});}),Button("验证账号／读取资料",async()=>await Run("读取账号资料",async ct=>{var user=AppState.Session??throw new FrameException("请先登录。");info.Text=Json.Pretty(await CloudClient.Request("User/GetUserInfo",user.Fields(),ct));})),Button("退出登录",()=>{try{CredentialVault.Clear();AppState.Session=null;info.Text="已退出登录并清除本机保存的会话；请关闭窗口后重新连接。";}catch(Exception e){Status.Text=e.Message;}})));
        panel.Children.Add(Note("IP 和端口按用户 ID 分别保存。登录不会自动绑定设备，也不会把本地相册注册到手机云端。第三方账号请先在官方 App 设置邮箱密码。"));panel.Children.Add(Note("手机可见的新相册请在手机 App 创建，再到本客户端刷新。云端建相册、双向同步、RGB、日程与闹钟尚未接入。"));Tab("账号",panel);
    }
    void Device(){
        var panel=Stack();var brightness=new Slider{Minimum=0,Maximum=100,TickFrequency=1,IsSnapToTickEnabled=true,Width=250,Value=50};var label=Note("亮度尚未读取");brightness.ValueChanged+=(_,_)=>label.Text=$"待应用亮度 {(int)brightness.Value}%";var clocks=new ComboBox{Width=430};
        panel.Children.Add(Note(frame==null?"请先在主窗口连接设备。":$"已连接 {frame.Ip}:{frame.Port} · 设备 {deviceId}"));
        panel.Children.Add(Row(Button("读取亮度与云端表盘",async()=>await Run("读取状态",async ct=>{var value=await frame!.Command("Sys/GetBrightness",ct:ct);brightness.Value=value.Int("Brightness");label.Text=$"设备亮度 {value.Int("Brightness")}%";if(deviceId is int id){clocks.ItemsSource=await CloudClient.Clocks(id,AppState.Session,ct);clocks.SelectedIndex=0;}})),Button("开屏",()=>Send("开屏","Channel/OnOffScreen",new(){["OnOff"]=1})),Button("关屏",()=>Send("关屏","Channel/OnOffScreen",new(){["OnOff"]=0}))));
        panel.Children.Add(Row(label,brightness,Button("应用亮度",async()=>await Run("设置亮度并回读",async ct=>{var wanted=(int)brightness.Value;await frame!.Command("Channel/SetBrightness",new(){["Brightness"]=wanted},ct);var read=await frame.Command("Sys/GetBrightness",ct:ct);if(read.Int("Brightness",-1)!=wanted)throw new FrameException("回读亮度与设置值不符。");label.Text=$"设备亮度 {wanted}%";}))));
        panel.Children.Add(Row(clocks,Button("播放所选表盘／相册",async()=>{if(clocks.SelectedItem is not Clock c)return;await Run("切换播放",async ct=>{for(var i=0;i<2;i++)await frame!.Command("Channel/SetClockSelectId",new(){["ClockId"]=c.Id},ct);});})));
        var mirror=new CheckBox{Content="镜像",Margin=new Thickness(4),VerticalAlignment=VerticalAlignment.Center};var hour=new CheckBox{Content="24 小时制",IsChecked=true,Margin=new Thickness(4),VerticalAlignment=VerticalAlignment.Center};
        panel.Children.Add(Row(mirror,Button("应用镜像",()=>Send("设置镜像","Device/SetMirrorMode",new(){["Mode"]=mirror.IsChecked==true?1:0})),hour,Button("应用时间格式",()=>Send("设置时间格式","Device/SetTime24Flag",new(){["Mode"]=hour.IsChecked==true?1:0}))));
        panel.Children.Add(Note("镜像和时间格式为待应用选项，不代表当前值；固件可能在重启后复原。"));panel.Children.Add(Button("重启设备…",()=>{if(Ui.Confirm(this,"重启 Times Frame？设备将暂时离线。"))Send("发送重启请求","Device/SysReboot",new());}));
        output.Height=190;output.IsReadOnly=true;panel.Children.Add(output);Tab("设备",panel,frame!=null);
    }
    static int Number(TextBox box,int max){if(!int.TryParse(box.Text,out var n)||n<0||n>max)throw new FrameException($"请输入 0–{max} 的整数。");return n;}
    void Tools(){
        var panel=Stack();var minute=Field("25");var second=Field("0");panel.Children.Add(Note("工具会切换设备显示，完成后可以重新播放表盘或相册。"));
        panel.Children.Add(Row(Note("倒计时（分／秒）"),minute,second,Button("开始",async()=>await Run("启动倒计时",async ct=>{var m=Number(minute,999);var s=Number(second,59);if(m+s==0)throw new FrameException("倒计时不能为零。");await frame!.Command("Tools/SetTimer",new(){["Minute"]=m,["Second"]=s,["Status"]=1},ct);})),Button("停止",()=>Send("停止倒计时","Tools/SetTimer",new(){["Minute"]=0,["Second"]=0,["Status"]=0}))));
        panel.Children.Add(Row(Note("秒表"),Button("开始",()=>Send("启动秒表","Tools/SetStopWatch",new(){["Status"]=1})),Button("停止",()=>Send("停止秒表","Tools/SetStopWatch",new(){["Status"]=0})),Button("复位",()=>Send("复位秒表","Tools/SetStopWatch",new(){["Status"]=2}))));
        var blue=Field("0");var red=Field("0");panel.Children.Add(Row(Note("记分牌（蓝／红）"),blue,red,Button("显示记分牌",async()=>await Run("设置记分牌",async ct=>{await frame!.Command("Tools/SetScoreBoard",new(){["BlueScore"]=Number(blue,999),["RedScore"]=Number(red,999)},ct);} ))));
        panel.Children.Add(Row(Note("噪声工具"),Button("开启",()=>Send("开启噪声工具","Tools/SetNoiseStatus",new(){["NoiseStatus"]=1})),Button("关闭",()=>Send("关闭噪声工具","Tools/SetNoiseStatus",new(){["NoiseStatus"]=0}))));Tab("工具",panel,frame!=null);
    }
    async void Send(string label,string command,JsonObject fields)=>await Run(label,async ct=>{output.Text=Json.Pretty(await frame!.Command(command,fields,ct));});
}
