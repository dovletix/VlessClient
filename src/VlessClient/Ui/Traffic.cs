using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using VlessClient.Core;

namespace VlessClient.Ui
{
    public sealed class FailRec { public string Time = "", Dest = "", Out = "", Reason = ""; public bool Udp; public int N = 1; }
    public sealed class HostRec { public string Host = "", Out = ""; public long Up, Down; public double RUp, RDown; }

    /// <summary>One program as seen by the monitor (a copy: the UI never touches the monitor's own state).</summary>
    public sealed class ProcData
    {
        public string Key = "", Name = "", Path = "";
        public bool Running, Window;
        public int Total, Active, Fail, Udp, ProxyN, DirectN, FProxy, FDirect, NHosts;
        public long Up, Down, PBytes, DBytes;
        public double RUp, RDown, RP, RD;
        public List<FailRec> Fails = new List<FailRec>();
        public List<HostRec> Hosts = new List<HostRec>();
    }

    public sealed class TrafficSnapshot
    {
        public bool ApiOk;
        public List<ProcData> Rows = new List<ProcData>();
    }

    /// <summary>
    /// Per-program traffic, destinations and failed connections, ported from the web UI of the PowerShell edition.
    /// Source: sing-box's Clash API (/connections, about once a second) and the ERROR lines of sing-box.log (failed dials).
    /// A connection that sent data but never received a byte counts as "no answer". Everything counts from the window's start.
    /// </summary>
    public sealed class TrafficMonitor
    {
        public const string Unknown = "(unknown)";

        private sealed class Conn { public string Key, Dest, HostKey, Out; public bool Udp, Flagged; public DateTime Start; public long Up, Down; }
        private sealed class HostStat { public string Host, Out; public long Up, Down, TUp, TDown; public double RUp, RDown; public DateTime Last; }
        private sealed class Stat
        {
            public string Key, Name, Path = "";
            public int Total, Ok, Fail, Udp, ProxyN, DirectN, FProxy, FDirect;
            public long Up, Down, PBytes, DBytes, TUp, TDown, TP, TD;
            public double RUp, RDown, RP, RD;
            public List<FailRec> Fails = new List<FailRec>();
            public Dictionary<string, HostStat> Hosts = new Dictionary<string, HostStat>(StringComparer.OrdinalIgnoreCase);
        }
        private sealed class Proc { public string Name, Path; public bool Window; }

        private static readonly HttpClient Http = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(3) };
        private static readonly Regex ErrorLine = new Regex(@"connection: open connection to (\S+) using outbound/[\w-]+\[([\w-]+)\]: (.+)$", RegexOptions.Compiled);
        private static readonly Regex Ansi = new Regex(@"\x1b\[[0-9;]*m", RegexOptions.Compiled);

        private readonly object gate = new object();
        private readonly Dictionary<string, Conn> conns = new Dictionary<string, Conn>();
        private readonly Dictionary<string, Stat> stats = new Dictionary<string, Stat>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, KeyValuePair<string, DateTime>> destMap = new Dictionary<string, KeyValuePair<string, DateTime>>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, string> pathCache = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private Dictionary<string, Proc> procCache;
        private DateTime procTime = DateTime.MinValue, lastTick = DateTime.MinValue;
        private bool first = true;
        private volatile bool resetPending;
        private long logPos = -1;

        /// <summary>Clears everything on the next sample (safe to call while a sample runs).</summary>
        public void Reset() => resetPending = true;

        /// <param name="all">include every running process, not only those with a window or a rule</param>
        /// <param name="ruled">lower-case exe names that have an app rule</param>
        public Task<TrafficSnapshot> SampleAsync(int port, string secret, bool all, ICollection<string> ruled) =>
            Task.Run(() => { lock (gate) return Sample(port, secret, all, ruled); });

        private TrafficSnapshot Sample(int port, string secret, bool all, ICollection<string> ruled)
        {
            if (resetPending)
            {
                conns.Clear(); stats.Clear(); destMap.Clear();
                first = true; lastTick = DateTime.MinValue; logPos = -1; resetPending = false;
            }
            var snap = new TrafficSnapshot { ApiOk = Poll(port, secret) };
            if (snap.ApiOk) ReadLogErrors();
            var procs = RunningProcs();

            var active = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (var c in conns.Values) { active.TryGetValue(c.Key, out var n); active[c.Key] = n + 1; }
            var keys = new HashSet<string>(stats.Keys, StringComparer.OrdinalIgnoreCase);
            foreach (var kv in procs) if (all || kv.Value.Window || ruled.Contains(kv.Key)) keys.Add(kv.Key);

            foreach (var k in keys)
            {
                stats.TryGetValue(k, out var x); procs.TryGetValue(k, out var p);
                var row = new ProcData { Key = k, Name = p?.Name ?? x?.Name ?? k, Path = p?.Path ?? "", Running = p != null, Window = p?.Window ?? false };
                active.TryGetValue(k, out row.Active);
                if (x != null)
                {
                    if (row.Path.Length == 0) row.Path = x.Path;
                    row.Total = x.Total; row.Fail = x.Fail; row.Udp = x.Udp; row.Up = x.Up; row.Down = x.Down;
                    row.ProxyN = x.ProxyN; row.DirectN = x.DirectN; row.FProxy = x.FProxy; row.FDirect = x.FDirect;
                    row.RUp = x.RUp; row.RDown = x.RDown; row.RP = x.RP; row.RD = x.RD; row.PBytes = x.PBytes; row.DBytes = x.DBytes;
                    row.Fails = x.Fails.Select(f => new FailRec { Time = f.Time, Dest = f.Dest, Out = f.Out, Reason = f.Reason, Udp = f.Udp, N = f.N }).ToList();
                    row.Hosts = x.Hosts.Values.OrderByDescending(h => h.RUp + h.RDown).ThenByDescending(h => h.Up + h.Down).Take(10)
                        .Select(h => new HostRec { Host = h.Host, Out = h.Out, Up = h.Up, Down = h.Down, RUp = h.RUp, RDown = h.RDown }).ToList();
                    row.NHosts = x.Hosts.Count;
                }
                snap.Rows.Add(row);
            }
            return snap;
        }

        // ------------------------------------------------------------------ /connections

        private bool Poll(int port, string secret)
        {
            string text;
            try
            {
                using (var req = new HttpRequestMessage(HttpMethod.Get, "http://127.0.0.1:" + port + "/connections"))
                {
                    req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", secret);
                    using (var resp = Http.SendAsync(req).GetAwaiter().GetResult())
                    {
                        if (!resp.IsSuccessStatusCode) return false;
                        text = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                    }
                }
            }
            catch { return false; }

            var now = DateTime.Now;
            var seen = new HashSet<string>();
            var j = Json.ParseObject(text);
            if (j.TryGetValue("connections", out var list) && list is IEnumerable items)
                foreach (var o in items)
                {
                    if (!(o is Dictionary<string, object> c)) continue;
                    var id = c.Str("id"); seen.Add(id);
                    long up = (long)c.Num("upload"), down = (long)c.Num("download");
                    if (!conns.TryGetValue(id, out var t))
                    {
                        var m = c.Obj("metadata") ?? new Dictionary<string, object>();
                        var path = ExePath(m.Str("processPath"));
                        string name = Unknown, key = Unknown;
                        if (path.Length > 0) { name = System.IO.Path.GetFileName(path); key = name.ToLowerInvariant(); }
                        var ip = m.Str("destinationIP"); var dport = m.Str("destinationPort");
                        if (dport.Length == 0) dport = ((long)m.Num("destinationPort")).ToString();
                        var ipDest = (ip.Contains(":") ? "[" + ip + "]" : ip) + ":" + dport;
                        var host = m.Str("host");
                        var dest = host.Length > 0 ? host + ":" + dport : ipDest;
                        var chains = c.ContainsKey("chains") && c["chains"] is IEnumerable ch ? ch.Cast<object>().Select(x => x?.ToString() ?? "").ToList() : new List<string>();
                        var outb = chains.Contains("direct") ? "direct" : chains.Contains("proxy") || chains.Count == 0 ? "proxy" : chains[0];
                        t = new Conn { Key = key, Dest = dest, HostKey = host.Length > 0 ? host : ip, Udp = m.Str("network") == "udp", Out = outb, Start = now };
                        // connections that were already open before the first sample: count only what they transfer from now on
                        if (first) { t.Up = up; t.Down = down; }
                        conns[id] = t;
                        var st = GetStat(key, name, path);
                        st.Total++;
                        if (outb == "direct") st.DirectN++; else st.ProxyN++;
                        destMap[ipDest] = new KeyValuePair<string, DateTime>(key, now);
                        destMap[dest] = new KeyValuePair<string, DateTime>(key, now);
                    }
                    if (up != t.Up || down != t.Down)
                    {
                        var st = stats[t.Key];
                        long du = Math.Max(0, up - t.Up), dd = Math.Max(0, down - t.Down);
                        st.Up += du; st.Down += dd; st.TUp += du; st.TDown += dd;
                        if (t.Out == "direct") { st.DBytes += du + dd; st.TD += du + dd; } else { st.PBytes += du + dd; st.TP += du + dd; }
                        if (t.HostKey.Length > 0)
                        {
                            if (!st.Hosts.TryGetValue(t.HostKey, out var hs)) st.Hosts[t.HostKey] = hs = new HostStat { Host = t.HostKey };
                            hs.Up += du; hs.Down += dd; hs.TUp += du; hs.TDown += dd; hs.Out = t.Out; hs.Last = now;
                        }
                        t.Up = up; t.Down = down;
                    }
                    if (!t.Flagged && down == 0 && up > 0 && (now - t.Start).TotalSeconds >= 6)
                    {
                        t.Flagged = true;
                        AddFail(stats[t.Key], t.Dest, t.Out, "no-answer", t.Udp);
                    }
                }
            foreach (var id in conns.Keys.Where(x => !seen.Contains(x)).ToList())
            {
                var t = conns[id];
                if (!t.Flagged)
                {
                    if (t.Down > 0) stats[t.Key].Ok++;
                    else if (t.Up > 0 && (now - t.Start).TotalSeconds >= 2) AddFail(stats[t.Key], t.Dest, t.Out, "no-answer", t.Udp);
                }
                conns.Remove(id);
            }
            if (destMap.Count > 4000)
                foreach (var k in destMap.Where(kv => (now - kv.Value.Value).TotalSeconds > 60).Select(kv => kv.Key).ToList()) destMap.Remove(k);

            // this tick's byte counts -> smoothed speeds (bytes per second)
            var dt = lastTick == DateTime.MinValue ? 1.0 : Math.Max(0.2, (now - lastTick).TotalSeconds);
            lastTick = now; first = false;
            foreach (var st in stats.Values)
            {
                st.RUp = Smooth(st.RUp, st.TUp, dt); st.RDown = Smooth(st.RDown, st.TDown, dt);
                st.RP = Smooth(st.RP, st.TP, dt); st.RD = Smooth(st.RD, st.TD, dt);
                st.TUp = st.TDown = st.TP = st.TD = 0;
                foreach (var hs in st.Hosts.Values) { hs.RUp = Smooth(hs.RUp, hs.TUp, dt); hs.RDown = Smooth(hs.RDown, hs.TDown, dt); hs.TUp = hs.TDown = 0; }
                if (st.Hosts.Count > 120)   // keep it bounded: drop the destinations silent the longest
                    foreach (var h in st.Hosts.Values.OrderBy(h => h.Last).Take(st.Hosts.Count - 80).Select(h => h.Host).ToList()) st.Hosts.Remove(h);
            }
            return true;
        }

        private static double Smooth(double prev, long bytes, double dt)
        {
            var v = 0.5 * prev + 0.5 * bytes / dt;
            return v < 50 ? 0 : v;
        }

        private static string ExePath(string processPath)
        {
            if (string.IsNullOrEmpty(processPath)) return "";
            var cut = processPath.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
            return cut > 0 ? processPath.Substring(0, cut + 4) : processPath;
        }

        private Stat GetStat(string key, string name, string path)
        {
            if (!stats.TryGetValue(key, out var st)) stats[key] = st = new Stat { Key = key, Name = name, Path = path ?? "" };
            if (!string.IsNullOrEmpty(path) && st.Path.Length == 0) st.Path = path;
            return st;
        }

        private static void AddFail(Stat st, string dest, string outb, string reason, bool udp)
        {
            if (udp) st.Udp++;
            else { st.Fail++; if (outb == "direct") st.FDirect++; else st.FProxy++; }
            var time = DateTime.Now.ToString("HH:mm:ss");
            if (st.Fails.Count > 0 && st.Fails[0].Dest == dest && st.Fails[0].Reason == reason && st.Fails[0].Out == outb) { st.Fails[0].N++; st.Fails[0].Time = time; return; }
            st.Fails.Insert(0, new FailRec { Time = time, Dest = dest, Out = outb, Reason = reason, Udp = udp });
            while (st.Fails.Count > 10) st.Fails.RemoveAt(st.Fails.Count - 1);
        }

        // ------------------------------------------------------------------ sing-box.log: failed dials

        /// <summary>New ERROR lines of sing-box.log (failed dials), attributed to the program that connected to that address.</summary>
        private void ReadLogErrors()
        {
            string text;
            try
            {
                var file = System.IO.Path.Combine(Paths.LogsDir, "sing-box.log");
                if (!File.Exists(file)) return;
                using (var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (logPos < 0 || logPos > fs.Length) { logPos = fs.Length; return; }   // start (or log rotated): only what comes next
                    if (fs.Length == logPos) return;
                    fs.Position = logPos;
                    var buf = new byte[(int)Math.Min(fs.Length - logPos, 262144)];
                    var n = fs.Read(buf, 0, buf.Length);
                    logPos += n;
                    text = Encoding.UTF8.GetString(buf, 0, n);
                }
            }
            catch { return; }
            var now = DateTime.Now;
            foreach (var raw in text.Split('\n'))
            {
                if (raw.IndexOf("ERROR", StringComparison.Ordinal) < 0) continue;
                var m = ErrorLine.Match(Ansi.Replace(raw, "").TrimEnd('\r'));
                if (!m.Success) continue;
                var dest = m.Groups[1].Value; var outb = m.Groups[2].Value; var msg = m.Groups[3].Value;
                var reason = "error";
                if (Regex.IsMatch(msg, "timeout|timed out|did not properly respond", RegexOptions.IgnoreCase)) reason = "timeout";
                else if (msg.IndexOf("refused", StringComparison.OrdinalIgnoreCase) >= 0) reason = "refused";
                else if (Regex.IsMatch(msg, "reset|forcibly closed|aborted", RegexOptions.IgnoreCase)) reason = "reset";
                else if (Regex.IsMatch(msg, "unreachable|no route", RegexOptions.IgnoreCase)) reason = "unreachable";
                else if (Regex.IsMatch(msg, "lookup|empty result", RegexOptions.IgnoreCase)) reason = "dns";
                var key = Unknown;
                if (destMap.TryGetValue(dest, out var d) && (now - d.Value).TotalSeconds < 30) key = d.Key;
                AddFail(GetStat(key, key, ""), dest, outb, reason, false);
            }
        }

        // ------------------------------------------------------------------ running processes

        private Dictionary<string, Proc> RunningProcs()
        {
            if (procCache != null && (DateTime.Now - procTime).TotalSeconds < 5) return procCache;
            var map = new Dictionary<string, Proc>(StringComparer.OrdinalIgnoreCase);
            foreach (var p in Process.GetProcesses())
            {
                try
                {
                    var name = p.ProcessName + ".exe";
                    if (!map.TryGetValue(name, out var e))
                    {
                        if (!pathCache.TryGetValue(name, out var path))
                        {
                            path = "";
                            try { path = p.MainModule?.FileName ?? ""; } catch { }
                            pathCache[name] = path;
                        }
                        map[name] = e = new Proc { Name = name, Path = path };
                    }
                    if (!e.Window) { try { e.Window = p.MainWindowHandle != IntPtr.Zero; } catch { } }
                }
                catch { }
                finally { p.Dispose(); }
            }
            procCache = map; procTime = DateTime.Now;
            return map;
        }
    }
}
