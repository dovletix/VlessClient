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
        /// <summary>0 = the main subscription, 1.. = backup subscription number (used when none of the main servers works).</summary>
        public int Group;
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
        /// <summary>Downloads the main subscription; throws on network errors, returns null when the answer has no vless:// lines.</summary>
        public static Task<string> FetchAsync(Settings s) => FetchAsync(s.SubscriptionUrl, s.InsecureTls);

        public static async Task<string> FetchAsync(string url, bool insecure)
        {
            var handler = new HttpClientHandler { UseProxy = false, AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate };
            if (insecure) handler.ServerCertificateCustomValidationCallback = (m, c, ch, e) => true;
            using (var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(25) })
            {
                http.DefaultRequestHeaders.UserAgent.ParseAdd("VlessClient/" + typeof(Subscription).Assembly.GetName().Version.ToString(3));
                var body = await http.GetStringAsync(url.Trim()).ConfigureAwait(false);
                return Decode(body);
            }
        }

        /// <summary>The cached copy of a backup subscription, named after its link (removing one keeps the others' files).</summary>
        public static string BackupCache(BackupSub b)
        {
            uint h = 0x811c9dc5;
            foreach (var c in Encoding.UTF8.GetBytes(b.Url)) { h ^= c; h *= 0x01000193; }
            return Path.Combine(Paths.RuntimeDir, "backup-" + h.ToString("x8") + ".txt");
        }

        public static DateTime BackupTime(BackupSub b) { var f = BackupCache(b); return File.Exists(f) ? File.GetLastWriteTime(f) : DateTime.MinValue; }

        /// <summary>Subscription groups that have at least one node, in order (main first).</summary>
        public static List<int> Groups(List<Node> all) => all.Select(n => n.Group).Distinct().OrderBy(g => g).ToList();

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

        /// <summary>The main subscription's nodes first (group 0), then each backup's (group 1..), numbered on. A link that is
        /// already in the list is skipped, so a backup that mirrors the main subscription adds nothing (it still helps when
        /// the main link cannot be downloaded).</summary>
        public static List<Node> LoadCached(Settings s)
        {
            var res = new List<Node>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            Add(res, seen, Paths.SubscriptionCache, 0);
            for (var k = 0; k < s.Backups.Count; k++) Add(res, seen, BackupCache(s.Backups[k]), k + 1);
            return res;
        }

        private static void Add(List<Node> res, HashSet<string> seen, string file, int group)
        {
            if (!File.Exists(file)) return;
            foreach (var line in File.ReadAllLines(file, Paths.Utf8))
            {
                // the same server = the same user id, address and port; the query may differ between two downloads
                // (3x-ui picks a random short id from the inbound's list for every answer)
                var key = line.Trim().Split('#')[0].Split('?')[0].ToLowerInvariant();
                if (seen.Contains(key)) continue;
                var n = Node.Parse(line);
                if (n == null) continue;
                seen.Add(key);
                n.Group = group;
                n.Index = res.Count + 1;
                if (n.Name.Length == 0) n.Name = "Сервер " + n.Index;
                res.Add(n);
            }
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
