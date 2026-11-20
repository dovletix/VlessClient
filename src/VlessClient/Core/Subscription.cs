using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace VlessClient.Core
{
    /// <summary>One server from the subscription (a vless:// link).</summary>
    public sealed class Node
    {
        public int Index;
        public string Name = "";
        public string Id = "";
        public string Address = "";
        public int Port;
        public Dictionary<string, string> Query = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public string Tag => "node-" + Index.ToString("00");

        public string Q(string key) => Query.TryGetValue(key, out var v) ? v : "";

        public string Kind
        {
            get
            {
                var t = Q("type"); if (t.Length == 0) t = "tcp";
                var k = t;
                if (Q("security").Length > 0) k += "+" + Q("security");
                if (Q("encryption").Length > 0 && Q("encryption") != "none") k += "+mlkem";
                return k;
            }
        }

        public static Node Parse(string line)
        {
            var m = Regex.Match(line.Trim(), @"^vless://([^@]+)@(\[[^\]]+\]|[^:/?#]+):(\d+)/?\??([^#]*)#?(.*)$");
            if (!m.Success) return null;
            var n = new Node
            {
                Id = Uri.UnescapeDataString(m.Groups[1].Value),
                Address = m.Groups[2].Value.Trim('[', ']'),
                Port = int.Parse(m.Groups[3].Value),
                Name = Uri.UnescapeDataString(m.Groups[5].Value.Replace("+", "%20")).Trim(),
            };
            foreach (var kv in m.Groups[4].Value.Split('&'))
            {
                if (kv.Length == 0) continue;
                var i = kv.IndexOf('=');
                if (i < 0) n.Query[kv] = "";
                else n.Query[kv.Substring(0, i)] = Uri.UnescapeDataString(kv.Substring(i + 1));
            }
            return n;
        }
    }

    public static class Subscription
    {
        /// <summary>Downloads the subscription; returns null on failure (the cached copy stays).</summary>
        public static async Task<string> FetchAsync(Settings s)
        {
            var handler = new HttpClientHandler { UseProxy = false, AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate };
            if (s.InsecureTls) handler.ServerCertificateCustomValidationCallback = (m, c, ch, e) => true;
            using (var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(25) })
            {
                http.DefaultRequestHeaders.UserAgent.ParseAdd("VlessClient/" + typeof(Subscription).Assembly.GetName().Version.ToString(3));
                var body = await http.GetStringAsync(s.SubscriptionUrl.Trim()).ConfigureAwait(false);
                return Decode(body);
            }
        }

        /// <summary>Accepts a plain list of links or a base64 blob; returns only vless:// lines.</summary>
        public static string Decode(string body)
        {
            body = (body ?? "").Trim();
            if (!body.Contains("://"))
            {
                try
                {
                    var b = Regex.Replace(body, @"\s", "").Replace('-', '+').Replace('_', '/');
                    while (b.Length % 4 != 0) b += "=";
                    body = Encoding.UTF8.GetString(Convert.FromBase64String(b));
                }
                catch { return null; }
            }
            var lines = body.Replace("\r", "").Split('\n').Select(l => l.Trim()).Where(l => l.StartsWith("vless://", StringComparison.OrdinalIgnoreCase)).ToList();
            return lines.Count == 0 ? null : string.Join("\n", lines);
        }

        public static List<Node> LoadCached()
        {
            var res = new List<Node>();
            if (!File.Exists(Paths.SubscriptionCache)) return res;
            var i = 0;
            foreach (var line in File.ReadAllLines(Paths.SubscriptionCache, Paths.Utf8))
            {
                var n = Node.Parse(line);
                if (n == null) continue;
                n.Index = ++i;
                if (n.Name.Length == 0) n.Name = "Сервер " + n.Index;
                res.Add(n);
            }
            return res;
        }

        public static DateTime CacheTime => File.Exists(Paths.SubscriptionCache) ? File.GetLastWriteTime(Paths.SubscriptionCache) : DateTime.MinValue;

        /// <summary>Nodes that "auto" may use (auto_exclude applied; falls back to all when the filter removes everything).</summary>
        public static List<Node> AutoPool(Settings s, List<Node> all)
        {
            if (string.IsNullOrWhiteSpace(s.AutoExclude)) return all;
            try
            {
                var rx = new Regex(s.AutoExclude, RegexOptions.IgnoreCase);
                var pool = all.Where(n => !rx.IsMatch(n.Name)).ToList();
                return pool.Count > 0 ? pool : all;
            }
            catch { return all; }
        }

        /// <summary>A pinned node by number or by part of its name; null for "auto" or when not found.</summary>
        public static Node FindPinned(Settings s, List<Node> all)
        {
            var sel = (s.Node ?? "").Trim();
            if (sel.Length == 0 || sel.Equals("auto", StringComparison.OrdinalIgnoreCase)) return null;
            if (int.TryParse(sel, out var idx)) return all.FirstOrDefault(n => n.Index == idx);
            return all.FirstOrDefault(n => n.Name.Equals(sel, StringComparison.OrdinalIgnoreCase))
                ?? all.FirstOrDefault(n => n.Name.IndexOf(sel, StringComparison.OrdinalIgnoreCase) >= 0);
        }
    }
}
