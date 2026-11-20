using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;

namespace VlessClient.Core
{
    /// <summary>Reads Xray's geoip.dat / geosite.dat (protobuf) and turns selected categories into sing-box rule-sets.</summary>
    public static class GeoDat
    {
        private static ulong V(byte[] b, ref int p)
        {
            ulong r = 0; var s = 0;
            while (true) { var x = b[p++]; r |= ((ulong)(x & 0x7F)) << s; if (x < 0x80) break; s += 7; }
            return r;
        }

        private static void Skip(byte[] b, ref int p, int wt)
        {
            if (wt == 0) V(b, ref p);
            else if (wt == 1) p += 8;
            else if (wt == 2) { var l = (int)V(b, ref p); p += l; }
            else if (wt == 5) p += 4;
            else throw new InvalidDataException("unsupported wire type " + wt);
        }

        private static bool Has(ICollection<string> codes, string cc) => codes.Any(c => string.Equals(c, cc, StringComparison.OrdinalIgnoreCase));

        public static List<string> Cidrs(string path, ICollection<string> codes)
        {
            var res = new List<string>();
            if (codes.Count == 0 || !File.Exists(path)) return res;
            var b = File.ReadAllBytes(path); var p = 0;
            while (p < b.Length)
            {
                var tag = V(b, ref p); var wt = (int)(tag & 7);
                if ((tag >> 3) != 1 || wt != 2) { Skip(b, ref p, wt); continue; }
                var len = (int)V(b, ref p); var end = p + len; var q = p; var match = false;
                while (q < end)
                {
                    var t = V(b, ref q); var w = (int)(t & 7); var f = (int)(t >> 3);
                    if (f == 1 && w == 2)
                    {
                        var l = (int)V(b, ref q); var cc = Encoding.UTF8.GetString(b, q, l); q += l;
                        match = Has(codes, cc); if (!match) break;
                    }
                    else if (f == 2 && w == 2 && match)
                    {
                        var l = (int)V(b, ref q); var e = q + l; byte[] ip = null; var prefix = 0;
                        while (q < e)
                        {
                            var t2 = V(b, ref q); var w2 = (int)(t2 & 7); var f2 = (int)(t2 >> 3);
                            if (f2 == 1 && w2 == 2) { var l2 = (int)V(b, ref q); ip = new byte[l2]; Array.Copy(b, q, ip, 0, l2); q += l2; }
                            else if (f2 == 2 && w2 == 0) prefix = (int)V(b, ref q);
                            else Skip(b, ref q, w2);
                        }
                        if (ip != null && (ip.Length == 4 || ip.Length == 16)) res.Add(new IPAddress(ip) + "/" + prefix);
                    }
                    else Skip(b, ref q, w);
                }
                p = end;
            }
            return res;
        }

        /// <summary>Returns a sing-box headless rule (domain / domain_suffix / domain_keyword / domain_regex) or null when empty.</summary>
        public static JObj Domains(string path, ICollection<string> codes, out int count)
        {
            count = 0;
            if (codes.Count == 0 || !File.Exists(path)) return null;
            var dom = new List<string>(); var suf = new List<string>(); var kw = new List<string>(); var rx = new List<string>();
            var b = File.ReadAllBytes(path); var p = 0;
            while (p < b.Length)
            {
                var tag = V(b, ref p); var wt = (int)(tag & 7);
                if ((tag >> 3) != 1 || wt != 2) { Skip(b, ref p, wt); continue; }
                var len = (int)V(b, ref p); var end = p + len; var q = p; var match = false;
                while (q < end)
                {
                    var t = V(b, ref q); var w = (int)(t & 7); var f = (int)(t >> 3);
                    if (f == 1 && w == 2)
                    {
                        var l = (int)V(b, ref q); var cc = Encoding.UTF8.GetString(b, q, l); q += l;
                        match = Has(codes, cc); if (!match) break;
                    }
                    else if (f == 2 && w == 2 && match)
                    {
                        var l = (int)V(b, ref q); var e = q + l; var type = 0; string val = null;
                        while (q < e)
                        {
                            var t2 = V(b, ref q); var w2 = (int)(t2 & 7); var f2 = (int)(t2 >> 3);
                            if (f2 == 1 && w2 == 0) type = (int)V(b, ref q);
                            else if (f2 == 2 && w2 == 2) { var l2 = (int)V(b, ref q); val = Encoding.UTF8.GetString(b, q, l2); q += l2; }
                            else Skip(b, ref q, w2);
                        }
                        if (string.IsNullOrEmpty(val)) continue;
                        if (type == 0) kw.Add(val);
                        else if (type == 1) rx.Add(val);
                        else if (type == 2) { dom.Add(val); suf.Add("." + val); }
                        else dom.Add(val);
                    }
                    else Skip(b, ref q, w);
                }
                p = end;
            }
            count = dom.Count + kw.Count + rx.Count;
            if (count == 0) return null;
            var r = new JObj();
            if (dom.Count > 0) r.Set("domain", dom);
            if (suf.Count > 0) r.Set("domain_suffix", suf);
            if (kw.Count > 0) r.Set("domain_keyword", kw);
            if (rx.Count > 0) r.Set("domain_regex", rx);
            return r;
        }
    }
}
