using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace VlessClient.Core
{
    public sealed class AppRule
    {
        public string Name = "";
        public List<string> Processes = new List<string>();
        public bool Vpn;
    }

    /// <summary>All user settings. Stored as JSON in C:\ProgramData\VlessClient\settings.json; only the service writes it.</summary>
    public sealed class Settings
    {
        // subscription
        public string SubscriptionUrl = "";
        public bool InlineNodes;             // servers were pasted as vless:// lines instead of a link (nothing to download)
        public bool InsecureTls;
        public int UpdateHours = 12;

        // connection
        public bool Enabled;                 // the user wants the VPN on (survives reboots)
        public string Node = "auto";         // "auto", node number or part of its name
        public string AutoExclude = "";      // regex on node names that "auto" must never use
        public string LastGoodNode = "";     // name of the node that worked last time (auto starts with it)
        public string Mode = "tun";          // tun = whole computer, proxy = local proxy only
        public string Default = "proxy";     // where traffic without a rule goes
        public bool BlockQuicOnProxy = true;

        // ports (localhost only)
        public int ProxyPort = 12080;
        public int XrayPort = 12081;
        public int ApiPort = 12090;
        public string ApiSecret = "";

        // tunnel
        public string TunName = "VlessClient";
        public string TunAddress4 = "198.18.0.1/30";
        public string TunAddress6 = "fdfe:dcba:9876::1/126";
        public string TunIpv6 = "auto";      // auto | on | off
        public int TunMtu = 9000;
        public string TunStack = "mixed";
        public List<string> ExcludeRoutes = new List<string>
        {
            "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10",
            "224.0.0.0/4", "255.255.255.255/32", "fc00::/7", "fe80::/10", "ff00::/8"
        };

        public string DnsProxy = "1.1.1.1";
        public string DnsDirect = "auto";

        // corporate VPN (Check Point Endpoint Security)
        public bool CheckpointEnabled;
        public string CheckpointPath = @"C:\Program Files (x86)\CheckPoint";
        public List<string> CheckpointExcludeIps = new List<string>();

        // Russia
        public bool RuDirect = true;
        public List<string> RuGeoip = new List<string> { "ru" };
        public List<string> RuGeosite = new List<string> { "category-ru", "tld-ru", "available-only-in-ru", "yandex", "vk", "mailru" };
        public List<string> RuBlockedGeosite = new List<string> { "blocked-in-ru" };

        // rules
        public List<AppRule> Apps = new List<AppRule>
        {
            new AppRule { Name = "Удалённый доступ", Processes = new List<string> { "rustdesk.exe", "AnyDesk.exe", "TeamViewer.exe" }, Vpn = false },
            new AppRule { Name = "Торренты", Processes = new List<string> { "qbittorrent.exe", "utorrent.exe", "bittorrent.exe" }, Vpn = false },
        };
        public List<string> BlockProcesses = new List<string>();
        public List<string> DirectDomains = new List<string>();
        public List<string> ProxyDomains = new List<string>();
        public List<string> DirectIps = new List<string>();
        public List<string> ProxyIps = new List<string>();

        // updates
        public bool AutoUpdate;              // off by default: update only when the user presses the button

        public string LogLevel = "warn";

        public bool HasSubscription => InlineNodes || !string.IsNullOrWhiteSpace(SubscriptionUrl);
        public bool CanDownload => !InlineNodes && !string.IsNullOrWhiteSpace(SubscriptionUrl);

        // ------------------------------------------------------------------ load / save

        public static Settings Load()
        {
            var s = new Settings();
            try
            {
                if (File.Exists(Paths.SettingsFile))
                    s = FromJson(Json.ParseObject(File.ReadAllText(Paths.SettingsFile, Paths.Utf8)));
            }
            catch (Exception e) { Log.Write("settings: cannot read, using defaults: " + e.Message); }
            if (string.IsNullOrEmpty(s.ApiSecret)) s.ApiSecret = Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N");
            return s;
        }

        public void Save()
        {
            var tmp = Paths.SettingsFile + ".tmp";
            File.WriteAllText(tmp, Json.Serialize(ToJson(), true) + "\n", Paths.Utf8);
            if (File.Exists(Paths.SettingsFile)) File.Replace(tmp, Paths.SettingsFile, null);
            else File.Move(tmp, Paths.SettingsFile);
        }

        public Settings Clone() => FromJson(Json.ParseObject(Json.Serialize(ToJson())));

        public JObj ToJson()
        {
            return new JObj()
                .Set("subscription", new JObj().Set("url", SubscriptionUrl).Set("inline", InlineNodes).Set("insecure_tls", InsecureTls).Set("update_hours", UpdateHours))
                .Set("enabled", Enabled)
                .Set("node", Node)
                .Set("auto_exclude", AutoExclude)
                .Set("last_good_node", LastGoodNode)
                .Set("mode", Mode)
                .Set("default", Default)
                .Set("block_quic_on_proxy", BlockQuicOnProxy)
                .Set("ports", new JObj().Set("proxy", ProxyPort).Set("xray", XrayPort).Set("api", ApiPort))
                .Set("api_secret", ApiSecret)
                .Set("tun", new JObj().Set("name", TunName).Set("address4", TunAddress4).Set("address6", TunAddress6)
                    .Set("ipv6", TunIpv6).Set("mtu", TunMtu).Set("stack", TunStack).Set("exclude_routes", ExcludeRoutes))
                .Set("dns", new JObj().Set("proxy", DnsProxy).Set("direct", DnsDirect))
                .Set("checkpoint", new JObj().Set("enabled", CheckpointEnabled).Set("path", CheckpointPath).Set("exclude_ips", CheckpointExcludeIps))
                .Set("ru_direct", new JObj().Set("enabled", RuDirect).Set("geoip", RuGeoip).Set("geosite", RuGeosite).Set("blocked_geosite", RuBlockedGeosite))
                .Set("apps", Apps.Select(a => (object)new JObj().Set("name", a.Name).Set("processes", a.Processes).Set("vpn", a.Vpn)).ToList())
                .Set("rules", new JObj().Set("block_processes", BlockProcesses).Set("direct_domains", DirectDomains).Set("proxy_domains", ProxyDomains)
                    .Set("direct_ips", DirectIps).Set("proxy_ips", ProxyIps))
                .Set("auto_update", AutoUpdate)
                .Set("log_level", LogLevel);
        }

        public static Settings FromJson(Dictionary<string, object> j)
        {
            var s = new Settings();
            var sub = j.Obj("subscription");
            if (sub != null) { s.SubscriptionUrl = sub.Str("url"); s.InlineNodes = sub.Bool("inline"); s.InsecureTls = sub.Bool("insecure_tls"); s.UpdateHours = Math.Max(1, sub.Int("update_hours", 12)); }
            s.Enabled = j.Bool("enabled");
            s.Node = j.Str("node", "auto");
            s.AutoExclude = j.Str("auto_exclude");
            s.LastGoodNode = j.Str("last_good_node");
            s.Mode = j.Str("mode", "tun") == "proxy" ? "proxy" : "tun";
            s.Default = j.Str("default", "proxy") == "direct" ? "direct" : "proxy";
            s.BlockQuicOnProxy = j.Bool("block_quic_on_proxy", true);
            var ports = j.Obj("ports");
            if (ports != null) { s.ProxyPort = ports.Int("proxy", s.ProxyPort); s.XrayPort = ports.Int("xray", s.XrayPort); s.ApiPort = ports.Int("api", s.ApiPort); }
            s.ApiSecret = j.Str("api_secret");
            var tun = j.Obj("tun");
            if (tun != null)
            {
                s.TunName = tun.Str("name", s.TunName); s.TunAddress4 = tun.Str("address4", s.TunAddress4); s.TunAddress6 = tun.Str("address6", s.TunAddress6);
                s.TunIpv6 = tun.Str("ipv6", "auto"); s.TunMtu = tun.Int("mtu", s.TunMtu); s.TunStack = tun.Str("stack", s.TunStack);
                if (tun.ContainsKey("exclude_routes")) s.ExcludeRoutes = tun.Strings("exclude_routes");
            }
            var dns = j.Obj("dns");
            if (dns != null) { s.DnsProxy = dns.Str("proxy", s.DnsProxy); s.DnsDirect = dns.Str("direct", "auto"); }
            var cp = j.Obj("checkpoint");
            if (cp != null) { s.CheckpointEnabled = cp.Bool("enabled"); s.CheckpointPath = cp.Str("path", s.CheckpointPath); s.CheckpointExcludeIps = cp.Strings("exclude_ips"); }
            var ru = j.Obj("ru_direct");
            if (ru != null)
            {
                s.RuDirect = ru.Bool("enabled", true);
                if (ru.ContainsKey("geoip")) s.RuGeoip = ru.Strings("geoip");
                if (ru.ContainsKey("geosite")) s.RuGeosite = ru.Strings("geosite");
                if (ru.ContainsKey("blocked_geosite")) s.RuBlockedGeosite = ru.Strings("blocked_geosite");
            }
            if (j.ContainsKey("apps"))
                s.Apps = j.Objects("apps").Select(a => new AppRule { Name = a.Str("name"), Processes = a.Strings("processes"), Vpn = a.Bool("vpn") })
                    .Where(a => a.Name.Length > 0 && a.Processes.Count > 0).ToList();
            var r = j.Obj("rules");
            if (r != null)
            {
                s.BlockProcesses = r.Strings("block_processes"); s.DirectDomains = r.Strings("direct_domains"); s.ProxyDomains = r.Strings("proxy_domains");
                s.DirectIps = r.Strings("direct_ips"); s.ProxyIps = r.Strings("proxy_ips");
            }
            s.AutoUpdate = j.Bool("auto_update");
            s.LogLevel = j.Str("log_level", "warn");
            return s;
        }

        // ------------------------------------------------------------------ app rules

        /// <summary>Creates or updates an app rule; the listed exe files are removed from every other rule.</summary>
        public void SetApp(string name, IEnumerable<string> processes, bool vpn)
        {
            var procs = processes.Where(p => !string.IsNullOrWhiteSpace(p)).Select(p => p.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            foreach (var a in Apps.Where(a => a.Name != name))
                a.Processes.RemoveAll(p => procs.Contains(p, StringComparer.OrdinalIgnoreCase));
            Apps.RemoveAll(a => a.Processes.Count == 0);
            var existing = Apps.FirstOrDefault(a => a.Name == name);
            if (existing == null) Apps.Add(new AppRule { Name = name, Processes = procs, Vpn = vpn });
            else { if (procs.Count > 0) existing.Processes = procs; existing.Vpn = vpn; }
        }
    }
}
