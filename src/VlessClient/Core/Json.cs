using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Web.Script.Serialization;

namespace VlessClient.Core
{
    /// <summary>Small JSON helper: parsing through JavaScriptSerializer, writing with indentation.</summary>
    public static class Json
    {
        private static JavaScriptSerializer NewSerializer() => new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024, RecursionLimit = 256 };

        public static object Parse(string text) => NewSerializer().DeserializeObject(text);

        public static Dictionary<string, object> ParseObject(string text) => Parse(text) as Dictionary<string, object> ?? new Dictionary<string, object>();

        public static string Serialize(object value, bool indent = false)
        {
            var sb = new StringBuilder();
            Write(sb, value, indent, 0);
            return sb.ToString();
        }

        private static void Write(StringBuilder sb, object v, bool indent, int level)
        {
            switch (v)
            {
                case null: sb.Append("null"); return;
                case string s: WriteString(sb, s); return;
                case bool b: sb.Append(b ? "true" : "false"); return;
                case int i: sb.Append(i.ToString(CultureInfo.InvariantCulture)); return;
                case long l: sb.Append(l.ToString(CultureInfo.InvariantCulture)); return;
                case double d: sb.Append(d.ToString("R", CultureInfo.InvariantCulture)); return;
                case decimal m: sb.Append(m.ToString(CultureInfo.InvariantCulture)); return;
                case float f: sb.Append(f.ToString("R", CultureInfo.InvariantCulture)); return;
                case IDictionary dict:
                    {
                        if (dict.Count == 0) { sb.Append("{}"); return; }
                        sb.Append('{');
                        var first = true;
                        foreach (DictionaryEntry e in dict)
                        {
                            if (!first) sb.Append(',');
                            first = false;
                            NewLine(sb, indent, level + 1);
                            WriteString(sb, Convert.ToString(e.Key, CultureInfo.InvariantCulture));
                            sb.Append(indent ? ": " : ":");
                            Write(sb, e.Value, indent, level + 1);
                        }
                        NewLine(sb, indent, level);
                        sb.Append('}');
                        return;
                    }
                case IEnumerable list:
                    {
                        var items = new List<object>();
                        foreach (var x in list) items.Add(x);
                        if (items.Count == 0) { sb.Append("[]"); return; }
                        var simple = indent && items.TrueForAll(x => x == null || x is string || x is bool || x is int || x is long || x is double || x is decimal);
                        sb.Append('[');
                        for (var k = 0; k < items.Count; k++)
                        {
                            if (k > 0) sb.Append(',');
                            if (simple && items.Count <= 4 && !(items[k] is string)) { if (k > 0) sb.Append(' '); }
                            else NewLine(sb, indent, level + 1);
                            Write(sb, items[k], indent, level + 1);
                        }
                        if (!(simple && items.Count <= 4 && !(items[0] is string))) NewLine(sb, indent, level);
                        sb.Append(']');
                        return;
                    }
                default:
                    WriteString(sb, Convert.ToString(v, CultureInfo.InvariantCulture));
                    return;
            }
        }

        private static void NewLine(StringBuilder sb, bool indent, int level)
        {
            if (!indent) return;
            sb.Append('\n');
            sb.Append(' ', level * 2);
        }

        private static void WriteString(StringBuilder sb, string s)
        {
            sb.Append('"');
            foreach (var c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }

        // ---- reading helpers for Dictionary<string, object> trees

        public static Dictionary<string, object> Obj(this Dictionary<string, object> d, string key)
            => d != null && d.TryGetValue(key, out var v) ? v as Dictionary<string, object> : null;

        public static string Str(this Dictionary<string, object> d, string key, string def = "")
            => d != null && d.TryGetValue(key, out var v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : def;

        public static bool Bool(this Dictionary<string, object> d, string key, bool def = false)
        {
            if (d == null || !d.TryGetValue(key, out var v) || v == null) return def;
            if (v is bool b) return b;
            return bool.TryParse(Convert.ToString(v, CultureInfo.InvariantCulture), out var r) ? r : def;
        }

        public static int Int(this Dictionary<string, object> d, string key, int def = 0)
        {
            if (d == null || !d.TryGetValue(key, out var v) || v == null) return def;
            try { return Convert.ToInt32(v, CultureInfo.InvariantCulture); } catch { return def; }
        }

        public static double Num(this Dictionary<string, object> d, string key, double def = 0)
        {
            if (d == null || !d.TryGetValue(key, out var v) || v == null) return def;
            try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); } catch { return def; }
        }

        public static List<string> Strings(this Dictionary<string, object> d, string key)
        {
            var res = new List<string>();
            if (d == null || !d.TryGetValue(key, out var v) || v == null) return res;
            if (v is string one) { if (one.Trim().Length > 0) res.Add(one.Trim()); return res; }
            if (v is IEnumerable e)
                foreach (var x in e)
                {
                    var s = Convert.ToString(x, CultureInfo.InvariantCulture)?.Trim();
                    if (!string.IsNullOrEmpty(s)) res.Add(s);
                }
            return res;
        }

        public static List<Dictionary<string, object>> Objects(this Dictionary<string, object> d, string key)
        {
            var res = new List<Dictionary<string, object>>();
            if (d == null || !d.TryGetValue(key, out var v) || !(v is IEnumerable e) || v is string) return res;
            foreach (var x in e) if (x is Dictionary<string, object> o) res.Add(o);
            return res;
        }
    }

    /// <summary>Ordered dictionary shortcut for building configs.</summary>
    public sealed class JObj : Dictionary<string, object>
    {
        public JObj() : base(StringComparer.Ordinal) { }
        public JObj Set(string key, object value) { this[key] = value; return this; }
    }
}
