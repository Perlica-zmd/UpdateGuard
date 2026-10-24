using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace LiquidWU
{
    // =====================================================================
    //  Windows 11 Fluent theme: white background, light-bordered cards, accent buttons
    // =====================================================================
    public static class Theme
    {
        public static readonly Color WindowBg     = Color.FromArgb(255, 255, 255);
        public static readonly Color CardBg       = Color.FromArgb(250, 250, 250);
        public static readonly Color CardBorder   = Color.FromArgb(233, 233, 233);
        public static readonly Color Divider      = Color.FromArgb(240, 240, 240);
        public static readonly Color Text         = Color.FromArgb(26, 26, 26);
        public static readonly Color TextSecond   = Color.FromArgb(96, 96, 96);
        public static readonly Color TextThird    = Color.FromArgb(144, 144, 144);
        public static readonly Color Accent       = Color.FromArgb(0, 103, 192);
        public static readonly Color AccentHover  = Color.FromArgb(25, 117, 197);
        public static readonly Color AccentPress  = Color.FromArgb(49, 131, 202);
        public static readonly Color BtnBg        = Color.FromArgb(253, 253, 253);
        public static readonly Color BtnHover     = Color.FromArgb(246, 246, 246);
        public static readonly Color BtnPress     = Color.FromArgb(240, 240, 240);
        public static readonly Color BtnBorder    = Color.FromArgb(214, 214, 214);
        public static readonly Color Success      = Color.FromArgb(15, 123, 15);
        public static readonly Color Warning      = Color.FromArgb(157, 93, 0);
        public static readonly Color Danger       = Color.FromArgb(196, 43, 28);
        public static readonly Color DisabledBg   = Color.FromArgb(249, 249, 249);
        public static readonly Color DisabledText = Color.FromArgb(160, 160, 160);

        private static FontFamily _fam;

        public static FontFamily Family()
        {
            if (_fam != null) return _fam;
            string[] names = { "Microsoft YaHei UI", "Microsoft YaHei", "Segoe UI", "Tahoma" };
            foreach (string n in names)
            {
                try { _fam = new FontFamily(n); return _fam; }
                catch { }
            }
            _fam = FontFamily.GenericSansSerif;
            return _fam;
        }

        public static GraphicsPath Rounded(RectangleF r, float radius)
        {
            GraphicsPath p = new GraphicsPath();
            float d = radius * 2f;
            if (d <= 1f) { p.AddRectangle(r); return p; }
            if (d > r.Width) d = r.Width;
            if (d > r.Height) d = r.Height;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        /// <summary>A very soft shadow, just enough to lift a card off the white background.</summary>
        public static void SoftShadow(Graphics g, Rectangle r, float radius)
        {
            for (int i = 3; i >= 1; i--)
            {
                Rectangle rr = new Rectangle(r.X - i, r.Y - i + 2, r.Width + i * 2, r.Height + i * 2);
                using (GraphicsPath p = Rounded(rr, radius + i))
                using (Pen pen = new Pen(Color.FromArgb(7 / i + 3, 0, 0, 0), 3f))
                    g.DrawPath(pen, p);
            }
        }

        public static void Card(Graphics g, Rectangle r, float radius, bool shadow)
        {
            if (shadow) SoftShadow(g, r, radius);
            using (GraphicsPath p = Rounded(r, radius))
            {
                using (SolidBrush b = new SolidBrush(CardBg)) g.FillPath(b, p);
                using (Pen pen = new Pen(CardBorder, 1f)) g.DrawPath(pen, p);
            }
        }

        public static void Dot(Graphics g, float x, float y, float r, Color c)
        {
            using (SolidBrush b = new SolidBrush(c))
                g.FillEllipse(b, x - r, y - r, r * 2, r * 2);
        }

        public static void HLine(Graphics g, int x1, int x2, int y, Color c)
        {
            using (Pen p = new Pen(c, 1f)) g.DrawLine(p, x1, y, x2, y);
        }
    }

    public enum WinButtonKind { Accent, Standard }

    // =====================================================================
    //  Win11 style button
    // =====================================================================
    public class WinButton : Control
    {
        public WinButtonKind Kind = WinButtonKind.Standard;
        public bool Enabled2 = true;

        private bool hover;
        private bool down;

        public WinButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Cursor = Cursors.Hand;
            Font = new Font(Theme.Family(), 10f, FontStyle.Regular);
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
            float radius = 6f;

            Color fill, border, fore;
            if (!Enabled2) { fill = Theme.DisabledBg; border = Theme.CardBorder; fore = Theme.DisabledText; }
            else if (Kind == WinButtonKind.Accent)
            {
                fill = down ? Theme.AccentPress : (hover ? Theme.AccentHover : Theme.Accent);
                border = fill;
                fore = Color.White;
            }
            else
            {
                fill = down ? Theme.BtnPress : (hover ? Theme.BtnHover : Theme.BtnBg);
                border = Theme.BtnBorder;
                fore = down ? Theme.TextSecond : Theme.Text;
            }

            using (GraphicsPath p = Theme.Rounded(r, radius))
            {
                using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
                using (Pen pen = new Pen(border, 1f)) g.DrawPath(pen, p);
            }
            TextRenderer.DrawText(g, Text, Font, r, fore,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }
}
