using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading.Tasks;
using VlessClient.Core;

namespace VlessClient.Ui
{
    public sealed class TrafficRow : INotifyPropertyChanged
    {
        public string Key { get; set; } = "";
        public string Exe { get; set; } = "";
        public string Path { get; set; } = "";
        public double DownRate { get; private set; }      // bytes per second
        public double UpRate { get; private set; }
        public double SpeedSort => DownRate + UpRate;
        public long VpnBytes { get; private set; }
        public long DirectBytes { get; private set; }
        public long TotalBytes => VpnBytes + DirectBytes;
        public int Active { get; private set; }
        public string Rule { get; private set; } = "";     // "Через VPN" / "Напрямую" / "" (common rule)
        public string Hosts { get; private set; } = "";

        public string Speed => DownRate + UpRate < 125 ? "—" : $"↓ {Mbit(DownRate)}  ↑ {Mbit(UpRate)}";
        public string Total => TotalBytes == 0 ? "—" : Bytes(TotalBytes);
        public string Split
        {
            get
            {
                if (TotalBytes == 0) return "—";
                var v = (int)Math.Round(100.0 * VpnBytes / TotalBytes);
                return v == 100 ? "VPN" : v == 0 ? "напрямую" : $"VPN {v}% · напрямую {100 - v}%";
            }
        }
        public string RuleText => Rule.Length == 0 ? "как все" : Rule;

        internal void Update(double down, double up, long vpn, long direct, int active, string rule, string hosts)
        {
            DownRate = down; UpRate = up; VpnBytes = vpn; DirectBytes = direct; Active = active; Rule = rule; Hosts = hosts;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
        }

        public event PropertyChangedEventHandler PropertyChanged;

        public static string Mbit(double bytesPerSec) => (bytesPerSec * 8 / 1e6).ToString(bytesPerSec * 8 / 1e6 < 10 ? "0.00" : "0.0") + " Мбит/с";

        public static string Bytes(long n)
        {
            if (n < 1024) return n + " Б";
            string[] u = { "КБ", "МБ", "ГБ", "ТБ" };
            double v = n; var i = -1;
            do { v /= 1024; i++; } while (v >= 1024 && i < u.Length - 1);
            return v.ToString(v < 10 ? "0.0" : "0") + " " + u[i];
        }
    }

    /// <summary>Per-program traffic from sing-box's Clash API (/connections), sampled about once a second.</summary>
    public sealed class TrafficMonitor
    {
        private sealed class Conn { public string Key; public bool Vpn; public long Up, Down; public string Host; }
        private sealed class Acc { public string Exe = "", Path = ""; public long Vpn, Direct, TickUp, TickDown; public double RUp, RDown; public int Active; public Dictionary<string, long> Hosts = new Dictionary<string, long>(); }

        private readonly Dictionary<string, Conn> conns = new Dictionary<string, Conn>();
        private readonly Dictionary<string, Acc> acc = new Dictionary<string, Acc>(StringComparer.OrdinalIgnoreCase);
        private DateTime lastTick = DateTime.MinValue;
        private bool first = true;

        public async Task<bool> SampleAsync(int port, string secret)
        {
            string text;
            try
            {
                using (var http = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(3) })
                {
                    http.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", secret);
                    text = await http.GetStringAsync("http://127.0.0.1:" + port + "/connections").ConfigureAwait(false);
                }
            }
            catch { return false; }

            var now = DateTime.Now;
            var dt = lastTick == DateTime.MinValue ? 1.0 : Math.Max(0.2, (now - lastTick).TotalSeconds);
            lastTick = now;
            var j = Json.ParseObject(text);
            var seen = new HashSet<string>();
            foreach (var a in acc.Values) { a.Active = 0; a.TickUp = 0; a.TickDown = 0; }
            if (j.TryGetValue("connections", out var list) && list is IEnumerable items)
                foreach (var o in items)
                {
                    if (!(o is Dictionary<string, object> c)) continue;
                    var id = c.Str("id"); seen.Add(id);
                    var meta = c.Obj("metadata");
                    var up = (long)c.Num("upload"); var down = (long)c.Num("download");
                    if (!conns.TryGetValue(id, out var k))
                    {
                        var path = meta.Str("processPath");
                        var cut = path.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
                        if (cut > 0) path = path.Substring(0, cut + 4);
                        var exe = path.Length > 0 ? System.IO.Path.GetFileName(path) : "(система)";
                        // "selected programs" mode: sing-box sees ProxiFyre, which carries the traffic of all selected programs
                        if (exe.Equals("ProxiFyre.exe", StringComparison.OrdinalIgnoreCase)) exe = "Выбранные программы (через ProxiFyre)";
                        var chains = c.ContainsKey("chains") && c["chains"] is IEnumerable ch ? ch.Cast<object>().Select(x => x?.ToString()).ToList() : new List<string>();
                        k = new Conn { Key = exe.ToLowerInvariant(), Vpn = !chains.Contains("direct"), Host = meta.Str("host").Length > 0 ? meta.Str("host") : meta.Str("destinationIP") };
                        // connections that were already open before the first sample: count only what they transfer from now on
                        if (first) { k.Up = up; k.Down = down; }
                        conns[id] = k;
                        if (!acc.TryGetValue(k.Key, out var na)) acc[k.Key] = na = new Acc { Exe = exe, Path = path };
                        else if (na.Path.Length == 0) na.Path = path;
                    }
                    var a = acc[k.Key];
                    long du = Math.Max(0, up - k.Up), dd = Math.Max(0, down - k.Down);
                    k.Up = up; k.Down = down;
                    a.TickUp += du; a.TickDown += dd; a.Active++;
                    if (k.Vpn) a.Vpn += du + dd; else a.Direct += du + dd;
                    if (du + dd > 0 && k.Host.Length > 0) { a.Hosts.TryGetValue(k.Host, out var hb); a.Hosts[k.Host] = hb + du + dd; }
                }
            foreach (var id in conns.Keys.Where(x => !seen.Contains(x)).ToList()) conns.Remove(id);
            foreach (var a in acc.Values)
            {
                a.RUp = 0.5 * a.RUp + 0.5 * a.TickUp / dt; if (a.RUp < 50) a.RUp = 0;
                a.RDown = 0.5 * a.RDown + 0.5 * a.TickDown / dt; if (a.RDown < 50) a.RDown = 0;
            }
            first = false;
            return true;
        }

        public void Reset() { conns.Clear(); acc.Clear(); first = true; lastTick = DateTime.MinValue; }

        /// <summary>Brings the observable rows in line with the samples (rows are updated in place).</summary>
        public void Apply(IList<TrafficRow> rows, Func<string, string> ruleOf)
        {
            foreach (var kv in acc)
            {
                var row = rows.FirstOrDefault(r => r.Key == kv.Key);
                if (row == null) { row = new TrafficRow { Key = kv.Key, Exe = kv.Value.Exe, Path = kv.Value.Path }; rows.Add(row); }
                var hosts = string.Join("\n", kv.Value.Hosts.OrderByDescending(h => h.Value).Take(8).Select(h => h.Key + " — " + TrafficRow.Bytes(h.Value)));
                row.Update(kv.Value.RDown, kv.Value.RUp, kv.Value.Vpn, kv.Value.Direct, kv.Value.Active, ruleOf(kv.Value.Exe), hosts);
            }
        }
    }
}
