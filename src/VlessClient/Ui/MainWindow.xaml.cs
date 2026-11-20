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
using System.Windows.Media;
using System.Windows.Threading;
using VlessClient.Core;

namespace VlessClient.Ui
{
    public sealed class AppVm
    {
        public string Name { get; set; }
        public bool Vpn { get; set; }
        public string ProcessText { get; set; }
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
        private readonly ObservableCollection<TrafficRow> trafficRows = new ObservableCollection<TrafficRow>();
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
            TrafficGrid.ItemsSource = trafficRows;
            var view = (ListCollectionView)CollectionViewSource.GetDefaultView(trafficRows);
            view.SortDescriptions.Add(new SortDescription("SpeedSort", ListSortDirection.Descending));
            view.SortDescriptions.Add(new SortDescription("TotalBytes", ListSortDirection.Descending));
            view.IsLiveSorting = true;
            view.LiveSortingProperties.Add("SpeedSort");
            view.LiveSortingProperties.Add("TotalBytes");
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
            if (page == AdvancedPage && AdvancedTabs.SelectedIndex == 0) { traffic.Reset(); trafficRows.Clear(); trafficTimer.Start(); }
            else trafficTimer.Stop();
            if (page == AdvancedPage) { Width = Math.Max(Width, 900); Height = Math.Max(Height, 640); }
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
                    if (status.Str("mode") == "apps")
                        hint += status.Int("apps_count") > 0
                            ? "\nЧерез VPN идут только выбранные программы: " + status.Int("apps_count")
                            : "\nНи одной программе не задано «через VPN» — откройте «Для продвинутых → Программы»";
                    else if (!status.Bool("tun")) hint += "\nТолько локальный прокси — системный туннель недоступен";
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
                var count = status?.Objects("nodes").Count ?? 0;
                SubInfo.Text = sub.Bool("inline")
                    ? "Серверы вставлены вручную: " + count + "\nЧтобы обновить их, нажмите «Изменить ссылку»."
                    : "Сервер подписки: " + host + "\nСерверов в подписке: " + count +
                      (subTime.Length > 0 && DateTime.TryParse(subTime, out var t) ? "\nОбновлена: " + t.ToString("dd.MM.yyyy HH:mm") : "");
                RuDirectBox.IsChecked = settings.Obj("ru_direct").Bool("enabled", true);
                AutoUpdateBox.IsChecked = settings.Bool("auto_update");
                lastNodesKey = "";
                RenderNodeChoices();

                var apps = settings.Objects("apps").Select(a => new AppVm { Name = a.Str("name"), Vpn = a.Bool("vpn"), ProcessText = string.Join(", ", a.Strings("processes")) }).ToList();
                AppsList.ItemsSource = apps;
                var rules = settings.Obj("rules");
                DirectList.ItemsSource = rules.Strings("direct_domains").Concat(rules.Strings("direct_ips")).ToList();
                ProxyList.ItemsSource = rules.Strings("proxy_domains").Concat(rules.Strings("proxy_ips")).ToList();
                AutoExcludeInput.Text = settings.Str("auto_exclude");
                var mode = settings.Str("mode", "tun");
                ModeTun.IsChecked = mode == "tun";
                ModeApps.IsChecked = mode == "apps";
                ModeProxy.IsChecked = mode == "proxy";
                DefaultProxy.IsChecked = settings.Str("default") != "direct";
                DefaultDirect.IsChecked = settings.Str("default") == "direct";
                ProxyInfo.Text = "Локальный прокси (SOCKS5 и HTTP): 127.0.0.1:" + settings.Obj("ports").Int("proxy") + " — работает во всех режимах.";
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
                items.AddRange(nodes.Select(n => new KeyValuePair<string, string>(n.Int("index").ToString(), n.Int("index") + ". " + n.Str("name"))));
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

        private async Task SampleTraffic()
        {
            if (sampling || settings == null) return;
            sampling = true;
            try
            {
                var api = settings.Obj("api");
                if (api == null) return;
                if (!await traffic.SampleAsync(api.Int("port"), api.Str("secret"))) return;
                var apps = settings.Objects("apps");
                traffic.Apply(trafficRows, exe =>
                {
                    var a = apps.FirstOrDefault(x => x.Strings("processes").Any(p => p.Equals(exe, StringComparison.OrdinalIgnoreCase)));
                    return a == null ? "" : a.Bool("vpn") ? "через VPN" : "напрямую";
                });
                TrafficEmpty.Visibility = trafficRows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            }
            finally { sampling = false; }
        }

        private void TrafficSorting(object sender, DataGridSortingEventArgs e)
        {
            var view = (ListCollectionView)CollectionViewSource.GetDefaultView(trafficRows);
            var prop = e.Column.SortMemberPath;
            if (!view.LiveSortingProperties.Contains(prop)) view.LiveSortingProperties.Add(prop);
        }

        private async void RouteSelectedClick(object sender, RoutedEventArgs e)
        {
            if (!(TrafficGrid.SelectedItem is TrafficRow row) || row.Exe.StartsWith("(")) { MessageBox.Show(this, "Выберите программу в таблице.", "VlessClient"); return; }
            var vpn = (string)((Button)sender).Tag == "vpn";
            var existing = settings?.Objects("apps").FirstOrDefault(a => a.Strings("processes").Any(p => p.Equals(row.Exe, StringComparison.OrdinalIgnoreCase)));
            var name = existing?.Str("name") ?? Path.GetFileNameWithoutExtension(row.Exe);
            var procs = existing?.Strings("processes") ?? new List<string> { row.Exe };
            await Send(new JObj().Set("cmd", "set_app").Set("name", name).Set("processes", procs).Set("vpn", vpn));
            await LoadSettings();
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

        private async void DomainClick(object sender, RoutedEventArgs e)
        {
            var parts = ((string)((Button)sender).Tag).Split(':');
            var list = parts[0]; var op = parts[1];
            string value;
            if (op == "add") { var box = list == "direct" ? DirectInput : ProxyInput; value = box.Text.Trim(); if (value.Length == 0) return; box.Text = ""; }
            else { value = (list == "direct" ? DirectList : ProxyList).SelectedItem as string; if (value == null) return; }
            await Send(new JObj().Set("cmd", "set_domain").Set("list", list).Set("op", op).Set("value", value));
            await LoadSettings();
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

        private async void ModeClick(object sender, RoutedEventArgs e)
        {
            if (suppress) return;
            await Send(new JObj().Set("cmd", "set_option").Set("key", "mode").Set("value", (string)((RadioButton)sender).Tag));
        }

        private async void DefaultClick(object sender, RoutedEventArgs e)
        {
            if (suppress) return;
            await Send(new JObj().Set("cmd", "set_option").Set("key", "default").Set("value", (string)((RadioButton)sender).Tag));
        }
    }
}
