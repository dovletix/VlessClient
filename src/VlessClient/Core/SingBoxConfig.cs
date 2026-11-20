using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace VlessClient.Core
{
    /// <summary>Builds the sing-box config (TUN, routing rules, DNS, local proxy) and the rule-set files it watches.</summary>
    public static class SingBoxConfig
    {
        public static readonly string[] UserRuleSets = { "apps-block", "apps-direct", "apps-proxy", "direct-domains", "direct-ips", "proxy-domains", "proxy-ips" };
        public static readonly string[] GeoRuleSets = { "geosite-ru-blocked", "geosite-ru", "geoip-ru" };

        // ------------------------------------------------------------------ rule-set files

        private static JObj RuleSetFile(JObj rule) => new JObj().Set("version", 3).Set("rules", rule == null || rule.Count == 0 ? new List<object>() : new List<object> { rule });

        private static bool WriteIfChanged(string path, string text)
        {
            if (File.Exists(path) && File.ReadAllText(path, Paths.Utf8) == text) return false;
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, text, Paths.Utf8);
            if (File.Exists(path)) File.Replace(tmp, path, null); else File.Move(tmp, path);
            return true;
        }

        private static List<string> ProcRegex(IEnumerable<string> names) =>
            names.Where(n => !string.IsNullOrWhiteSpace(n)).Select(n => @"(?i)(^|[\\/])" + Regex.Escape(n.Trim()) + "$").ToList();

        /// <summary>Plain entry = the domain and its subdomains; prefixes full: keyword: regex:.</summary>
        public static void AddDomainFields(JObj rule, IEnumerable<string> entries)
        {
            var dom = new List<string>(); var suf = new List<string>(); var kw = new List<string>(); var rx = new List<string>();
            foreach (var e in entries)
            {
                var v = e.Trim(); if (v.Length == 0) continue;
                var lower = v.ToLowerInvariant();
                if (lower.StartsWith("full:")) dom.Add(lower.Substring(5));
                else if (lower.StartsWith("keyword:")) kw.Add(lower.Substring(8));
                else if (lower.StartsWith("regex:")) rx.Add(v.Substring(6));
                else { lower = lower.TrimStart('.'); dom.Add(lower); suf.Add("." + lower); }
            }
            if (dom.Count > 0) rule.Set("domain", dom);
            if (suf.Count > 0) rule.Set("domain_suffix", suf);
            if (kw.Count > 0) rule.Set("domain_keyword", kw);
            if (rx.Count > 0) rule.Set("domain_regex", rx);
        }

        /// <summary>Rewrites the small user rule-sets; sing-box picks the changes up without a restart.</summary>
        public static bool WriteUserRuleSets(Settings s)
        {
            var direct = s.Apps.Where(a => !a.Vpn).SelectMany(a => a.Processes);
            var proxy = s.Apps.Where(a => a.Vpn).SelectMany(a => a.Processes);
            var sets = new Dictionary<string, JObj>
            {
                ["apps-block"] = Proc(s.BlockProcesses),
                ["apps-direct"] = Proc(direct),
                ["apps-proxy"] = Proc(proxy),
            };
            var dd = new JObj(); AddDomainFields(dd, s.DirectDomains); sets["direct-domains"] = dd;
            var pd = new JObj(); AddDomainFields(pd, s.ProxyDomains); sets["proxy-domains"] = pd;
            sets["direct-ips"] = s.DirectIps.Count > 0 ? new JObj().Set("ip_cidr", s.DirectIps) : null;
            sets["proxy-ips"] = s.ProxyIps.Count > 0 ? new JObj().Set("ip_cidr", s.ProxyIps) : null;
            var changed = false;
            foreach (var kv in sets)
                changed |= WriteIfChanged(Path.Combine(Paths.RulesDir, kv.Key + ".json"), Json.Serialize(RuleSetFile(kv.Value)));
            return changed;
        }

        private static JObj Proc(IEnumerable<string> names)
        {
            var rx = ProcRegex(names);
            return rx.Count > 0 ? new JObj().Set("process_path_regex", rx) : null;
        }

        /// <summary>Russian networks / domains from the Xray geo databases (cached by a stamp file).</summary>
        public static void WriteGeoRuleSets(Settings s)
        {
            var geoip = Path.Combine(Paths.BinDir, "geoip.dat");
            var geosite = Path.Combine(Paths.BinDir, "geosite.dat");
            var ipCodes = s.RuDirect ? s.RuGeoip : new List<string>();
            var siteCodes = s.RuDirect ? s.RuGeosite : new List<string>();
            var blockedCodes = s.RuDirect ? s.RuBlockedGeosite : new List<string>();
            long t1 = File.Exists(geoip) ? File.GetLastWriteTimeUtc(geoip).Ticks : 0, t2 = File.Exists(geosite) ? File.GetLastWriteTimeUtc(geosite).Ticks : 0;
            var stamp = string.Join("|", "v2", string.Join(",", ipCodes), string.Join(",", siteCodes), string.Join(",", blockedCodes), t1, t2);
            var stampFile = Path.Combine(Paths.RulesDir, "geo.stamp");
            var files = GeoRuleSets.Select(g => Path.Combine(Paths.RulesDir, g + ".json")).ToList();
            if (files.All(File.Exists) && File.Exists(stampFile) && File.ReadAllText(stampFile) == stamp) return;

            var cidrs = GeoDat.Cidrs(geoip, ipCodes);
            var site = GeoDat.Domains(geosite, siteCodes, out var nSite);
            var blocked = GeoDat.Domains(geosite, blockedCodes, out var nBlocked);
            WriteIfChanged(Path.Combine(Paths.RulesDir, "geoip-ru.json"), Json.Serialize(RuleSetFile(cidrs.Count > 0 ? new JObj().Set("ip_cidr", cidrs) : null)));
            WriteIfChanged(Path.Combine(Paths.RulesDir, "geosite-ru.json"), Json.Serialize(RuleSetFile(site)));
            WriteIfChanged(Path.Combine(Paths.RulesDir, "geosite-ru-blocked.json"), Json.Serialize(RuleSetFile(blocked)));
            File.WriteAllText(stampFile, stamp);
            Log.Write($"geo: {cidrs.Count} RU networks, {nSite} RU domains, {nBlocked} blocked-in-RU domains");
        }

        // ------------------------------------------------------------------ main config

        private static void AddRoute(List<object> list, JObj match, string target, bool blockQuic)
        {
            JObj Copy() { var r = new JObj(); foreach (var kv in match) r[kv.Key] = kv.Value; return r; }
            if (target == "block") { list.Add(Copy().Set("action", "reject")); return; }
            if (target == "proxy" && blockQuic) list.Add(Copy().Set("protocol", "quic").Set("action", "reject"));
            list.Add(Copy().Set("outbound", target));
        }

        private static JObj RuleSet(params string[] tags) => new JObj().Set("rule_set", tags.ToList());

        public static JObj Build(Settings s, bool tun, List<Node> nodes, string logFile)
        {
            var def = s.Default == "direct" ? "direct" : "proxy";
            var order = def == "proxy" ? new[] { "proxy", "direct" } : new[] { "direct", "proxy" };
            var q = s.BlockQuicOnProxy;

            var rules = new List<object>
            {
                new JObj().Set("action", "sniff"),
                new JObj().Set("protocol", "dns").Set("action", "hijack-dns"),
                new JObj().Set("process_path_regex", new List<object> { "(?i)^" + Regex.Escape(Paths.XrayExe) + "$" }).Set("outbound", "direct"),
            };
            if (s.CheckpointEnabled)
            {
                rules.Add(new JObj().Set("process_path_regex", new List<object> { "(?i)^" + Regex.Escape(s.CheckpointPath.TrimEnd('\\')) + @"\\" }).Set("outbound", "direct"));
                rules.Add(new JObj().Set("network", "udp").Set("port", new List<object> { 500, 4500 }).Set("outbound", "direct"));
                var cp = NetInfo.CheckpointRoutes(s);
                if (cp.Count > 0) rules.Add(new JObj().Set("ip_cidr", cp).Set("outbound", "direct"));
            }
            rules.Add(new JObj().Set("ip_is_private", true).Set("outbound", "direct"));

            // "Selected programs" mode: everything ProxiFyre hands over belongs to a program with the VPN rule.
            if (s.Mode == "apps") AddRoute(rules, new JObj().Set("inbound", new List<object> { "apps-in" }), "proxy", q);

            AddRoute(rules, RuleSet("apps-block"), "block", false);
            AddRoute(rules, RuleSet("apps-direct"), "direct", q);
            AddRoute(rules, RuleSet("apps-proxy"), "proxy", q);
            foreach (var t in order) AddRoute(rules, RuleSet(t + "-domains", t + "-ips"), t, q);
            AddRoute(rules, RuleSet("geosite-ru-blocked"), "proxy", q);
            AddRoute(rules, RuleSet("geosite-ru", "geoip-ru"), "direct", false);
            if (def == "proxy" && q) rules.Add(new JObj().Set("protocol", "quic").Set("action", "reject"));

            var dnsDirect = tun
                ? new JObj().Set("type", "udp").Set("tag", "dns-direct").Set("server", NetInfo.DirectDns(s))
                : new JObj().Set("type", "local").Set("tag", "dns-direct");
            var dnsRules = new List<object>();
            foreach (var t in order) dnsRules.Add(RuleSet(t + "-domains").Set("server", "dns-" + t));
            dnsRules.Add(RuleSet("geosite-ru-blocked").Set("server", "dns-proxy"));
            dnsRules.Add(RuleSet("geosite-ru").Set("server", "dns-direct"));
            var dns = new JObj()
                .Set("servers", new List<object> { new JObj().Set("type", "https").Set("tag", "dns-proxy").Set("server", string.IsNullOrEmpty(s.DnsProxy) ? "1.1.1.1" : s.DnsProxy).Set("detour", "proxy"), dnsDirect })
                .Set("rules", dnsRules)
                .Set("final", "dns-" + def)
                .Set("strategy", "ipv4_only");

            var ruleSets = SingBoxConfig.UserRuleSets.Concat(GeoRuleSets)
                .Select(tag => (object)new JObj().Set("type", "local").Set("tag", tag).Set("format", "source").Set("path", Path.Combine(Paths.RulesDir, tag + ".json"))).ToList();

            var inbounds = new List<object> { new JObj().Set("type", "mixed").Set("tag", "mixed-in").Set("listen", "127.0.0.1").Set("listen_port", s.ProxyPort) };
            if (s.Mode == "apps")
                inbounds.Add(new JObj().Set("type", "socks").Set("tag", "apps-in").Set("listen", "127.0.0.1").Set("listen_port", s.AppsPort));
            if (tun)
            {
                var addr = new List<string> { s.TunAddress4 };
                // Without native IPv6 an IPv6 route on the tunnel makes direct IPv6 connections hang; Windows uses IPv4 when there is none.
                var v6 = s.TunIpv6 == "on" || (s.TunIpv6 != "off" && NetInfo.HasNativeIPv6(s));
                if (v6 && !string.IsNullOrWhiteSpace(s.TunAddress6)) addr.Add(s.TunAddress6);
                var ex = s.ExcludeRoutes.Concat(NetInfo.ServerRoutes(s, nodes)).Concat(NetInfo.CheckpointRoutes(s))
                    .Where(x => v6 || !x.Contains(":")).Distinct().ToList();
                inbounds.Add(new JObj()
                    .Set("type", "tun").Set("tag", "tun-in").Set("interface_name", s.TunName)
                    .Set("address", addr).Set("mtu", s.TunMtu).Set("auto_route", true).Set("strict_route", false)
                    .Set("stack", s.TunStack).Set("route_exclude_address", ex));
            }

            return new JObj()
                .Set("log", new JObj().Set("level", string.IsNullOrEmpty(s.LogLevel) ? "warn" : s.LogLevel).Set("output", logFile).Set("timestamp", true))
                .Set("dns", dns)
                .Set("inbounds", inbounds)
                .Set("outbounds", new List<object>
                {
                    new JObj().Set("type", "socks").Set("tag", "proxy").Set("server", "127.0.0.1").Set("server_port", s.XrayPort).Set("version", "5"),
                    new JObj().Set("type", "direct").Set("tag", "direct"),
                })
                .Set("route", new JObj()
                    .Set("rules", rules).Set("rule_set", ruleSets).Set("final", def)
                    .Set("auto_detect_interface", true).Set("default_domain_resolver", "dns-direct"))
                .Set("experimental", new JObj().Set("clash_api", new JObj()
                    .Set("external_controller", "127.0.0.1:" + s.ApiPort).Set("secret", s.ApiSecret)));
        }
    }
}
