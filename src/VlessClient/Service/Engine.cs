using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using VlessClient.Core;

namespace VlessClient.Service
{
    /// <summary>The VPN itself: subscription, node choice, cores, supervision. Runs inside the Windows service.</summary>
    public sealed class Engine : IDisposable
    {
        public enum State { Off, Connecting, On, Error, NoSubscription }

        private readonly object gate = new object();
        private readonly SemaphoreSlim op = new SemaphoreSlim(1);
        private Settings settings;
        private State state = State.Off;
        private string message = "";
        private string error = "";
        private Node mainNode, spareNode;
        private bool tunActive;
        private DateTime since;
        private List<Node> nodes = new List<Node>();
        private List<string> warnings = new List<string>();
        private Process xray, singbox;
        private JobObject job;
        private Timer timer;
        private CancellationTokenSource connectCts;
        private int crashCount;
        private DateTime firstCrash;
        private DateTime nextRetry = DateTime.MaxValue;
        private DateTime nextSubCheck = DateTime.MinValue;
        private List<ProbeResult> lastProbe;
        public readonly Updater Updater = new Updater();

        public static bool IsElevated
        {
            get { using (var id = WindowsIdentity.GetCurrent()) return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator); }
        }

        public void Start()
        {
            settings = Settings.Load();
            try { settings.Save(); } catch (Exception e) { Log.Write("settings: cannot save: " + e.Message); }
            nodes = Subscription.LoadCached(settings);
            KillOrphans();
            try { job = new JobObject(); Prober.Job = job; } catch (Exception e) { Log.Write("job object: " + e.Message); }
            Log.Write($"engine: started, version {Updater.CurrentVersion}, elevated={IsElevated}, enabled={settings.Enabled}");
            if (IsElevated) OldComponents.RemoveInBackground();
            if (!settings.HasSubscription) SetState(State.NoSubscription, "Нужна ссылка на подписку");
            else if (settings.Enabled) BeginConnect();
            timer = new Timer(_ => Tick(), null, 2000, 2000);
        }

        public void Shutdown()
        {
            timer?.Dispose();
            connectCts?.Cancel();
            StopCores();
            job?.Dispose();
            Log.Write("engine: stopped");
        }

        public void Dispose() => Shutdown();

        // ------------------------------------------------------------------ status

        public JObj Status()
        {
            lock (gate)
            {
                var st = new JObj()
                    .Set("state", state.ToString().ToLowerInvariant())
                    .Set("message", message)
                    .Set("error", error)
                    .Set("enabled", settings.Enabled)
                    .Set("has_subscription", settings.HasSubscription)
                    .Set("node", mainNode?.Name ?? "")
                    .Set("spare", spareNode?.Name ?? "")
                    .Set("tun", tunActive)
                    .Set("since", state == State.On ? since.ToString("s") : "")
                    .Set("warnings", warnings.ToList())
                    .Set("version", Updater.CurrentVersion.ToString(3))
                    .Set("update", Updater.StatusJson())
                    .Set("nodes", nodes.Select(n => (object)new JObj().Set("index", n.Index).Set("name", n.Name).Set("kind", n.Kind).Set("group", n.Group)).ToList())
                    .Set("backups", settings.Backups.Select((b, k) => (object)new JObj()
                        .Set("url", b.Url).Set("host", b.Host)
                        .Set("count", nodes.Count(n => n.Group == k + 1))
                        .Set("time", Subscription.BackupTime(b) == DateTime.MinValue ? "" : Subscription.BackupTime(b).ToString("s"))
                        .Set("error", backupErrors.TryGetValue(b.Url, out var be) ? be : "")).ToList())
                    .Set("subscription_time", Subscription.CacheTime == DateTime.MinValue ? "" : Subscription.CacheTime.ToString("s"));
                return st;
            }
        }

        public JObj SettingsView()
        {
            lock (gate)
            {
                var j = settings.ToJson();
                j.Remove("api_secret");
                j.Set("api", new JObj().Set("port", settings.ApiPort).Set("secret", settings.ApiSecret));
                j.Set("elevated", IsElevated);
                return j;
            }
        }

        private void SetState(State s, string msg, string err = "")
        {
            lock (gate)
            {
                if (state != s || message != msg) Log.Write($"state: {s} {msg} {err}".TrimEnd());
                state = s; message = msg; error = err;
                if (s == State.On) since = DateTime.Now;
            }
        }

        // ------------------------------------------------------------------ commands

        public void Connect()
        {
            lock (gate) { settings.Enabled = true; SaveSettings(); }
            BeginConnect();
        }

        public void Disconnect()
        {
            connectCts?.Cancel();
            lock (gate) { settings.Enabled = false; SaveSettings(); nextRetry = DateTime.MaxValue; }
            op.Wait();
            try { StopCores(); } finally { op.Release(); }
            SetState(settings.HasSubscription ? State.Off : State.NoSubscription, settings.HasSubscription ? "VPN выключен" : "Нужна ссылка на подписку");
            lock (gate) { mainNode = null; spareNode = null; tunActive = false; }
        }

        public async Task<string> SetSubscriptionAsync(string url, bool insecure)
        {
            url = (url ?? "").Trim();
            // Fallback for networks where the subscription server is unreachable: the servers themselves, pasted as vless:// lines.
            if (url.IndexOf("vless://", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                var list = Subscription.Decode(url);
                if (list == null || !list.Split('\n').Any(l => Node.Parse(l) != null)) return "Не нашёл ни одного сервера vless:// во вставленном тексте.";
                File.WriteAllText(Paths.SubscriptionCache, list, Paths.Utf8);
                lock (gate)
                {
                    settings.SubscriptionUrl = ""; settings.InlineNodes = true; settings.LastGoodNode = ""; settings.Enabled = true;
                    SaveSettings();
                    nodes = Subscription.LoadCached(settings);
                }
                Log.Write($"subscription: {nodes.Count} servers pasted directly");
                BeginConnect();
                return null;
            }
            if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || (u.Scheme != "https" && u.Scheme != "http"))
                return "Это не похоже на ссылку подписки. Она должна начинаться с https://";
            var test = settings.Clone();
            test.SubscriptionUrl = url; test.InsecureTls = insecure;
            string body;
            try { body = await Subscription.FetchAsync(test).ConfigureAwait(false); }
            catch (Exception e)
            {
                var m = Flatten(e);
                if (!insecure && (m.IndexOf("SSL", StringComparison.OrdinalIgnoreCase) >= 0 || m.IndexOf("trust", StringComparison.OrdinalIgnoreCase) >= 0
                                  || m.IndexOf("certificate", StringComparison.OrdinalIgnoreCase) >= 0 || m.IndexOf("сертификат", StringComparison.OrdinalIgnoreCase) >= 0))
                {
                    // Many self-hosted panels use a self-signed certificate: retry once without checking it.
                    test.InsecureTls = true;
                    try { body = await Subscription.FetchAsync(test).ConfigureAwait(false); insecure = true; }
                    catch (Exception e2) { return "Не удалось загрузить подписку: " + Flatten(e2); }
                }
                else return "Не удалось загрузить подписку: " + m;
            }
            if (body == null) return "По ссылке нет серверов VLESS.";
            File.WriteAllText(Paths.SubscriptionCache, body, Paths.Utf8);
            lock (gate)
            {
                settings.SubscriptionUrl = url; settings.InlineNodes = false; settings.InsecureTls = insecure; settings.LastGoodNode = "";
                settings.Enabled = true;
                SaveSettings();
                nodes = Subscription.LoadCached(settings);
            }
            Log.Write($"subscription: set, {nodes.Count} nodes, insecure_tls={insecure}");
            BeginConnect();
            return null;
        }

        public async Task<string> RefreshSubscriptionAsync()
        {
            var s = SettingsCopy();
            if (!s.HasSubscription) return "Подписка не задана";
            if (!s.CanDownload && s.Backups.Count == 0)
                return "Серверы были вставлены вручную, скачивать нечего. Чтобы обновить их, нажмите «Изменить ссылку» и вставьте новые.";
            string old; lock (gate) old = NodesSignature(nodes);
            var err = await DownloadAllAsync(s).ConfigureAwait(false);
            string now; lock (gate) now = NodesSignature(nodes);
            if (old != now && s.Enabled) { Log.Write("subscription: changed, reconnecting"); BeginConnect(); }
            List<string> failed; lock (gate) failed = s.Backups.Where(b => backupErrors.ContainsKey(b.Url)).Select(b => b.Host).ToList();
            if (err != null)
                return s.Backups.Count == 0
                    ? "Не удалось обновить подписку: " + err
                    : "Основная подписка не загрузилась (" + err + "), остались прежние серверы. Запасные: " +
                      (failed.Count == 0 ? "обновлены." : "не загрузились " + string.Join(", ", failed) + ".");
            if (failed.Count > 0) return "Основная подписка обновлена, запасные не загрузились: " + string.Join(", ", failed) + ".";
            return null;
        }

        private static string NodesSignature(List<Node> list) =>
            string.Join("\n", list.Select(n => n.Group + "|" + n.Index + "|" + n.Address + "|" + n.Port + "|" + n.Id + "|" + n.Name + "|" +
                                               string.Join("&", n.Query.OrderBy(kv => kv.Key).Select(kv => kv.Key + "=" + kv.Value))));

        /// <summary>Why a backup subscription did not download last time (by link); absent when it did.</summary>
        private readonly Dictionary<string, string> backupErrors = new Dictionary<string, string>();

        private async Task<bool> DownloadBackupAsync(BackupSub b)
        {
            try
            {
                var body = await Subscription.FetchAsync(b.Url, b.Insecure).ConfigureAwait(false);
                if (body == null) { lock (gate) backupErrors[b.Url] = "по ссылке нет серверов VLESS"; return false; }
                File.WriteAllText(Subscription.BackupCache(b), body, Paths.Utf8);
                lock (gate) backupErrors.Remove(b.Url);
                return true;
            }
            catch (Exception e)
            {
                lock (gate) backupErrors[b.Url] = Flatten(e);
                Log.Write("subscription: backup " + b.Host + " failed: " + Flatten(e));
                return false;
            }
        }

        /// <summary>Downloads the main subscription (when it is a link) and every backup; whatever fails keeps its cached copy.
        /// Returns the main subscription's error, null when it downloaded or is not a link.</summary>
        private async Task<string> DownloadAllAsync(Settings s)
        {
            string mainError = null;
            if (s.CanDownload)
            {
                try
                {
                    var body = await Subscription.FetchAsync(s).ConfigureAwait(false);
                    if (body == null) mainError = "по ссылке нет серверов VLESS";
                    else File.WriteAllText(Paths.SubscriptionCache, body, Paths.Utf8);
                }
                catch (Exception e) { mainError = Flatten(e); Log.Write("subscription: fetch failed: " + mainError); }
            }
            await Task.WhenAll(s.Backups.Select(DownloadBackupAsync)).ConfigureAwait(false);
            lock (gate) nodes = Subscription.LoadCached(settings);
            return mainError;
        }

        /// <summary>Adds a backup subscription link. It is saved even when it does not download right now: a backup is often
        /// meant for a network where the main one is blocked. Returns null and a message, or an error (nothing saved).</summary>
        public async Task<(string error, string message)> AddBackupAsync(string url)
        {
            url = (url ?? "").Trim();
            if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || (u.Scheme != "https" && u.Scheme != "http"))
                return ("Это не похоже на ссылку подписки. Она должна начинаться с https://", null);
            lock (gate)
                if (url == settings.SubscriptionUrl.Trim() || settings.Backups.Any(b => b.Url == url)) return ("Эта ссылка уже добавлена.", null);
            var backup = new BackupSub { Url = url };
            string body = null, err = null;
            try { body = await Subscription.FetchAsync(url, false).ConfigureAwait(false); }
            catch (Exception e)
            {
                err = Flatten(e);
                if (err.IndexOf("SSL", StringComparison.OrdinalIgnoreCase) >= 0 || err.IndexOf("trust", StringComparison.OrdinalIgnoreCase) >= 0
                    || err.IndexOf("certificate", StringComparison.OrdinalIgnoreCase) >= 0 || err.IndexOf("сертификат", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    // self-hosted panels often use a self-signed certificate: accept it for this link, as for the main one
                    try { body = await Subscription.FetchAsync(url, true).ConfigureAwait(false); backup.Insecure = true; err = null; }
                    catch (Exception e2) { err = Flatten(e2); }
                }
            }
            int added;
            lock (gate)
            {
                settings.Backups.Add(backup);
                SaveSettings();
                if (body != null) { File.WriteAllText(Subscription.BackupCache(backup), body, Paths.Utf8); backupErrors.Remove(url); }
                else backupErrors[url] = err ?? "по ссылке нет серверов VLESS";
                nodes = Subscription.LoadCached(settings);
                added = nodes.Count(n => n.Group == settings.Backups.Count);
            }
            Log.Write($"subscription: backup {backup.Host} added, {added} new servers, insecure_tls={backup.Insecure}, error={err}");
            if (body == null) return (null, "Сохранил, но сейчас она не загружается (" + (err ?? "по ссылке нет серверов VLESS") + "). Попробую при следующем обновлении.");
            return (null, added == 0
                ? "Сохранил. Это копия основной подписки: новых серверов в ней нет, но она выручит, если основная ссылка перестанет загружаться."
                : "Сохранил. Запасных серверов: " + added + ".");
        }

        public string RemoveBackup(string url)
        {
            bool onBackup, enabled;
            lock (gate)
            {
                var b = settings.Backups.FirstOrDefault(x => x.Url == url);
                if (b == null) return "Такой запасной подписки нет.";
                // later backups get new numbers, so a tunnel that runs on a backup server is rebuilt
                onBackup = (mainNode?.Group ?? 0) > 0;
                settings.Backups.Remove(b);
                SaveSettings();
                try { File.Delete(Subscription.BackupCache(b)); } catch { }
                backupErrors.Remove(url);
                nodes = Subscription.LoadCached(settings);
                enabled = settings.Enabled;
            }
            if (onBackup && enabled) BeginConnect();
            return null;
        }

        /// <summary>Applies a settings change from the UI. Rules are hot-reloaded; structural changes reconnect.</summary>
        public string Change(Action<Settings> change, bool needsReconnect)
        {
            lock (gate)
            {
                change(settings);
                SaveSettings();
            }
            try { SingBoxConfig.WriteUserRuleSets(settings); } catch (Exception e) { return "Не удалось записать правила: " + e.Message; }
            if (needsReconnect && settings.Enabled) BeginConnect();
            return null;
        }

        public async Task<List<ProbeResult>> TestNodesAsync()
        {
            var list = nodes.ToList();
            var res = await Prober.ProbeAsync(list).ConfigureAwait(false);
            lock (gate) lastProbe = res;
            return res;
        }

        private void SaveSettings()
        {
            try { settings.Save(); } catch (Exception e) { Log.Write("settings: cannot save: " + e.Message); }
        }

        public Settings SettingsCopy() { lock (gate) return settings.Clone(); }

        // ------------------------------------------------------------------ connect

        private void BeginConnect()
        {
            connectCts?.Cancel();
            var cts = new CancellationTokenSource();
            connectCts = cts;
            lock (gate) nextRetry = DateTime.MaxValue;
            Task.Run(() => ConnectAsync(cts.Token));
        }

        private async Task ConnectAsync(CancellationToken ct)
        {
            await op.WaitAsync().ConfigureAwait(false);
            try
            {
                if (ct.IsCancellationRequested) return;
                StopCores();
                var s = SettingsCopy();
                if (!s.HasSubscription) { SetState(State.NoSubscription, "Нужна ссылка на подписку"); return; }

                SetState(State.Connecting, "Загружаю список серверов…");
                bool empty; lock (gate) empty = nodes.Count == 0;
                // a backup that was never downloaded (or long ago) counts too: it is what saves the day when the main servers die
                if (empty || (DateTime.Now - Subscription.CacheTime).TotalHours > s.UpdateHours
                          || s.Backups.Any(b => (DateTime.Now - Subscription.BackupTime(b)).TotalHours > s.UpdateHours))
                    await DownloadAllAsync(s).ConfigureAwait(false);
                List<Node> all; lock (gate) all = nodes.ToList();
                if (all.Count == 0)
                {
                    Fail("Не удалось загрузить список серверов: сервер подписки не отвечает. Возможно, ваш интернет-провайдер его не пропускает. " +
                         "Добавьте запасную подписку в «Настройках» или попросите того, кто выдал подписку, прислать сами серверы (строки vless://) и вставьте их через «Настройки → Изменить ссылку».");
                    return;
                }
                if (ct.IsCancellationRequested) return;

                SingBoxConfig.WriteGeoRuleSets(s);
                SingBoxConfig.WriteUserRuleSets(s);
                lock (gate) warnings = NetInfo.ForeignTunnels(s).Select(t => "Включён другой VPN («" + t + "»). Выключите его, иначе интернет может не работать.").ToList();

                // candidates in order of preference; "auto" takes one subscription at a time: the main one, then each backup
                // in turn when none of the earlier ones answers
                var pinned = Subscription.FindPinned(s, all);
                List<Node> order = null;
                if (pinned != null)
                    order = new[] { pinned }.Concat(Subscription.AutoPool(s, all.Where(n => n.Group == pinned.Group).ToList()).Where(n => n.Index != pinned.Index)).ToList();
                else
                {
                    var probed = new List<ProbeResult>();
                    foreach (var g in Subscription.Groups(all))
                    {
                        var pool = Subscription.AutoPool(s, all.Where(n => n.Group == g).ToList());
                        if (pool.Count == 0) continue;
                        SetState(State.Connecting, g == 0 || g > s.Backups.Count
                            ? "Ищу самый быстрый сервер…"
                            : "Серверы не отвечают, пробую запасную подписку " + s.Backups[g - 1].Host + "…");
                        var probe = await Prober.ProbeAsync(pool).ConfigureAwait(false);
                        probed.AddRange(probe);
                        lock (gate) lastProbe = probed.ToList();
                        if (ct.IsCancellationRequested) return;
                        Log.Write($"probe (subscription {g}): " + string.Join(", ", probe.Select(r => $"{r.Node.Index}={(r.Ok ? r.Ms + "ms" : "fail")}")));
                        var reasons = probe.Where(r => !r.Ok).GroupBy(r => r.Error).Select(x => x.Key + " ×" + x.Count()).ToList();
                        if (reasons.Count > 0) Log.Write("probe failures: " + string.Join("; ", reasons));
                        var ok = probe.Where(r => r.Ok).ToList();
                        if (ok.Count == 0) continue;
                        // keep the node that worked last time unless another one is much faster: fewer surprises for the user
                        var last = ok.FirstOrDefault(r => r.Node.Name == s.LastGoodNode);
                        if (last != null && last.Ms <= ok[0].Ms * 1.5 + 100) ok = new[] { last }.Concat(ok.Where(r => r != last)).ToList();
                        order = ok.Select(r => r.Node).ToList();
                        break;
                    }
                    if (order == null) { Fail("Ни один сервер не отвечает. Возможно, нет интернета или провайдер их блокирует."); return; }
                }

                var tun = IsElevated;   // only a development run (--console) is not elevated
                if (!tun) Log.Write("engine: not elevated, local proxy only");
                foreach (var main in order.Take(3))
                {
                    if (ct.IsCancellationRequested) return;
                    var spare = order.FirstOrDefault(n => n.Index != main.Index);
                    SetState(State.Connecting, "Подключаюсь к серверу «" + main.Name + "»…");
                    var err = StartCores(s, all, main, spare, tun);
                    if (err == null)
                    {
                        try
                        {
                            await Prober.HttpThroughSocks(s.ProxyPort, 12000).ConfigureAwait(false);
                            lock (gate)
                            {
                                mainNode = main; spareNode = spare; tunActive = tun; crashCount = 0;
                                settings.LastGoodNode = main.Name; SaveSettings();
                            }
                            SetState(State.On, tun ? "VPN включён" : "VPN включён (только локальный прокси)");
                            return;
                        }
                        catch (Exception e) { err = "сервер «" + main.Name + "» не пропускает трафик: " + e.Message; }
                    }
                    Log.Write("connect: " + err);
                    StopCores();
                }
                Fail("Не удалось подключиться к серверу. Попробую ещё раз через минуту.");
            }
            catch (Exception e)
            {
                Log.Write("connect: unexpected: " + e);
                Fail("Ошибка: " + e.Message);
            }
            finally { op.Release(); }
        }

        private void Fail(string text)
        {
            StopCores();
            lock (gate) { mainNode = null; spareNode = null; tunActive = false; nextRetry = DateTime.Now.AddSeconds(60); }
            SetState(State.Error, text, text);
        }

        // ------------------------------------------------------------------ cores

        private string StartCores(Settings s, List<Node> all, Node main, Node spare, bool tun)
        {
            if (!File.Exists(Paths.XrayExe) || !File.Exists(Paths.SingBoxExe)) return "файлы ядер не найдены в " + Paths.BinDir;
            foreach (var port in new[] { s.ProxyPort, s.XrayPort, s.ApiPort })
                if (!NetInfo.IsPortFree(port)) return "порт " + port + " занят другой программой";

            var xrayCfg = Path.Combine(Paths.RuntimeDir, "xray.json");
            var sbCfg = Path.Combine(Paths.RuntimeDir, "sing-box.json");
            File.WriteAllText(xrayCfg, Json.Serialize(XrayConfig.Main(main, spare, s.XrayPort, Path.Combine(Paths.LogsDir, "xray.log")), true), Paths.Utf8);
            File.WriteAllText(sbCfg, Json.Serialize(SingBoxConfig.Build(s, tun, all, Path.Combine(Paths.LogsDir, "sing-box.log")), true), Paths.Utf8);
            RotateLog("xray.log"); RotateLog("sing-box.log");

            xray = Launch(Paths.XrayExe, "run -c \"" + xrayCfg + "\"");
            if (!WaitPort(s.XrayPort, xray, 8000)) return "xray не запустился (" + LastLine("xray.log") + ")";
            singbox = Launch(Paths.SingBoxExe, "run -c \"" + sbCfg + "\" -D \"" + Paths.RuntimeDir + "\"");
            if (!WaitPort(s.ApiPort, singbox, 15000)) return "sing-box не запустился (" + LastLine("sing-box.log") + ")";
            if (!WaitPort(s.ProxyPort, singbox, 3000)) return "sing-box не открыл локальный прокси";
            Log.Write($"cores: xray {xray.Id}, sing-box {singbox.Id}, node {main.Index} {main.Name}, spare {spare?.Index}, tun={tun}");
            return null;
        }

        private Process Launch(string exe, string args)
        {
            var p = Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Paths.RuntimeDir });
            try { job?.Add(p); } catch (Exception e) { Log.Write("job: cannot add process: " + e.Message); }
            return p;
        }

        private static bool WaitPort(int port, Process p, int ms)
        {
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < ms)
            {
                if (p.HasExited) return false;
                if (!NetInfo.IsPortFree(port)) return true;
                Thread.Sleep(150);
            }
            return false;
        }

        private void StopCores()
        {
            foreach (var p in new[] { singbox, xray })
            {
                if (p == null) continue;
                try { if (!p.HasExited) { p.Kill(); p.WaitForExit(5000); } } catch { }
                p.Dispose();
            }
            singbox = null; xray = null;
            lock (gate) tunActive = false;
        }

        /// <summary>Kills cores left from a previous run (started from our bin folder).</summary>
        private static void KillOrphans()
        {
            foreach (var name in new[] { "sing-box", "xray" })
                foreach (var p in Process.GetProcessesByName(name))
                {
                    try
                    {
                        var path = p.MainModule?.FileName ?? "";
                        if (path.StartsWith(Paths.BinDir, StringComparison.OrdinalIgnoreCase)) { p.Kill(); Log.Write("engine: killed orphan " + name + " " + p.Id); }
                    }
                    catch { }
                    finally { p.Dispose(); }
                }
        }

        private static void RotateLog(string name)
        {
            try
            {
                var f = Path.Combine(Paths.LogsDir, name);
                if (File.Exists(f) && new FileInfo(f).Length > 4 * 1024 * 1024) { var old = f + ".old"; if (File.Exists(old)) File.Delete(old); File.Move(f, old); }
            }
            catch { }
        }

        private static string LastLine(string log)
        {
            var t = Log.Tail(log, 3).Trim();
            var lines = t.Split('\n');
            return lines.Length > 0 ? lines[lines.Length - 1].Trim() : "";
        }

        // ------------------------------------------------------------------ supervision

        private void Tick()
        {
            try
            {
                State st; bool enabled; DateTime retry;
                lock (gate) { st = state; enabled = settings.Enabled; retry = nextRetry; }

                if (st == State.On && ((xray?.HasExited ?? true) || (singbox?.HasExited ?? true)))
                {
                    Log.Write($"supervisor: a core exited (xray={xray?.HasExited}, sing-box={singbox?.HasExited})");
                    if (crashCount == 0 || (DateTime.Now - firstCrash).TotalMinutes > 3) { firstCrash = DateTime.Now; crashCount = 0; }
                    crashCount++;
                    if (crashCount <= 3) RestartSameNode();
                    else { SetState(State.Connecting, "Переподключаюсь…"); BeginConnect(); }
                }
                else if (enabled && st == State.Error && DateTime.Now >= retry)
                {
                    BeginConnect();
                }

                if (DateTime.Now >= nextSubCheck)
                {
                    nextSubCheck = DateTime.Now.AddHours(1);
                    var s = SettingsCopy();
                    if (s.CanDownload && st == State.On && (DateTime.Now - Subscription.CacheTime).TotalHours > s.UpdateHours)
                        Task.Run(RefreshSubscriptionAsync);
                    if (s.AutoUpdate) Task.Run(() => Updater.AutoUpdateTickAsync());
                }
            }
            catch (Exception e) { Log.Write("supervisor: " + e.Message); }
        }

        private void RestartSameNode()
        {
            Task.Run(async () =>
            {
                await op.WaitAsync().ConfigureAwait(false);
                try
                {
                    Node main, spare; List<Node> all;
                    lock (gate) { main = mainNode; spare = spareNode; all = nodes.ToList(); }
                    if (main == null) return;
                    StopCores();
                    var s = SettingsCopy();
                    var tun = IsElevated;
                    var err = StartCores(s, all, main, spare, tun);
                    if (err != null) { Log.Write("supervisor: restart failed: " + err); StopCores(); lock (gate) nextRetry = DateTime.Now.AddSeconds(10); SetState(State.Error, "Связь прервалась, переподключаюсь…", err); }
                    else lock (gate) tunActive = tun;
                }
                finally { op.Release(); }
            });
        }

        public static string Flatten(Exception e)
        {
            var parts = new List<string>();
            for (var x = e; x != null; x = x.InnerException) if (!string.IsNullOrEmpty(x.Message) && !parts.Contains(x.Message)) parts.Add(x.Message);
            return string.Join(" → ", parts);
        }

        // ------------------------------------------------------------------ report for support

        public string Report()
        {
            var sb = new System.Text.StringBuilder();
            var s = SettingsCopy();
            sb.AppendLine("VlessClient report " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            sb.AppendLine("version: " + Updater.CurrentVersion + "   windows: " + Environment.OSVersion + "   elevated: " + IsElevated);
            lock (gate)
            {
                sb.AppendLine($"state: {state}  message: {message}  error: {error}");
                sb.AppendLine($"node: {mainNode?.Index} {mainNode?.Name}  spare: {spareNode?.Index} {spareNode?.Name}  tun: {tunActive}");
                foreach (var w in warnings) sb.AppendLine("warning: " + w);
            }
            string host = ""; try { host = new Uri(s.SubscriptionUrl).Host; } catch { }
            List<Node> list; lock (gate) list = nodes.ToList();
            sb.AppendLine($"subscription host: {host}  insecure_tls: {s.InsecureTls}  cached: {Subscription.CacheTime:s}  nodes: {list.Count(n => n.Group == 0)}");
            for (var k = 0; k < s.Backups.Count; k++)
            {
                var b = s.Backups[k];
                string be; lock (gate) backupErrors.TryGetValue(b.Url, out be);
                sb.AppendLine($"backup {k + 1}: {b.Host}  cached: {Subscription.BackupTime(b):s}  new nodes: {list.Count(n => n.Group == k + 1)}" + (be != null ? "  error: " + be : ""));
            }
            sb.AppendLine($"default: {s.Default}  node setting: {s.Node}  auto_exclude: {s.AutoExclude}  ru_direct: {s.RuDirect}");
            sb.AppendLine("apps: " + string.Join("; ", s.Apps.Select(a => a.Name + (a.Vpn ? "=vpn" : "=direct"))));
            sb.AppendLine();
            sb.AppendLine("nodes:");
            foreach (var n in list) sb.AppendLine($"  {n.Index,2}{(n.Group > 0 ? " [b" + n.Group + "]" : "")} {n.Name}  {n.Kind}");
            if (lastProbe != null)
            {
                sb.AppendLine("last probe:");
                foreach (var r in lastProbe) sb.AppendLine($"  {r.Node.Index,2} {(r.Ok ? r.Ms + " ms" : "FAIL " + r.Error)}");
            }
            sb.AppendLine();
            sb.AppendLine("network adapters:");
            foreach (var i in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (i.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                var p = i.GetIPProperties();
                sb.AppendLine($"  {i.Name} | {i.Description} | gw {string.Join(",", p.GatewayAddresses.Select(g => g.Address))} | dns {string.Join(",", p.DnsAddresses)}");
            }
            sb.AppendLine("native ipv6: " + NetInfo.HasNativeIPv6(s) + "   direct dns: " + NetInfo.DirectDns(s));
            sb.AppendLine();
            sb.AppendLine("--- service.log ---"); sb.AppendLine(Log.Tail("service.log", 80));
            sb.AppendLine("--- xray.log ---"); sb.AppendLine(Log.Tail("xray.log", 30));
            sb.AppendLine("--- sing-box.log ---"); sb.AppendLine(Log.Tail("sing-box.log", 30));
            return sb.ToString();
        }
    }
}
