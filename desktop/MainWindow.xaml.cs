using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;

namespace VlessClient
{
    public partial class MainWindow : Window
    {
        private readonly DesktopBackend backend = new DesktopBackend();
        private readonly DispatcherTimer poll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1500) };
        private DesktopState state;
        private Reply settings;
        private bool loaded;
        private bool busy;
        private bool refreshing;
        private bool closed;

        public MainWindow()
        {
            InitializeComponent();
            poll.Tick += async (sender, args) => await RefreshAsync();
        }

        private async void WindowLoaded(object sender, RoutedEventArgs e)
        {
            loaded = true;
            await RefreshAsync();
            if (state?.configured == false)
            {
                Pages.SelectedItem = SettingsPage;
                SubscriptionUrl.Focus();
            }
            if (!closed) poll.Start();
        }

        private void WindowClosed(object sender, EventArgs e)
        {
            closed = true;
            poll.Stop();
            backend.Dispose();
        }

        private async Task<Reply> SendAsync(string action, object data)
        {
            var reply = await backend.SendAsync(action, data);
            if (reply == null || !reply.ok) throw new InvalidOperationException(ErrorText(reply?.error));
            return reply;
        }

        private async Task ReadStateAsync()
        {
            var reply = await SendAsync("state", new { all = AllProcesses.IsChecked == true });
            if (closed) return;
            state = reply.state;
            RenderState();
        }

        private async Task RefreshAsync()
        {
            if (busy || refreshing || closed) return;
            refreshing = true;
            try { await ReadStateAsync(); }
            catch (Exception ex)
            {
                if (!closed)
                {
                    ConnectionStatus.Text = "Не удалось прочитать состояние";
                    ConnectionDetail.Text = ex.Message;
                    StatusDot.Fill = (Brush)FindResource("Danger");
                }
            }
            finally { refreshing = false; }
        }

        private async Task RunAsync(Func<Task> action, string progress = "Применяем изменения…", string success = "Готово")
        {
            if (busy || closed) return;
            busy = true;
            RenderControls();
            SetFeedback(progress);
            try
            {
                await action();
                if (!closed) SetFeedback(success);
            }
            catch (Exception ex)
            {
                if (!closed) SetFeedback(ex.Message, true);
            }
            finally
            {
                busy = false;
                if (!closed) RenderControls();
            }
        }

        private void SetFeedback(string message, bool error = false)
        {
            Feedback.Text = message;
            Feedback.Foreground = (Brush)FindResource(error ? "Danger" : "Muted");
        }

        private void RenderControls()
        {
            ConnectButton.IsEnabled = !busy && state != null;
            RestartButton.IsEnabled = !busy && state?.status.running == true;
            SaveButton.IsEnabled = !busy && settings != null;
            AutostartButton.IsEnabled = !busy && settings != null;
            var exe = (ProcessGrid.SelectedItem as ProcessRow)?.name;
            ProcessVpn.IsEnabled = ProcessDirect.IsEnabled =
                !busy && exe?.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) == true;
        }

        private void RenderState()
        {
            var status = state.status;
            ConnectButton.Tag = status.running ? "stop" : "start";
            ConnectButton.Content = status.running ? "Отключить" : "Подключить";
            var error = !string.IsNullOrWhiteSpace(status.error);
            var color = (Brush)FindResource(error ? "Danger" : status.ready ? "Ok" : "Muted");
            StatusDot.Fill = ConnectionStatus.Foreground = color;
            StatusPill.Background = (Brush)FindResource(error ? "DangerSoft" : status.ready ? "OkSoft" : "Control");
            ConnectionStatus.Text = error ? "Ошибка подключения" : status.ready ? "Подключено" :
                status.running ? "Подключение…" : "Отключено";
            var mode = status.tun || (!status.running && status.mode == "tun") ? "Системный туннель" : "Локальный прокси";
            ConnectionDetail.Text = error ? status.error :
                $"{mode}  ·  {status.proxy}  ·  {(status.node == "auto" ? "Автовыбор сервера" : status.node)}";
            ConnectionDetail.ToolTip = ConnectionDetail.Text;
            RenderProcesses();
            RefreshList(AppRules, state.apps, (a, b) => a.name == b.name && a.vpn == b.vpn &&
                a.running == b.running && a.processes.SequenceEqual(b.processes));
            RefreshList(DirectRules, state.domains.direct, (a, b) => a == b);
            RefreshList(ProxyRules, state.domains.proxy, (a, b) => a == b);
            RenderControls();
        }

        private void RenderProcesses()
        {
            if (state == null) return;
            var query = ProcessSearch.Text.Trim();
            var key = (ProcessGrid.SelectedItem as ProcessRow)?.key;
            var sort = ProcessGrid.Items.SortDescriptions.ToArray();
            var rows = state.rows;
            var filtered = rows
                .Where(r => r.name.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0 &&
                    (OnlyProblems.IsChecked != true || r.ProblemCount > 0))
                .OrderBy(r => r.name, StringComparer.CurrentCultureIgnoreCase).ToArray();
            var scroller = ProcessGrid.Template?.FindName("DG_ScrollViewer", ProcessGrid) as ScrollViewer;
            var offset = scroller?.VerticalOffset ?? 0;
            ProcessGrid.ItemsSource = filtered;
            if (sort.Length > 0)
            {
                var view = CollectionViewSource.GetDefaultView(ProcessGrid.ItemsSource);
                using (view.DeferRefresh())
                    foreach (var description in sort) view.SortDescriptions.Add(description);
            }
            ProcessGrid.SelectedItem = filtered.FirstOrDefault(r => r.key == key);
            if (offset > 0) scroller.ScrollToVerticalOffset(offset);
            TrafficSummary.Text = state.status.api
                ? $"↓ {rows.Sum(r => r.DownRate):F2}  ↑ {rows.Sum(r => r.UpRate):F2} Мбит/с  ·  " +
                  $"VPN {rows.Sum(r => r.rP) * 8d / 1000000:F2}  ·  Прям. {rows.Sum(r => r.rD) * 8d / 1000000:F2}"
                : "Ожидание статистики";
        }

        private static void RefreshList<T>(ListBox list, T[] entries, Func<T, T, bool> equals)
        {
            var previous = list.ItemsSource as T[];
            if (previous != null && previous.Length == entries.Length && previous.Zip(entries, equals).All(x => x))
                return;
            var selected = list.SelectedValue;
            list.ItemsSource = entries;
            list.SelectedValue = selected;
        }

        private void ProcessSearchChanged(object sender, TextChangedEventArgs e)
        {
            if (loaded) RenderProcesses();
        }

        private void ProcessFilterClick(object sender, RoutedEventArgs e) => RenderProcesses();

        private void ProcessSelected(object sender, SelectionChangedEventArgs e)
        {
            if (!loaded) return;
            var row = ProcessGrid.SelectedItem as ProcessRow;
            ProcessDetails.Visibility = row == null ? Visibility.Collapsed : Visibility.Visible;
            DetailTitle.Text = row?.name;
            DetailTitle.ToolTip = row?.path;
            DetailSummary.Text = row == null ? "" :
                $"VPN {FormatBytes(row.pBytes)} · Напрямую {FormatBytes(row.dBytes)}\nБез ответа: {row.fail} · UDP: {row.udp}";
            Destinations.ItemsSource = row == null ? null : row.hosts
                .Select(h => $"{h.host} · {(h.@out == "direct" ? "напрямую" : "VPN")} · {FormatBytes(h.up + h.down)}")
                .Concat(row.fails.Select(f => $"{f.dest} · {(f.udp ? "UDP" : "нет ответа")} · {f.reason} ×{f.n}"))
                .ToArray();
            RenderControls();
        }

        private async void ControlClick(object sender, RoutedEventArgs e)
        {
            var op = (string)((Button)sender).Tag;
            if (op == "start" && state?.configured == false)
            {
                Pages.SelectedItem = SettingsPage;
                SubscriptionUrl.Focus();
                return;
            }
            await RunAsync(async () => { await SendAsync("control", new { op }); await ReadStateAsync(); },
                op == "stop" ? "Отключаем…" : "Подключаем…");
        }

        private async void RefreshClick(object sender, RoutedEventArgs e) => await RefreshAsync();

        private async void ResetClick(object sender, RoutedEventArgs e) =>
            await RunAsync(async () => { await SendAsync("reset", new { }); await ReadStateAsync(); });

        private async Task SetRuleAsync(string name, string[] processes, bool vpn)
        {
            await RunAsync(async () =>
            {
                await SendAsync("app", new { op = "set", name, processes, vpn });
                await ReadStateAsync();
            });
        }

        private async void RouteClick(object sender, RoutedEventArgs e)
        {
            if (!(ProcessGrid.SelectedItem is ProcessRow row)) return;
            var rule = state.apps.FirstOrDefault(a => a.name == row.app);
            await SetRuleAsync(rule?.name ?? Path.GetFileNameWithoutExtension(row.name),
                rule?.processes ?? new[] { row.name }, (string)((Button)sender).Tag == "vpn");
        }

        private async void AddRuleClick(object sender, RoutedEventArgs e)
        {
            if (busy) return;
            var exe = NewExe.Text.Trim();
            if (exe.Length == 0) { NewExe.Focus(); return; }
            if (!exe.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) exe += ".exe";
            var name = exe.Substring(0, exe.Length - 4);
            var vpn = (string)((Button)sender).Tag == "vpn";
            await RunAsync(async () =>
            {
                await SendAsync("app", new { op = "set", name, processes = new[] { exe }, vpn });
                NewExe.Clear();
                await ReadStateAsync();
                AppRules.SelectedValue = name;
            });
        }

        private async void ToggleRuleClick(object sender, RoutedEventArgs e)
        {
            var toggle = (ToggleButton)sender;
            if (!(toggle.DataContext is AppRule rule)) return;
            toggle.SetCurrentValue(ToggleButton.IsCheckedProperty, rule.vpn);
            await SetRuleAsync(rule.name, rule.processes, !rule.vpn);
        }

        private async void RemoveRuleClick(object sender, RoutedEventArgs e)
        {
            if (!(((Button)sender).DataContext is AppRule rule)) return;
            await RunAsync(async () => { await SendAsync("app", new { op = "remove", name = rule.name }); await ReadStateAsync(); });
        }

        private async void DomainClick(object sender, RoutedEventArgs e)
        {
            var parts = ((string)((Button)sender).Tag).Split(':');
            var list = parts[0];
            var op = parts[1];
            var input = list == "direct" ? DirectEntry : ProxyEntry;
            var rules = list == "direct" ? DirectRules : ProxyRules;
            var value = op == "add" ? input.Text.Trim() : rules.SelectedItem as string;
            if (string.IsNullOrEmpty(value)) return;
            await RunAsync(async () =>
            {
                await SendAsync("domain", new { op, list, value });
                if (op == "add") input.Clear();
                await ReadStateAsync();
            });
        }

        private async void TabChanged(object sender, SelectionChangedEventArgs e)
        {
            if (loaded && e.Source == Pages && Pages.SelectedItem == SettingsPage)
                await RunAsync(ReadSettingsAsync, "Загрузка настроек…", "");
        }

        private async Task ReadSettingsAsync()
        {
            var reply = await SendAsync("settings", new { });
            if (closed) return;
            settings = reply;
            var choices = new List<Choice> { new Choice("auto", "Автоматически") };
            choices.AddRange(settings.nodes.Select(n => new Choice(n.index.ToString(), $"{n.index}. {n.name}")));
            var selected = settings.node;
            if (!choices.Any(c => c.Value == selected)) choices.Add(new Choice(selected, selected));
            NodePicker.ItemsSource = choices;
            NodePicker.SelectedValue = selected;
            ModePicker.SelectedValue = settings.mode;
            DefaultPicker.SelectedValue = settings.@default;
            AllowInsecure.IsChecked = settings.insecureTls;
            SubscriptionHint.Text = settings.configured
                ? "Ссылка сохранена. Введите новую, чтобы заменить её."
                : "Вставьте ссылку на подписку VLESS (https://…).";
            AutostartButton.Content = settings.autostart ? "Выключить автозапуск" : "Включить автозапуск";
        }

        private async void SaveClick(object sender, RoutedEventArgs e)
        {
            var url = SubscriptionUrl.Password;
            if (settings?.configured == false && string.IsNullOrWhiteSpace(url))
            {
                SetFeedback("Вставьте ссылку на подписку.", true);
                SubscriptionUrl.Focus();
                return;
            }
            await RunAsync(async () =>
            {
                await SendAsync("save-settings", new
                {
                    url,
                    mode = ModePicker.SelectedValue,
                    @default = DefaultPicker.SelectedValue,
                    node = NodePicker.SelectedValue,
                    insecureTls = AllowInsecure.IsChecked == true
                });
                if (closed) return;
                SubscriptionUrl.Clear();
                await ReadSettingsAsync();
                await ReadStateAsync();
            }, "Сохраняем настройки…", "Настройки сохранены");
        }

        private async void UpdateClick(object sender, RoutedEventArgs e) =>
            await RunAsync(async () => { await SendAsync("update", new { }); await ReadSettingsAsync(); await ReadStateAsync(); },
                "Обновляем подписку…", "Подписка обновлена");

        private async void AutostartClick(object sender, RoutedEventArgs e) =>
            await RunAsync(async () => { await SendAsync("autostart", new { enabled = !settings.autostart }); await ReadSettingsAsync(); });

        private async void ImportSettingsClick(object sender, RoutedEventArgs e)
        {
            if (busy || settings == null) return;
            if (state?.status.running == true)
            {
                SetFeedback("Отключите клиент перед импортом настроек.", true);
                return;
            }
            var dialog = new Microsoft.Win32.OpenFileDialog
            {
                Title = "Выберите настройки VlessClient",
                Filter = "Настройки VlessClient (*.json)|*.json",
                FileName = "settings.json",
                CheckFileExists = true
            };
            if (dialog.ShowDialog(this) != true) return;
            if (settings.configured &&
                MessageBox.Show(this, "Заменить текущие настройки выбранным файлом?", "Импорт",
                    MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;

            await RunAsync(async () =>
            {
                await SendAsync("import-settings", new { path = dialog.FileName });
                if (closed) return;
                SubscriptionUrl.Clear();
                await ReadSettingsAsync();
                await ReadStateAsync();
            }, "Импортируем настройки…", "Настройки импортированы");
        }

        private void OpenSettingsClick(object sender, RoutedEventArgs e)
        {
            if (settings?.path == null) return;
            try { Process.Start(new ProcessStartInfo(Path.GetDirectoryName(settings.path)) { UseShellExecute = true }); }
            catch (Win32Exception ex) { SetFeedback(ex.Message, true); }
        }

        internal static string FormatBytes(long bytes)
        {
            if (bytes < 1024) return $"{bytes} Б";
            if (bytes < 1024L * 1024) return $"{bytes / 1024d:F1} КБ";
            if (bytes < 1024L * 1024 * 1024) return $"{bytes / 1048576d:F1} МБ";
            return $"{bytes / 1073741824d:F1} ГБ";
        }

        private static string ErrorText(string error)
        {
            switch (error)
            {
                case "bad-exe": return "Введите имя файла .exe без пути.";
                case "bad-name": return "Имя правила слишком длинное.";
                case "bad-value": return "Введите домен, IP-адрес или сеть в формате CIDR.";
                case "bad-subscription": return "Ссылка на подписку должна начинаться с http:// или https://.";
                case "bad-import": return "Выберите действительный settings.json от VlessClient.";
                case "stop-before-import": return "Отключите клиент перед импортом настроек.";
                case "subscription-required": return "Добавьте ссылку на подписку в настройках.";
                case "subscription-fetch": return "Не удалось загрузить VLESS-серверы. Проверьте ссылку и настройки TLS.";
                case "elevation-declined":
                case "elevation-required": return "Для системного туннеля подтвердите запрос Windows на права администратора.";
                case "elevation-account": return "Подтвердите запрос Windows от имени текущего пользователя.";
                case "start-timeout": return "Запуск клиента занял слишком много времени.";
                case "start-failed": return "Ядра не запустились. Подробности в runtime\\daemon.log.";
                case "stop-failed": return "Не удалось остановить клиент.";
                default: return string.IsNullOrWhiteSpace(error) ? "Не удалось выполнить действие." : error;
            }
        }

        private sealed class Choice
        {
            public Choice(string value, string label) { Value = value; Label = label; }
            public string Value { get; }
            public string Label { get; }
            public override string ToString() => Label;
        }
    }
}
