using System.Collections.Generic;
using System.Linq;

namespace VlessClient.Core
{
    public static class XrayConfig
    {
        public static JObj Outbound(Node n)
        {
            var user = new JObj().Set("id", n.Id).Set("encryption", n.Q("encryption").Length > 0 ? n.Q("encryption") : "none");
            if (n.Q("flow").Length > 0) user.Set("flow", n.Q("flow"));

            var net = n.Q("type"); if (net.Length == 0 || net == "tcp") net = "raw";
            var sec = n.Q("security"); if (sec.Length == 0) sec = "none";
            var stream = new JObj().Set("network", net).Set("security", sec);

            if (sec == "reality")
            {
                var re = new JObj().Set("serverName", n.Q("sni")).Set("fingerprint", n.Q("fp").Length > 0 ? n.Q("fp") : "chrome")
                    .Set("publicKey", n.Q("pbk")).Set("shortId", n.Q("sid"));
                if (n.Q("spx").Length > 0) re.Set("spiderX", n.Q("spx"));
                if (n.Q("pqv").Length > 0) re.Set("mldsa65Verify", n.Q("pqv"));
                stream.Set("realitySettings", re);
            }
            else if (sec == "tls")
            {
                var tls = new JObj().Set("serverName", n.Q("sni"));
                if (n.Q("fp").Length > 0) tls.Set("fingerprint", n.Q("fp"));
                if (n.Q("alpn").Length > 0) tls.Set("alpn", n.Q("alpn").Split(',').ToList());
                if (n.Q("allowInsecure") == "1") tls.Set("allowInsecure", true);
                stream.Set("tlsSettings", tls);
            }

            switch (net)
            {
                case "xhttp":
                    {
                        var x = new JObj();
                        if (n.Q("path").Length > 0) x.Set("path", n.Q("path"));
                        if (n.Q("host").Length > 0) x.Set("host", n.Q("host"));
                        if (n.Q("mode").Length > 0) x.Set("mode", n.Q("mode"));
                        if (n.Q("extra").Length > 0) { try { x.Set("extra", Json.Parse(n.Q("extra"))); } catch { } }
                        stream.Set("xhttpSettings", x);
                        break;
                    }
                case "ws":
                    {
                        var w = new JObj();
                        if (n.Q("path").Length > 0) w.Set("path", n.Q("path"));
                        if (n.Q("host").Length > 0) w.Set("host", n.Q("host"));
                        stream.Set("wsSettings", w);
                        break;
                    }
                case "grpc":
                    {
                        var g = new JObj().Set("serviceName", n.Q("serviceName"));
                        if (n.Q("authority").Length > 0) g.Set("authority", n.Q("authority"));
                        stream.Set("grpcSettings", g);
                        break;
                    }
                case "httpupgrade":
                    {
                        var h = new JObj();
                        if (n.Q("path").Length > 0) h.Set("path", n.Q("path"));
                        if (n.Q("host").Length > 0) h.Set("host", n.Q("host"));
                        stream.Set("httpupgradeSettings", h);
                        break;
                    }
            }

            return new JObj()
                .Set("tag", n.Tag)
                .Set("protocol", "vless")
                .Set("settings", new JObj().Set("vnext", new List<object> { new JObj().Set("address", n.Address).Set("port", n.Port).Set("users", new List<object> { user }) }))
                .Set("streamSettings", stream);
        }

        /// <summary>Main config: SOCKS inbound for sing-box, the chosen node and (optionally) a spare that takes over only while the chosen one fails.</summary>
        public static JObj Main(Node main, Node spare, int port, string logFile)
        {
            var outs = new List<object> { Outbound(main) };
            if (spare != null) outs.Add(Outbound(spare));
            var cfg = new JObj()
                .Set("log", new JObj().Set("loglevel", "warning").Set("error", logFile).Set("access", "none"))
                .Set("inbounds", new List<object> { new JObj().Set("tag", "socks-in").Set("listen", "127.0.0.1").Set("port", port).Set("protocol", "socks")
                    .Set("settings", new JObj().Set("auth", "noauth").Set("udp", true)) })
                .Set("outbounds", outs);
            if (spare != null)
            {
                // One-candidate balancer: traffic never hops between nodes; fallbackTag is used only while the main node fails its probe.
                cfg.Set("routing", new JObj()
                    .Set("domainStrategy", "AsIs")
                    .Set("rules", new List<object> { new JObj().Set("inboundTag", new List<object> { "socks-in" }).Set("balancerTag", "main") })
                    .Set("balancers", new List<object> { new JObj().Set("tag", "main").Set("selector", new List<object> { main.Tag })
                        .Set("strategy", new JObj().Set("type", "leastPing")).Set("fallbackTag", spare.Tag) }));
                cfg.Set("observatory", new JObj().Set("subjectSelector", new List<object> { main.Tag })
                    .Set("probeUrl", "https://www.gstatic.com/generate_204").Set("probeInterval", "1m").Set("enableConcurrency", false));
            }
            return cfg;
        }

        /// <summary>Probe config: one SOCKS port per node (basePort + index).</summary>
        public static JObj Probe(IEnumerable<Node> nodes, int basePort, string logFile)
        {
            var ins = new List<object>();
            var outs = new List<object>();
            var rules = new List<object>();
            foreach (var n in nodes)
            {
                var itag = "in-" + n.Tag;
                ins.Add(new JObj().Set("tag", itag).Set("listen", "127.0.0.1").Set("port", basePort + n.Index).Set("protocol", "socks")
                    .Set("settings", new JObj().Set("auth", "noauth").Set("udp", false)));
                outs.Add(Outbound(n));
                rules.Add(new JObj().Set("inboundTag", new List<object> { itag }).Set("outboundTag", n.Tag));
            }
            return new JObj()
                .Set("log", new JObj().Set("loglevel", "warning").Set("error", logFile).Set("access", "none"))
                .Set("inbounds", ins)
                .Set("outbounds", outs)
                .Set("routing", new JObj().Set("domainStrategy", "AsIs").Set("rules", rules));
        }
    }
}
