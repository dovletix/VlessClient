using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace VlessClient.Ui
{
    /// <summary>Tray icons drawn at run time: a shield in the colour of the current state.</summary>
    public static class Icons
    {
        public static readonly Color On = Color.FromArgb(22, 163, 74);
        public static readonly Color Off = Color.FromArgb(120, 128, 140);
        public static readonly Color Busy = Color.FromArgb(217, 119, 6);
        public static readonly Color Bad = Color.FromArgb(220, 38, 38);

        public static Icon Shield(Color fill, bool check)
        {
            const int size = 64;
            using (var bmp = new Bitmap(size, size))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    using (var path = new GraphicsPath())
                    {
                        path.AddLines(new[] { new PointF(32, 3), new PointF(57, 12), new PointF(57, 30) });
                        path.AddBezier(new PointF(57, 30), new PointF(57, 46), new PointF(46, 56), new PointF(32, 62));
                        path.AddBezier(new PointF(32, 62), new PointF(18, 56), new PointF(7, 46), new PointF(7, 30));
                        path.AddLines(new[] { new PointF(7, 30), new PointF(7, 12), new PointF(32, 3) });
                        path.CloseFigure();
                        using (var b = new SolidBrush(fill)) g.FillPath(b, path);
                    }
                    using (var pen = new Pen(Color.White, 7) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                    {
                        if (check) g.DrawLines(pen, new[] { new PointF(20, 33), new PointF(29, 42), new PointF(45, 24) });
                        else g.DrawLine(pen, 21, 33, 43, 33);
                    }
                }
                var h = bmp.GetHicon();
                try { return (Icon)Icon.FromHandle(h).Clone(); }
                finally { DestroyIcon(h); }
            }
        }

        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr handle);
    }
}
