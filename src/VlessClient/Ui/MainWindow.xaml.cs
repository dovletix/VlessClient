using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Threading;
using VlessClient.Core;

namespace VlessClient.Ui
{
    public sealed class AppVm : INotifyPropertyChanged
    {
        private bool running;
        public string Name { get; set; }
        public bool Vpn { get; set; }
        public List<string> Processes { get; set; } = new List<string>();
        public string ProcessText => string.Join(", ", Processes);
        public bool Running { get => running; set { if (running == value) return; running = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Running))); } }
        public event PropertyChangedEventHandler PropertyChanged;
    }

    public sealed class ChipVm
    {
        public string Value { get; set; }
        public string List { get; set; }
    }

    public sealed class NodeRow
    {
        public int Index { get; set; }
        public string Name { get; set; }
        public string Kind { get; set; }
        public string Result { get; set; }
        public int Sort { get; set; }
    }

    public partial class MainWindow : Window
    {
        private readonly ServiceClient client;
        private readonly DispatcherTimer statusTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        private readonly DispatcherTimer trafficTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        private readonly DispatcherTimer proxyTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(20) };
        private readonly TrafficMonitor traffic = new TrafficMonitor();
        private readonly Dictionary<string, ProcRow> allRows = new Dictionary<string, ProcRow>(StringComparer.OrdinalIgnoreCase);
        private readonly ObservableCollection<ProcRow> visibleRows = new ObservableCollection<ProcRow>();
        private TrafficSnapshot lastSnap;
        private string sortKey = "speed";
        private int sortDir = -1;
        private Dictionary<string, object> status;
        private Dictionary<string, object> settings;
        private bool polling, sampling, suppress, reallyExit, serviceDown;
        private FrameworkElement current;
        private string lastNodesKey = "";

        public event Action<string, bool, string> StatusChanged;
        public event Action<string, string> Notify;

        public MainWindow(ServiceClient client)
        {
            this.client = client;
            InitializeComponent();
            Icon = System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(Icons.Shield(Icons.On, true).Handle, Int32Rect.Empty, System.Windows.Media.Imaging.BitmapSizeOptions.FromEmptyOptions());
            ProcList.ItemsSource = visibleRows;
            SourceInitialized += (s, e) => Theme.TitleBar(this, Theme.Dark);
            ThemeDark.IsChecked = Theme.Dark;
            ThemeLight.IsChecked = !Theme.Dark;
            UpdateHeaders();
            statusTimer.Tick += async (s, e) => await PollStatus();
            trafficTimer.Tick += async (s, e) => await SampleTraffic();
            proxyTimer.Tick += (s, e) => CheckLeftoverProxy();
            current = HomePage;
            TrayBox.IsChecked = UiApp.TrayAtLogon;
        }

        public void Start()
        {
            statusTimer.Start();
            proxyTimer.Start();
            CheckLeftoverProxy();
            _ = PollStatus();
        }

        // ------------------------------------------------------------------ development snapshots

        internal IEnumerable<Action> SnapshotSteps(string dir)
        {
            void Save(string name)
            {
                UpdateLayout();
                var root = (FrameworkElement)Content;
                var dpi = VisualTreeHelper.GetDpi(this);
                var bmp = new System.Windows.Media.Imaging.RenderTargetBitmap((int)(root.ActualWidth * dpi.DpiScaleX), (int)(root.ActualHeight * dpi.DpiScaleY), dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
                var dv = new DrawingVisual();
                using (var dc = dv.RenderOpen()) { dc.DrawRectangle(Background, null, new Rect(0, 0, root.ActualWidth, root.ActualHeight)); dc.DrawRectangle(new VisualBrush(root), null, new Rect(0, 0, root.ActualWidth, root.ActualHeight)); }
                bmp.Render(dv);
                var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bmp));
                using (var f = File.Create(Path.Combine(dir, name + ".png"))) enc.Save(f);
            }
            yield return () => Save("1-home");
            yield return () => OpenSettingsClick(null, null);
            yield return () => Save("2-settings");
            yield return () => OpenAdvancedClick(null, null);
            yield return () => { };
            yield return () => { };
            yield return () => { };
            yield return () => { var r = visibleRows.FirstOrDefault(x => x.D.Fails.Count > 0) ?? visibleRows.FirstOrDefault(x => x.CanOpen); if (r != null) r.IsExpanded = true; };
            yield return () => Save("3-advanced-programs");
            yield return () => AdvancedTabs.SelectedIndex = 1;
            yield return () => Save("4-advanced-sites");
            yield return () => { AdvancedTabs.SelectedIndex = 2; TestNodesClick(TestNodesButton, null); };
            yield return () => { };
            yield return () => { };
            yield return () => { };
            yield return () => Save("5-advanced-servers");
            yield return () => AdvancedTabs.SelectedIndex = 3;
            yield return () => Save("6-advanced-mode");
            yield return () => { Width = 520; Height = 680; ChangeSubClick(null, null); };
            yield return () => Save("7-setup");
        }

        // ------------------------------------------------------------------ window / tray

        public void ShowFromTray()
        {
            Show();
            if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
            Activate();
            Topmost = true; Topmost = false;
            statusTimer.Interval = TimeSpan.FromSeconds(1);
        }

        public async void ToggleFromTray()
        {
            if (status == null) { ShowFromTray(); return; }
            await Send(ServiceClient.Cmd(status.Bool("enabled") ? "disconnect" : "connect"));
        }

        public void ExitUi()
        {
            reallyExit = true;
            Close();
            Application.Current.Shutdown();
        }

        protected override void OnClosing(CancelEventArgs e)
        {
            if (!reallyExit)
            {
                e.Cancel = true;
                Hide();
                statusTimer.Interval = TimeSpan.FromSeconds(4);
                trafficTimer.Stop();
                if (!UiApp.HintShown)
                {
                    UiApp.HintShown = true;
                    Notify?.Invoke("VlessClient работает в фоне", "Окно закрыто, VPN продолжает работать. Открыть его снова — щелчок по значку рядом с часами.");
                }
            }
            base.OnClosing(e);
        }

        private void ShowPage(FrameworkElement page)
        {
            foreach (var p in new FrameworkElement[] { SetupPage, HomePage, SettingsPage, AdvancedPage }) p.Visibility = p == page ? Visibility.Visible : Visibility.Collapsed;
            current = page;
            if (page == AdvancedPage && AdvancedTabs.SelectedIndex == 0) { trafficTimer.Start(); _ = SampleTraffic(); }
            else trafficTimer.Stop();
            if (page == AdvancedPage)
            {
                var area = SystemParameters.WorkArea;
                var w = Math.Min(1220, area.Width - 40); var h = Math.Min(820, area.Height - 40);
                var onScreen = Left > area.Left - 2000;   // the off-screen snapshot window must stay off-screen
                if (Width < w) { if (onScreen) Left = Math.Max(area.Left, Left - (w - Width) / 2); Width = w; }
                if (Height < h) { if (onScreen) Top = Math.Max(area.Top, Top - (h - Height) / 2); Height = h; }
                if (onScreen && Left + Width > area.Right) Left = Math.Max(area.Left, area.Right - Width);
                if (onScreen && Top + Height > area.Bottom) Top = Math.Max(area.Top, area.Bottom - Height);
            }
        }

        private void SetBusy(string text)
        {
            Busy.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
            BusyText.Text = text ?? "";
        }

        private async Task<Dictionary<string, object>> Send(JObj req, int timeoutMs = 15000, bool showErrors = true)
        {
            try
            {
                var r = await client.SendAsync(req, timeoutMs);
                if (!r.Bool("ok") && showErrors && r.Str("error").Length > 0)
                    MessageBox.Show(this, r.Str("error"), "VlessClient", MessageBoxButton.OK, MessageBoxImage.Warning);
                return r;
            }
            catch (Exception e)
            {
                if (showErrors) MessageBox.Show(this, e.Message, "VlessClient", MessageBoxButton.OK, MessageBoxImage.Warning);
                return new Dictionary<string, object> { ["ok"] = false, ["error"] = e.Message };
            }
        }

        // ------------------------------------------------------------------ status

        private async Task PollStatus()
        {
            if (polling) return;
            polling = true;
            try
            {
                Dictionary<string, object> r;
                try { r = await client.SendAsync(ServiceClient.Cmd("status"), 5000); serviceDown = false; }
                catch { serviceDown = true; r = null; }
                if (r == null || !r.Bool("ok")) { RenderServiceDown(); return; }
                status = r.Obj("status");
                RenderStatus();
            }
            finally { polling = false; }
        }

        private static readonly SolidColorBrush GreenBrush = new SolidColorBrush(Color.FromRgb(22, 163, 74));
        private static readonly SolidColorBrush AmberBrush = new SolidColorBrush(Color.FromRgb(217, 119, 6));
        private static readonly SolidColorBrush RedBrush = new SolidColorBrush(Color.FromRgb(220, 38, 38));
        private static readonly SolidColorBrush GreyBrush = new SolidColorBrush(Color.FromRgb(138, 148, 163));

        private void RenderServiceDown()
        {
            BigButton.Background = GreyBrush;
            StateText.Text = "Служба VlessClient не запущена";
            StateHint.Text = "Нажмите на кнопку, чтобы запустить её (Windows попросит разрешение). Если не поможет — переустановите VlessClient.";
            WarningBox.Visibility = Visibility.Collapsed;
            StatusChanged?.Invoke("off", false, "служба не запущена");
        }

        private void RenderStatus()
        {
            var st = status.Str("state");
            var enabled = status.Bool("enabled");
            if (!status.Bool("has_subscription"))
            {
                if (current != SetupPage) { SetupCancel.Visibility = Visibility.Collapsed; ShowPage(SetupPage); PrefillLink(); }
                StatusChanged?.Invoke("off", false, "нужна ссылка на подписку");
                return;
            }
            if (current == SetupPage && SetupCancel.Visibility != Visibility.Visible) ShowPage(HomePage);

            string title, hint; SolidColorBrush brush;
            switch (st)
            {
                case "on":
                    brush = GreenBrush; title = "VPN включён";
                    hint = "Сервер: " + status.Str("node");
                    if (!status.Bool("tun")) hint += "\nТолько локальный прокси — системный туннель недоступен";
                    break;
                case "connecting":
                    brush = AmberBrush; title = "Подключение…"; hint = status.Str("message");
                    break;
                case "error":
                    brush = RedBrush; title = "Нет подключения";
                    hint = status.Str("message") + "\nКлиент сам пробует снова. Нажмите на кнопку, чтобы выключить VPN.";
                    break;
                default:
                    brush = GreyBrush; title = "VPN выключен"; hint = "Нажмите на кнопку, чтобы включить";
                    break;
            }
            BigButton.Background = brush;
            StateText.Text = title;
            StateHint.Text = hint;
            var warns = status.Strings("warnings");
            WarningText.Text = string.Join("\n", warns);
            WarningBox.Visibility = warns.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

            var upd = status.Obj("update");
            if (upd != null && upd.Str("status") == "available")
            {
                UpdateBanner.Content = "Доступна новая версия " + upd.Str("latest") + " — обновить";
                UpdateBanner.Visibility = Visibility.Visible;
            }
            else UpdateBanner.Visibility = Visibility.Collapsed;

            RenderUpdate(upd);
            RenderNodeChoices();
            RenderAdvancedHeader(st);
            StatusChanged?.Invoke(st == "nosubscription" ? "off" : st, enabled, title + (st == "on" ? " (" + status.Str("node") + ")" : ""));
        }

        private async void BigButtonClick(object sender, RoutedEventArgs e)
        {
            if (serviceDown) { StartService(); return; }
            if (status == null) return;
            BigButton.IsEnabled = false;
            try
            {
                await Send(ServiceClient.Cmd(status.Bool("enabled") ? "disconnect" : "connect"), 30000);
                await PollStatus();
            }
            finally { BigButton.IsEnabled = true; }
        }

        private void StartService()
        {
            try
            {
                Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "sc.exe"), "start " + Paths.ServiceName)
                { Verb = "runas", UseShellExecute = true, WindowStyle = ProcessWindowStyle.Hidden });
            }
            catch { }
        }

        private void CheckLeftoverProxy()
        {
            var fixedProxy = ProxyFix.FixDeadLocalProxy();
            if (fixedProxy != null)
                Notify?.Invoke("Интернет восстановлен", "Другая программа (например, Happ) оставила включённый прокси " + fixedProxy + ", из-за которого не открывались сайты. VlessClient его выключил.");
        }

        // ------------------------------------------------------------------ first run

        private void PrefillLink()
        {
            if (SetupUrl.Text.Trim().Length > 0) return;
            try
            {
                var t = Clipboard.ContainsText() ? Clipboard.GetText().Trim() : "";
                if ((t.StartsWith("http", StringComparison.OrdinalIgnoreCase) && !t.Contains(" ") && t.Length < 500) ||
                    (t.StartsWith("vless://", StringComparison.OrdinalIgnoreCase) && t.Length < 200000)) SetupUrl.Text = t;
            }
            catch { }
        }

        private void PasteClick(object sender, RoutedEventArgs e)
        {
            try { if (Clipboard.ContainsText()) SetupUrl.Text = Clipboard.GetText().Trim(); } catch { }
        }

        private async void SetupClick(object sender, RoutedEventArgs e)
        {
            var url = SetupUrl.Text.Trim();
            if (url.Length == 0) { SetupStatus.Text = "Вставьте ссылку на подписку."; return; }
            SetupButton.IsEnabled = false;
            SetupStatus.Foreground = (Brush)FindResource("Muted");
            SetupStatus.Text = "Проверяю ссылку…";
            try
            {
                var r = await Send(new JObj().Set("cmd", "set_subscription").Set("url", url).Set("insecure", false), 60000, false);
                if (r.Bool("ok"))
                {
                    SetupStatus.Text = "";
                    SetupUrl.Text = "";
                    SetupCancel.Visibility = Visibility.Collapsed;
                    ShowPage(HomePage);
                    await PollStatus();
                }
                else
                {
                    SetupStatus.Foreground = RedBrush;
                    SetupStatus.Text = r.Str("error");
                }
            }
            finally { SetupButton.IsEnabled = true; }
        }

        // ------------------------------------------------------------------ navigation

        private async void OpenSettingsClick(object sender, RoutedEventArgs e)
        {
            ShowPage(SettingsPage);
            await LoadSettings();
        }

        private async void OpenAdvancedClick(object sender, RoutedEventArgs e)
        {
            ShowPage(AdvancedPage);
            await LoadSettings();
        }

        private void BackClick(object sender, RoutedEventArgs e)
        {
            SetupStatus.Text = "";
            SetupCancel.Visibility = Visibility.Collapsed;
            ShowPage(HomePage);
        }

        private void AdvancedTabChanged(object sender, SelectionChangedEventArgs e)
        {
            if (e.Source != AdvancedTabs) return;
            if (current == AdvancedPage && AdvancedTabs.SelectedIndex == 0) trafficTimer.Start(); else trafficTimer.Stop();
        }

        // ------------------------------------------------------------------ settings

        private async Task LoadSettings()
        {
            var r = await Send(ServiceClient.Cmd("settings"), 10000, false);
            if (!r.Bool("ok")) return;
            settings = r.Obj("settings");
            suppress = true;
            try
            {
                var sub = settings.Obj("subscription");
                string host = ""; try { host = new Uri(sub.Str("url")).Host; } catch { }
                var subTime = status?.Str("subscription_time") ?? "";
                var count = status?.Objects("nodes").Count(n => n.Int("group") == 0) ?? 0;
                RenderBackups();
                SubInfo.Text = sub.Bool("inline")
                    ? "Серверы вставлены вручную: " + count + "\nЧтобы обновить их, нажмите «Изменить ссылку»."
                    : "Сервер подписки: " + host + "\nСерверов в подписке: " + count +
                      (subTime.Length > 0 && DateTime.TryParse(subTime, out var t) ? "\nОбновлена: " + t.ToString("dd.MM.yyyy HH:mm") : "");
                RuDirectBox.IsChecked = settings.Obj("ru_direct").Bool("enabled", true);
                AutoUpdateBox.IsChecked = settings.Bool("auto_update");
                lastNodesKey = "";
                RenderNodeChoices();

                var apps = settings.Objects("apps").Select(a => new AppVm { Name = a.Str("name"), Vpn = a.Bool("vpn"), Processes = a.Strings("processes") }).ToList();
                AppsList.ItemsSource = apps;
                AppsEmpty.Visibility = apps.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                MarkRunningApps();
                var rules = settings.Obj("rules");
                var direct = rules.Strings("direct_domains").Concat(rules.Strings("direct_ips")).Select(v => new ChipVm { Value = v, List = "direct" }).ToList();
                var proxy = rules.Strings("proxy_domains").Concat(rules.Strings("proxy_ips")).Select(v => new ChipVm { Value = v, List = "proxy" }).ToList();
                DirectChips.ItemsSource = direct; DirectEmpty.Visibility = direct.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                ProxyChips.ItemsSource = proxy; ProxyEmpty.Visibility = proxy.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                RuNote.Text = settings.Obj("ru_direct").Bool("enabled", true)
                    ? "Российские сайты и адреса идут напрямую автоматически; заблокированные в России — через VPN."
                    : "Автоматическое правило для российских сайтов выключено (Настройки → Российские сайты).";
                if (current == AdvancedPage) RenderProcRows();
                AutoExcludeInput.Text = settings.Str("auto_exclude");
                DefaultProxy.IsChecked = settings.Str("default") != "direct";
                DefaultDirect.IsChecked = settings.Str("default") == "direct";
                ProxyInfo.Text = "Локальный прокси (SOCKS5 и HTTP): 127.0.0.1:" + settings.Obj("ports").Int("proxy") + " — для программ, которые умеют работать через прокси.";
            }
            finally { suppress = false; }
        }

        private void RenderNodeChoices()
        {
            if (status == null) return;
            var nodes = status.Objects("nodes");
            var sel = settings?.Str("node", "auto") ?? NodeBox.SelectedValue as string ?? "auto";
            var key = string.Join("|", nodes.Select(n => n.Str("name"))) + "#" + sel;
            if (key == lastNodesKey) return;
            lastNodesKey = key;
            suppress = true;
            try
            {
                var items = new List<KeyValuePair<string, string>> { new KeyValuePair<string, string>("auto", "Автоматически (рекомендуется)") };
                items.AddRange(nodes.Select(n => new KeyValuePair<string, string>(n.Int("index").ToString(),
                    n.Int("index") + ". " + n.Str("name") + (n.Int("group") > 0 ? "  (запасная подписка " + n.Int("group") + ")" : ""))));
                NodeBox.ItemsSource = items;
                NodeBox.DisplayMemberPath = "Value";
                NodeBox.SelectedValuePath = "Key";
                NodeBox.SelectedValue = items.Any(i => i.Key == sel) ? sel : "auto";
            }
            finally { suppress = false; }
        }

        private async void NodeChanged(object sender, SelectionChangedEventArgs e)
        {
            if (suppress || !(NodeBox.SelectedValue is string v)) return;
            await Send(new JObj().Set("cmd", "set_node").Set("node", v));
            if (settings != null) settings["node"] = v;
            lastNodesKey = "";
        }

        private async void RefreshSubClick(object sender, RoutedEventArgs e)
        {
            SetBusy("Обновляю список серверов…");
            try
            {
                var r = await Send(ServiceClient.Cmd("refresh_subscription"), 60000);
                await PollStatus();
                await LoadSettings();
                if (r.Bool("ok")) MessageBox.Show(this, "Список серверов обновлён.", "VlessClient", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            finally { SetBusy(null); }
        }

        private sealed class BackupVm
        {
            public string Url { get; set; }
            public string Title { get; set; }
            public string Info { get; set; }
            public string Error { get; set; }
            public Visibility ErrorVisibility => string.IsNullOrEmpty(Error) ? Visibility.Collapsed : Visibility.Visible;
        }

        private void RenderBackups()
        {
            var list = status?.Objects("backups") ?? new List<Dictionary<string, object>>();
            BackupList.ItemsSource = list.Select((b, k) =>
            {
                var time = b.Str("time");
                var count = b.Int("count");
                return new BackupVm
                {
                    Url = b.Str("url"),
                    Title = (k + 1) + ". " + b.Str("host"),
                    Info = time.Length == 0 || !DateTime.TryParse(time, out var t)
                        ? "ещё не загружалась"
                        : (count == 0 ? "копия основной, новых серверов нет" : "серверов: " + count) + " · обновлена " + t.ToString("dd.MM.yyyy HH:mm"),
                    Error = b.Str("error").Length > 0 ? "Не загрузилась: " + b.Str("error") : "",
                };
            }).ToList();
        }

        private async void BackupAddClick(object sender, RoutedEventArgs e)
        {
            var url = BackupInput.Text.Trim();
            if (url.Length == 0) return;
            SetBusy("Проверяю ссылку…");
            try
            {
                var r = await Send(new JObj().Set("cmd", "add_backup").Set("url", url), 60000);
                if (r.Bool("ok"))
                {
                    BackupInput.Text = "";
                    MessageBox.Show(this, r.Str("message"), "VlessClient", MessageBoxButton.OK, MessageBoxImage.Information);
                }
                await PollStatus();
                await LoadSettings();
            }
            finally { SetBusy(null); }
        }

        private async void BackupRemoveClick(object sender, RoutedEventArgs e)
        {
            if (!(((Button)sender).Tag is string url)) return;
            string host = url; try { host = new Uri(url).Host; } catch { }
            if (MessageBox.Show(this, "Убрать запасную подписку " + host + "?", "VlessClient", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            await Send(new JObj().Set("cmd", "remove_backup").Set("url", url));
            await PollStatus();
            await LoadSettings();
        }

        private void ChangeSubClick(object sender, RoutedEventArgs e)
        {
            SetupUrl.Text = "";
            SetupStatus.Text = "";
            SetupCancel.Visibility = Visibility.Visible;
            ShowPage(SetupPage);
            PrefillLink();
        }

        private async void RuDirectClick(object sender, RoutedEventArgs e)
        {
            if (suppress) return;
            await Send(new JObj().Set("cmd", "set_option").Set("key", "ru_direct").Set("value", RuDirectBox.IsChecked == true));
        }

        private async void AutoUpdateClick(object sender, RoutedEventArgs e)
        {
            if (suppress) return;
            await Send(new JObj().Set("cmd", "set_option").Set("key", "auto_update").Set("value", AutoUpdateBox.IsChecked == true));
        }

        private void TrayClick(object sender, RoutedEventArgs e) => UiApp.TrayAtLogon = TrayBox.IsChecked == true;

        private void RenderUpdate(Dictionary<string, object> upd)
        {
            VersionText.Text = "Установлена версия " + status?.Str("version");
            if (upd == null) return;
            var st = upd.Str("status");
            InstallUpdateButton.Visibility = st == "available" ? Visibility.Visible : Visibility.Collapsed;
            CheckUpdateButton.IsEnabled = st != "checking" && st != "downloading" && st != "installing";
            switch (st)
            {
                case "checking": UpdateText.Text = "Проверяю…"; break;
                case "available": UpdateText.Text = "Доступна версия " + upd.Str("latest") + "."; InstallUpdateButton.Content = "Обновить до " + upd.Str("latest"); break;
                case "uptodate": UpdateText.Text = "У вас последняя версия."; break;
                case "downloading": UpdateText.Text = "Скачиваю обновление…"; break;
                case "installing": UpdateText.Text = "Устанавливаю обновление. VPN на несколько секунд отключится, окно перезапустится."; RelaunchAfterUpdate(); break;
                case "error": UpdateText.Text = upd.Str("error"); break;
                default: UpdateText.Text = "Обновления проверяются только по кнопке" + (AutoUpdateBox.IsChecked == true ? " и автоматически раз в 12 часов." : "."); break;
            }
        }

        private async void CheckUpdateClick(object sender, RoutedEventArgs e)
        {
            CheckUpdateButton.IsEnabled = false;
            UpdateText.Text = "Проверяю…";
            await Send(ServiceClient.Cmd("update_check"), 60000, false);
            await PollStatus();
        }

        private async void InstallUpdateClick(object sender, RoutedEventArgs e)
        {
            if (MessageBox.Show(this, "Установить новую версию? VPN отключится примерно на полминуты.", "VlessClient", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            SetBusy("Скачиваю и устанавливаю обновление…");
            try
            {
                await Send(ServiceClient.Cmd("update_install"), 300000);
                await PollStatus();   // status "installing" makes the window restart itself (see RenderUpdate)
            }
            finally { SetBusy(null); }
        }

        private bool relaunchScheduled;

        /// <summary>The installer replaces VlessClient.exe, so the window leaves and comes back with the new version.</summary>
        private void RelaunchAfterUpdate()
        {
            if (relaunchScheduled) return;
            relaunchScheduled = true;
            try
            {
                var exe = Process.GetCurrentProcess().MainModule.FileName;
                var arg = IsVisible ? "" : " --tray";
                Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"),
                    "/c timeout /t 45 /nobreak >nul & start \"\" \"" + exe + "\"" + arg) { WindowStyle = ProcessWindowStyle.Hidden, CreateNoWindow = true, UseShellExecute = false });
            }
            catch { }
            ExitUi();
        }

        private async void ReportClick(object sender, RoutedEventArgs e)
        {
            SetBusy("Собираю отчёт…");
            try
            {
                var r = await Send(ServiceClient.Cmd("report"), 60000);
                if (!r.Bool("ok")) return;
                var file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "VlessClient-отчёт-" + DateTime.Now.ToString("yyyy-MM-dd-HHmm") + ".txt");
                File.WriteAllText(file, r.Str("text"), Paths.Utf8);
                MessageBox.Show(this, "Отчёт сохранён на Рабочий стол:\n" + Path.GetFileName(file) + "\n\nОтправьте этот файл тому, кто помогает вам с VPN.", "VlessClient", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex) { MessageBox.Show(this, "Не удалось сохранить отчёт: " + ex.Message, "VlessClient"); }
            finally { SetBusy(null); }
        }

        // ------------------------------------------------------------------ advanced: programs

        // The web UI's "Процессы" table: per program speed, totals, connections, VPN / direct split, failures; the rows
        // stay the same objects (expanded state survives), the visible list is filtered and sorted every second.

        private async Task SampleTraffic()
        {
            if (sampling || settings == null) return;
            sampling = true;
            try
            {
                var api = settings.Obj("api");
                if (api == null) return;
                var ruled = new HashSet<string>(settings.Objects("apps").SelectMany(a => a.Strings("processes")), StringComparer.OrdinalIgnoreCase);
                lastSnap = await traffic.SampleAsync(api.Int("port"), api.Str("secret"), ShowAllBox.IsChecked == true, ruled);
                RenderProcRows();
            }
            finally { sampling = false; }
        }

        private void RenderProcRows()
        {
            if (lastSnap == null || settings == null) return;
            var apps = settings.Objects("apps");
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var d in lastSnap.Rows)
            {
                seen.Add(d.Key);
                if (!allRows.TryGetValue(d.Key, out var row)) allRows[d.Key] = row = new ProcRow(d.Key);
                var a = apps.FirstOrDefault(x => x.Strings("processes").Any(p => p.Equals(d.Key, StringComparison.OrdinalIgnoreCase)));
                row.Update(d, a?.Str("name"), a?.Bool("vpn") ?? false);
            }
            foreach (var k in allRows.Keys.Where(k => !seen.Contains(k)).ToList()) allRows.Remove(k);

            var q = SearchBox.Text.Trim();
            var onlyBad = OnlyBadBox.IsChecked == true;
            Func<ProcRow, IComparable> key;
            switch (sortKey)
            {
                case "name": key = r => r.Name.ToLowerInvariant(); break;
                case "total": key = r => r.SortTotal; break;
                case "conns": key = r => r.SortConns; break;
                case "vpn": key = r => r.SortVpn; break;
                case "fail": key = r => r.SortFail; break;
                default: key = r => r.SortSpeed; break;
            }
            var list = allRows.Values
                .Where(r => q.Length == 0 || r.Name.IndexOf(q, StringComparison.OrdinalIgnoreCase) >= 0 || r.AppName.IndexOf(q, StringComparison.OrdinalIgnoreCase) >= 0)
                .Where(r => !onlyBad || r.D.Fail > 0 || r.D.Udp > 0)
                .ToList();
            list.Sort((x, y) =>
            {
                var c = key(x).CompareTo(key(y)) * (sortDir < 0 ? -1 : 1);
                if (c != 0) return c;
                // ties: more traffic first, then programs with a window, then by name
                c = y.SortTotal.CompareTo(x.SortTotal); if (c != 0) return c;
                c = y.D.Window.CompareTo(x.D.Window); if (c != 0) return c;
                return string.Compare(x.Name, y.Name, StringComparison.OrdinalIgnoreCase);
            });
            SyncRows(list);
            ProcEmpty.Visibility = list.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

            double down = 0, up = 0, v = 0, dir = 0;
            foreach (var r in lastSnap.Rows) { down += r.RDown; up += r.RUp; v += r.RP; dir += r.RD; }
            TotalsText.Inlines.Clear();
            TotalsText.Inlines.Add(new System.Windows.Documents.Run("Сейчас всего:  "));
            TotalsText.Inlines.Add(new System.Windows.Documents.Run("↓ " + ProcRow.Rate(down) + "  ·  ↑ " + ProcRow.Rate(up)) { FontWeight = FontWeights.SemiBold });
            TotalsText.Inlines.Add(new System.Windows.Documents.Run("        "));
            var rv = new System.Windows.Documents.Run("через VPN ") { FontWeight = FontWeights.SemiBold }; rv.SetResourceReference(TextElement.ForegroundProperty, "Accent");
            TotalsText.Inlines.Add(rv); TotalsText.Inlines.Add(new System.Windows.Documents.Run(ProcRow.Rate(v) + "        "));
            var rd = new System.Windows.Documents.Run("напрямую ") { FontWeight = FontWeights.SemiBold }; rd.SetResourceReference(TextElement.ForegroundProperty, "Ok");
            TotalsText.Inlines.Add(rd); TotalsText.Inlines.Add(new System.Windows.Documents.Run(ProcRow.Rate(dir)));

            StatNote.Text = lastSnap.ApiOk
                ? "Скорость и объёмы считаются с момента открытия окна. Наведите на программу, чтобы увидеть, куда она ходит; щелчок раскрывает адреса и сбои. «Без ответа» — программа отправила данные и не получила ни байта, либо соединение не установилось."
                : "Нет связи с sing-box — VPN выключен или ещё подключается. Статистика соединений сейчас недоступна.";
            MarkRunningApps();
        }

        /// <summary>Brings the visible collection in line with the wanted order with few moves (no flicker, hover and tooltips survive).</summary>
        private void SyncRows(List<ProcRow> want)
        {
            var wanted = new HashSet<ProcRow>(want);
            for (var i = visibleRows.Count - 1; i >= 0; i--) if (!wanted.Contains(visibleRows[i])) visibleRows.RemoveAt(i);
            for (var i = 0; i < want.Count; i++)
            {
                var cur = visibleRows.IndexOf(want[i]);
                if (cur < 0) visibleRows.Insert(i, want[i]);
                else if (cur != i) visibleRows.Move(cur, i);
            }
        }

        private void MarkRunningApps()
        {
            if (!(AppsList.ItemsSource is List<AppVm> apps) || lastSnap == null) return;
            var running = new HashSet<string>(lastSnap.Rows.Where(r => r.Running).Select(r => r.Key), StringComparer.OrdinalIgnoreCase);
            foreach (var a in apps) a.Running = a.Processes.Any(running.Contains);
        }

        private void UpdateHeaders()
        {
            foreach (var b in new[] { HName, HSpeed, HTotal, HConns, HVpn, HFail })
            {
                var label = ((string)b.Content).TrimEnd(' ', '▲', '▼');
                var on = (string)b.Tag == sortKey;
                b.Content = on ? label + (sortDir < 0 ? " ▼" : " ▲") : label;
                if (on) b.SetResourceReference(ForegroundProperty, "Accent"); else b.ClearValue(ForegroundProperty);
            }
        }

        private void HeaderSortClick(object sender, RoutedEventArgs e)
        {
            var k = (string)((Button)sender).Tag;
            if (k == sortKey) sortDir = -sortDir; else { sortKey = k; sortDir = k == "name" ? 1 : -1; }
            UpdateHeaders();
            RenderProcRows();
        }

        private void FilterClick(object sender, RoutedEventArgs e)
        {
            if (sender == ShowAllBox) _ = SampleTraffic(); else RenderProcRows();
        }

        private void SearchChanged(object sender, TextChangedEventArgs e)
        {
            SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            RenderProcRows();
        }

        private void PlaceholderChanged(object sender, TextChangedEventArgs e)
        {
            var box = (TextBox)sender;
            var hint = box == AddExeInput ? AddExeHint : box == DirectInput ? DirectHint : box == ProxyInput ? ProxyHint : box == BackupInput ? BackupHint : null;
            if (hint != null) hint.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        private void ResetStatsClick(object sender, RoutedEventArgs e)
        {
            traffic.Reset();
            allRows.Clear(); visibleRows.Clear(); lastSnap = null;
            _ = SampleTraffic();
        }

        private void RowToggle(object sender, System.Windows.Input.MouseButtonEventArgs e)
        {
            if (((FrameworkElement)sender).DataContext is ProcRow r) r.IsExpanded = !r.IsExpanded;
        }

        private void RowExpandClick(object sender, RoutedEventArgs e)
        {
            if (((FrameworkElement)sender).DataContext is ProcRow r) r.IsExpanded = !r.IsExpanded;
        }

        private async void RowRouteClick(object sender, RoutedEventArgs e)
        {
            if (!(((FrameworkElement)sender).DataContext is ProcRow r) || r.IsUnknown) return;
            var vpn = (string)((Button)sender).Tag == "vpn";
            var exe = r.D.Name;
            await Send(new JObj().Set("cmd", "set_app").Set("name", Path.GetFileNameWithoutExtension(exe)).Set("processes", new List<string> { exe }).Set("vpn", vpn));
            await LoadSettings();
        }

        private async void AddExeClick(object sender, RoutedEventArgs e)
        {
            var v = AddExeInput.Text.Trim();
            if (v.Length == 0) return;
            if (!v.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) v += ".exe";
            if (v.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) { MessageBox.Show(this, "Нужно имя файла вида program.exe", "VlessClient"); return; }
            var r = await Send(new JObj().Set("cmd", "set_app").Set("name", Path.GetFileNameWithoutExtension(v)).Set("processes", new List<string> { v }).Set("vpn", (string)((Button)sender).Tag == "vpn"));
            if (r.Bool("ok")) AddExeInput.Text = "";
            await LoadSettings();
        }

        private void RenderAdvancedHeader(string st)
        {
            string text, soft, strong;
            switch (st)
            {
                case "on": if (status.Bool("tun")) { text = "Туннель активен"; soft = "OkSoft"; strong = "Ok"; } else { text = "Только локальный прокси"; soft = "WarnSoft"; strong = "Warn"; } break;
                case "connecting": text = "Подключение…"; soft = "WarnSoft"; strong = "Warn"; break;
                case "error": text = "Нет подключения"; soft = "BadSoft"; strong = "Bad"; break;
                default: text = "VPN выключен"; soft = "Chip"; strong = "Muted"; break;
            }
            AdvPillText.Text = text;
            AdvPill.SetResourceReference(Border.BackgroundProperty, soft);
            AdvPillText.SetResourceReference(TextBlock.ForegroundProperty, strong);
            AdvPillDot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, strong);

            AdvFacts.Inlines.Clear();
            void Fact(string label, string value)
            {
                if (AdvFacts.Inlines.Count > 0) AdvFacts.Inlines.Add(new System.Windows.Documents.Run("      "));
                AdvFacts.Inlines.Add(new System.Windows.Documents.Run(label));
                var b = new System.Windows.Documents.Run(value) { FontWeight = FontWeights.SemiBold };
                b.SetResourceReference(TextElement.ForegroundProperty, "Text");
                AdvFacts.Inlines.Add(b);
            }
            if (st == "on") Fact("Сервер: ", status.Str("node") + (status.Str("spare").Length > 0 ? " (запасной: " + status.Str("spare") + ")" : ""));
            if (settings != null)
            {
                Fact("Остальной трафик: ", settings.Str("default") == "direct" ? "напрямую" : "через VPN");
                Fact("Локальный прокси: ", "127.0.0.1:" + settings.Obj("ports").Int("proxy"));
            }
        }

        private async void AppToggleClick(object sender, RoutedEventArgs e)
        {
            var cb = (CheckBox)sender;
            var name = (string)cb.Tag;
            await Send(new JObj().Set("cmd", "set_app").Set("name", name).Set("processes", new List<string>()).Set("vpn", cb.IsChecked == true));
            await LoadSettings();
        }

        private async void RemoveAppClick(object sender, RoutedEventArgs e)
        {
            await Send(new JObj().Set("cmd", "remove_app").Set("name", (string)((Button)sender).Tag));
            await LoadSettings();
        }

        private async void AddAppFileClick(object sender, RoutedEventArgs e)
        {
            var dlg = new Microsoft.Win32.OpenFileDialog { Filter = "Программы (*.exe)|*.exe", Title = "Выберите программу" };
            if (dlg.ShowDialog(this) != true) return;
            var exe = Path.GetFileName(dlg.FileName);
            var vpn = MessageBox.Show(this, "Пускать «" + exe + "» через VPN?\n\nДа — через VPN, Нет — напрямую.", "VlessClient", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;
            await Send(new JObj().Set("cmd", "set_app").Set("name", Path.GetFileNameWithoutExtension(exe)).Set("processes", new List<string> { exe }).Set("vpn", vpn));
            await LoadSettings();
        }

        // ------------------------------------------------------------------ advanced: sites, servers, mode

        private async void DomainAddClick(object sender, RoutedEventArgs e)
        {
            var list = (string)((Button)sender).Tag;
            var box = list == "direct" ? DirectInput : ProxyInput;
            var value = box.Text.Trim();
            if (value.Length == 0) return;
            var r = await Send(new JObj().Set("cmd", "set_domain").Set("list", list).Set("op", "add").Set("value", value));
            if (r.Bool("ok")) box.Text = "";
            await LoadSettings();
        }

        private async void ChipRemoveClick(object sender, RoutedEventArgs e)
        {
            if (!(((Button)sender).Tag is ChipVm c)) return;
            await Send(new JObj().Set("cmd", "set_domain").Set("list", c.List).Set("op", "remove").Set("value", c.Value));
            await LoadSettings();
        }

        private void ThemeClick(object sender, RoutedEventArgs e)
        {
            var dark = (string)((RadioButton)sender).Tag == "dark";
            Theme.Dark = dark;
            Theme.Apply(dark);
            if (status != null) RenderAdvancedHeader(status.Str("state"));
            UpdateHeaders();
        }

        private async void TestNodesClick(object sender, RoutedEventArgs e)
        {
            TestNodesButton.IsEnabled = false;
            NodesHint.Text = "Проверяю все серверы, это займёт до 15 секунд…";
            try
            {
                var r = await Send(ServiceClient.Cmd("test_nodes"), 90000);
                if (!r.Bool("ok")) return;
                NodesGrid.ItemsSource = r.Objects("results").Select(x => new NodeRow
                {
                    Index = x.Int("index"), Name = x.Str("name"), Kind = x.Str("kind"),
                    Result = x.Bool("ok") ? x.Int("ms") + " мс" : "не работает",
                    Sort = x.Bool("ok") ? x.Int("ms") : 1000000 + x.Int("index"),
                }).OrderBy(x => x.Sort).ToList();
                NodesHint.Text = "Готово. Время — полный запрос через сервер; меньше — лучше.";
            }
            finally { TestNodesButton.IsEnabled = true; }
        }

        private async void AutoExcludeClick(object sender, RoutedEventArgs e)
        {
            await Send(new JObj().Set("cmd", "set_option").Set("key", "auto_exclude").Set("value", AutoExcludeInput.Text.Trim()));
            await LoadSettings();
        }

        private async void DefaultClick(object sender, RoutedEventArgs e)
        {
            if (suppress) return;
            await Send(new JObj().Set("cmd", "set_option").Set("key", "default").Set("value", (string)((RadioButton)sender).Tag));
        }
    }
}
