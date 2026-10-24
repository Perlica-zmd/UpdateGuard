using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Threading;
using System.Windows.Forms;

namespace LiquidWU
{
    public class MainForm : Form
    {
        private WinButton btnDisable, btnRestore, btnRefresh;
        private System.Windows.Forms.Timer confirmTimer;

        private List<string[]> logs = new List<string[]>();
        private List<SvcInfo> svcs = new List<SvcInfo>();
        private bool policyOn;
        private bool admin;

        private string heroSub = "正在检测状态...";
        private bool busy;
        private string pendingConfirm = "";

        private float S = 1f;
        private Font fTitle, fHero, fSub, fSmall, fBody, fMono;
        private int pad, titleH, heroY, heroH, btnY, btnH, svcY, svcH, logY, logH;
        private int btnW1, btnW2, btnW3;
        private bool hoverClose, hoverMin;
        private Rectangle capMin, capClose;

        // ---- 进度条状态(过程默认折叠成进度条) ----
        private int progressValue;              // 目标百分比
        private double progressShown;           // 平滑显示值
        private string progressStage = "就绪";
        private string progressResult = "";     // 完成后的结果摘要
        private bool logVisible;                // 是否展开详细日志
        private bool hasError;
        private System.Windows.Forms.Timer animTimer;
        private Rectangle linkRect;
        private bool hoverLink;

        public MainForm(string autoAction)
        {
            Text = "更新守卫";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            KeyPreview = true;

            using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) S = g.DpiX / 96f;
            if (S < 1f) S = 1f;
            ClientSize = new Size((int)(460 * S), (int)(680 * S));

            admin = WuCore.IsAdmin();

            btnDisable = new WinButton();
            btnDisable.Text = "禁用更新";
            btnDisable.Kind = WinButtonKind.Accent;

            btnRestore = new WinButton();
            btnRestore.Text = "恢复更新";
            btnRestore.Kind = WinButtonKind.Standard;

            btnRefresh = new WinButton();
            btnRefresh.Text = "刷新";
            btnRefresh.Kind = WinButtonKind.Standard;

            btnDisable.Click += delegate { OnAction("disable"); };
            btnRestore.Click += delegate { OnAction("restore"); };
            btnRefresh.Click += delegate { RefreshStatus(); };

            Controls.Add(btnDisable);
            Controls.Add(btnRestore);
            Controls.Add(btnRefresh);

            confirmTimer = new System.Windows.Forms.Timer();
            confirmTimer.Interval = 4000;
            confirmTimer.Tick += delegate
            {
                confirmTimer.Stop();
                if (pendingConfirm != "")
                {
                    pendingConfirm = "";
                    btnDisable.Text = "禁用更新";
                    btnRestore.Text = "恢复更新";
                    AddLog("确认已超时, 操作取消", LogLevel.Warn);
                }
            };

            animTimer = new System.Windows.Forms.Timer();
            animTimer.Interval = 50;
            animTimer.Tick += delegate
            {
                double diff = progressValue - progressShown;
                if (Math.Abs(diff) < 0.4)
                {
                    progressShown = progressValue;
                    if (!busy) animTimer.Stop();
                }
                else progressShown += diff * 0.18;
                Invalidate();
            };

            DoLayout();

            MouseDown += OnFormMouseDown;
            MouseMove += OnFormMouseMove;
            MouseLeave += delegate { hoverClose = false; hoverMin = false; Invalidate(); };
            KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Close(); };

            AddLog("更新守卫 已启动", LogLevel.Info);
            AddLog(admin ? "已获得管理员权限" : "当前为普通权限, 执行操作时会请求授权", admin ? LogLevel.Ok : LogLevel.Warn);
            RefreshStatus();
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ClassStyle |= 0x20000;   // CS_DROPSHADOW
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.EnableRoundedCorners(Handle);
        }

        // ------------------------------------------------------------ 布局
        private void DoLayout()
        {
            if (btnDisable == null) return;
            pad = (int)(20 * S);
            titleH = (int)(48 * S);

            int w = ClientSize.Width - pad * 2;
            heroY = titleH + (int)(6 * S);
            heroH = (int)(106 * S);
            btnY = heroY + heroH + (int)(16 * S);
            btnH = (int)(40 * S);
            svcY = btnY + btnH + (int)(16 * S);
            svcH = (int)(176 * S);
            logY = svcY + svcH + (int)(16 * S);
            logH = ClientSize.Height - pad - logY;
            if (logH < (int)(80 * S)) logH = (int)(80 * S);

            int gap = (int)(10 * S);
            btnW1 = (int)(w * 0.40f);
            btnW2 = (int)(w * 0.40f);
            btnW3 = w - btnW1 - btnW2 - gap * 2;

            btnDisable.Bounds = new Rectangle(pad, btnY, btnW1, btnH);
            btnRestore.Bounds = new Rectangle(pad + btnW1 + gap, btnY, btnW2, btnH);
            btnRefresh.Bounds = new Rectangle(pad + btnW1 + btnW2 + gap * 2, btnY, btnW3, btnH);

            int cw = (int)(42 * S), ch = (int)(32 * S);
            capClose = new Rectangle(ClientSize.Width - pad - cw + (int)(6 * S), (titleH - ch) / 2, cw, ch);
            capMin = new Rectangle(capClose.X - cw, capClose.Y, cw, ch);

            if (fTitle != null) { fTitle.Dispose(); fHero.Dispose(); fSub.Dispose(); fSmall.Dispose(); fBody.Dispose(); fMono.Dispose(); }
            FontFamily fam = Theme.Family();
            fTitle = new Font(fam, 10f * S, FontStyle.Regular);
            fHero = new Font(fam, 17f * S, FontStyle.Bold);
            fSub = new Font(fam, 10f * S, FontStyle.Regular);
            fSmall = new Font(fam, 8.6f * S, FontStyle.Regular);
            fBody = new Font(fam, 10.5f * S, FontStyle.Bold);
            fMono = new Font("Consolas", 8.8f * S, FontStyle.Regular);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            if (ClientSize.Width <= 0 || ClientSize.Height <= 0) return;
            DoLayout();
        }

        // ------------------------------------------------------------ 绘制
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            e.Graphics.Clear(Theme.WindowBg);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

            DrawTitleBar(g);
            DrawHero(g);
            DrawServices(g);
            DrawProgress(g);

            using (Pen p = new Pen(Theme.CardBorder, 1f))
                g.DrawRectangle(p, 0, 0, ClientSize.Width - 1, ClientSize.Height - 1);
        }

        private void DrawAppIcon(Graphics g, RectangleF r)
        {
            using (GraphicsPath p = Theme.Rounded(r, r.Width * 0.28f))
            {
                using (LinearGradientBrush lg = new LinearGradientBrush(r,
                    Color.FromArgb(255, 76, 130, 245), Color.FromArgb(255, 0, 103, 192), 55f))
                    g.FillPath(lg, p);
            }
            float cx = r.X + r.Width / 2f, top = r.Y + r.Height * 0.22f;
            float w = r.Width * 0.46f, h = r.Height * 0.54f;
            PointF[] pts = new PointF[] {
                new PointF(cx, top),
                new PointF(cx + w / 2f, top + h * 0.18f),
                new PointF(cx + w / 2f, top + h * 0.56f),
                new PointF(cx, top + h),
                new PointF(cx - w / 2f, top + h * 0.56f),
                new PointF(cx - w / 2f, top + h * 0.18f)
            };
            using (GraphicsPath sp = new GraphicsPath())
            {
                sp.AddPolygon(pts);
                using (SolidBrush b = new SolidBrush(Color.FromArgb(245, 255, 255, 255))) g.FillPath(b, sp);
            }
            using (Pen pen = new Pen(Color.FromArgb(255, 0, 103, 192), Math.Max(1.4f, r.Width * 0.075f)))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
                g.DrawLines(pen, new PointF[] {
                    new PointF(cx - w * 0.26f, top + h * 0.45f),
                    new PointF(cx - w * 0.04f, top + h * 0.62f),
                    new PointF(cx + w * 0.30f, top + h * 0.26f)
                });
            }
        }

        private void DrawTitleBar(Graphics g)
        {
            float ic = 22 * S;
            float x = pad + 2 * S;
            float y = (titleH - ic) / 2f;
            DrawAppIcon(g, new RectangleF(x, y, ic, ic));

            g.DrawString("更新守卫", fTitle, new SolidBrush(Theme.Text), x + ic + 10 * S, y + 3 * S);

            DrawCaptionButton(g, capMin, false, hoverMin);
            DrawCaptionButton(g, capClose, true, hoverClose);
        }

        private void DrawCaptionButton(Graphics g, Rectangle r, bool isClose, bool hover)
        {
            if (hover)
            {
                using (GraphicsPath p = Theme.Rounded(r, 4f))
                using (SolidBrush b = new SolidBrush(isClose ? Theme.Danger : Color.FromArgb(240, 240, 240)))
                    g.FillPath(b, p);
            }
            Color fore = (isClose && hover) ? Color.White : Theme.Text;
            float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
            float k = 5f * S;
            using (Pen pen = new Pen(fore, 1.4f))
            {
                if (isClose)
                {
                    g.DrawLine(pen, cx - k, cy - k, cx + k, cy + k);
                    g.DrawLine(pen, cx + k, cy - k, cx - k, cy + k);
                }
                else g.DrawLine(pen, cx - k, cy, cx + k, cy);
            }
        }

        private void DrawHero(Graphics g)
        {
            int dis = 0;
            foreach (SvcInfo s in svcs) if (s.IsDisabled) dis++;
            bool allOff = svcs.Count > 0 && dis == svcs.Count;

            Rectangle card = new Rectangle(pad, heroY, ClientSize.Width - pad * 2, heroH);
            Theme.Card(g, card, 8f, true);

            float x = card.X + 20 * S;
            float y = card.Y + 18 * S;
            Color stateColor = allOff ? Theme.Success : Theme.Warning;

            Theme.Dot(g, x + 5 * S, y + 12 * S, 5 * S, stateColor);
            g.DrawString(allOff ? "更新已锁死" : "更新未完全禁用", fHero,
                new SolidBrush(Theme.Text), x + 18 * S, y - 2 * S);

            string txt = allOff ? "已禁用" : (svcs.Count == 0 ? "检测中" : "部分启用");
            SizeF sz = g.MeasureString(txt, fSmall);
            int pw = (int)sz.Width + (int)(26 * S), ph = (int)(24 * S);
            Rectangle pill = new Rectangle(card.Right - pw - (int)(18 * S), (int)(y + 2 * S), pw, ph);
            using (GraphicsPath p = Theme.Rounded(pill, ph / 2f))
            {
                using (SolidBrush b = new SolidBrush(allOff ? Color.FromArgb(232, 245, 233) : Color.FromArgb(255, 246, 229)))
                    g.FillPath(b, p);
                using (Pen pen = new Pen(allOff ? Color.FromArgb(190, 225, 195) : Color.FromArgb(240, 220, 180), 1f))
                    g.DrawPath(pen, p);
            }
            Theme.Dot(g, pill.X + 12 * S, pill.Y + ph / 2f, 3.5f * S, stateColor);
            g.DrawString(txt, fSmall, new SolidBrush(allOff ? Theme.Success : Theme.Warning),
                pill.X + 21 * S, pill.Y + (ph - sz.Height) / 2f);

            g.DrawString(heroSub, fSub, new SolidBrush(Theme.TextSecond), x + 18 * S, y + 34 * S);
            g.DrawString(admin ? "管理员权限已获得" : "需要管理员权限才能执行操作", fSmall,
                new SolidBrush(admin ? Theme.TextThird : Theme.Warning), x + 18 * S, y + 58 * S);
        }

        private void DrawServices(Graphics g)
        {
            Rectangle card = new Rectangle(pad, svcY, ClientSize.Width - pad * 2, svcH);
            Theme.Card(g, card, 8f, true);

            float x = card.X + 20 * S;
            float y = card.Y + 16 * S;
            g.DrawString("更新相关服务", fBody, new SolidBrush(Theme.Text), x, y);

            string pol = policyOn ? "组策略 NoAutoUpdate = 1" : "组策略未生效";
            SizeF sz = g.MeasureString(pol, fSmall);
            g.DrawString(pol, fSmall, new SolidBrush(policyOn ? Theme.Success : Theme.Warning),
                card.Right - sz.Width - 20 * S, y + 4 * S);

            float ry = y + 30 * S;
            float rowH = 25 * S;
            Theme.HLine(g, card.X + 16, card.Right - 16, (int)(ry - 3 * S), Theme.Divider);

            for (int i = 0; i < svcs.Count; i++)
            {
                SvcInfo s = svcs[i];
                Color dot = s.IsDisabled ? Theme.Success : Theme.Warning;
                Theme.Dot(g, x + 4 * S, ry + 9 * S, 3.6f * S, dot);
                g.DrawString(s.Name, fSub, new SolidBrush(Theme.Text), x + 15 * S, ry + 1 * S);
                string right = s.StartText + (s.Running ? " · 运行中" : " · 已停止");
                SizeF rs = g.MeasureString(right, fSub);
                g.DrawString(right, fSub, new SolidBrush(s.IsDisabled ? Theme.TextSecond : Theme.Warning),
                    card.Right - rs.Width - 20 * S, ry + 1 * S);
                ry += rowH;
                if (i < svcs.Count - 1)
                    Theme.HLine(g, card.X + 16, card.Right - 16, (int)(ry - 4 * S), Theme.Divider);
            }
        }

        private void DrawProgress(Graphics g)
        {
            Rectangle card = new Rectangle(pad, logY, ClientSize.Width - pad * 2, logH);
            Theme.Card(g, card, 8f, true);

            float x = card.X + 20 * S;
            float y = card.Y + 16 * S;

            // 标题 + 右侧状态
            g.DrawString("执行状态", fBody, new SolidBrush(Theme.Text), x, y);
            string state;
            Color stateColor;
            if (busy) { state = "执行中"; stateColor = Theme.Accent; }
            else if (hasError) { state = "有问题"; stateColor = Theme.Danger; }
            else if (progressValue >= 100) { state = "完成"; stateColor = Theme.Success; }
            else { state = "就绪"; stateColor = Theme.TextThird; }
            SizeF ss = g.MeasureString(state, fSmall);
            g.DrawString(state, fSmall, new SolidBrush(stateColor),
                card.Right - ss.Width - 20 * S, y + 3 * S);

            // 阶段说明
            g.DrawString(progressStage, fSub, new SolidBrush(Theme.TextSecond), x, y + 26 * S);

            // 进度条
            int by = (int)(y + 52 * S);
            int bh = (int)(10 * S);
            Rectangle track = new Rectangle((int)x, by, card.Width - (int)(46 * S), bh);
            using (GraphicsPath p = Theme.Rounded(track, bh / 2f))
            using (SolidBrush b = new SolidBrush(Color.FromArgb(236, 236, 236)))
                g.FillPath(b, p);

            double shown = progressShown;
            if (shown > 100) shown = 100;
            if (shown < 0) shown = 0;
            if (shown > 0.5)
            {
                int fw = (int)(track.Width * shown / 100.0);
                if (fw < bh) fw = bh;
                Rectangle fill = new Rectangle(track.X, track.Y, fw, bh);
                Color cTop = hasError ? Color.FromArgb(255, 226, 104, 96) : Theme.AccentHover;
                Color cBot = hasError ? Theme.Danger : Theme.Accent;
                using (GraphicsPath p = Theme.Rounded(fill, bh / 2f))
                {
                    using (LinearGradientBrush lg = new LinearGradientBrush(
                        new Rectangle(fill.X, fill.Y, Math.Max(1, fill.Width), bh),
                        cTop, cBot, 0f))
                        g.FillPath(lg, p);
                    Rectangle hi = new Rectangle(fill.X, fill.Y, Math.Max(1, fill.Width), Math.Max(1, bh / 2));
                    using (GraphicsPath hp = Theme.Rounded(hi, bh / 4f))
                    using (SolidBrush hb = new SolidBrush(Color.FromArgb(60, 255, 255, 255)))
                        g.FillPath(hb, hp);
                }
            }
            g.DrawString(((int)(shown + 0.5)) + "%", fSmall, new SolidBrush(Theme.TextSecond),
                track.Right + 10 * S, by - 3 * S);

            // 分隔线
            int dy = by + bh + (int)(14 * S);
            Theme.HLine(g, card.X + 16, card.Right - 16, dy, Theme.Divider);

            int areaTop = dy + (int)(10 * S);
            int areaBottom = card.Bottom - (int)(34 * S);

            if (logVisible && areaBottom - areaTop > (int)(18 * S))
            {
                float lineH = 15.5f * S;
                int maxLines = (int)((areaBottom - areaTop) / lineH);
                if (maxLines < 1) maxLines = 1;
                int start = logs.Count - maxLines;
                if (start < 0) start = 0;
                float ly = areaTop;
                for (int i = start; i < logs.Count; i++)
                {
                    string[] item = logs[i];
                    int lv = int.Parse(item[1]);
                    Color c = Theme.TextSecond;
                    if (lv == 1) c = Theme.Success;
                    else if (lv == 2) c = Theme.Warning;
                    else if (lv == 3) c = Theme.Danger;
                    string mark = "· ";
                    if (lv == 1) mark = "✓ ";
                    else if (lv == 2) mark = "! ";
                    else if (lv == 3) mark = "✕ ";
                    g.DrawString(mark + item[0], fMono, new SolidBrush(c), x, ly);
                    ly += lineH;
                }
            }
            else
            {
                string hint;
                if (progressResult != "") hint = progressResult;
                else if (progressValue == 0 && !busy) hint = "点上方按钮开始, 详细过程默认折叠";
                else hint = "";
                if (hint != "")
                {
                    g.DrawString(hint, fSub,
                        new SolidBrush(hasError ? Theme.Danger : Theme.TextSecond), x, areaTop + 2 * S);
                }
            }

            // 详情开关
            string link = logVisible ? "收起详情" : "查看详情";
            SizeF ls = g.MeasureString(link, fSmall);
            linkRect = new Rectangle(card.Right - (int)ls.Width - (int)(26 * S),
                                     card.Bottom - (int)(30 * S),
                                     (int)ls.Width + (int)(14 * S), (int)(20 * S));
            g.DrawString(link, fSmall,
                new SolidBrush(hoverLink ? Theme.AccentHover : Theme.Accent),
                linkRect.X + 6 * S, linkRect.Y + 1 * S);
        }

        // ------------------------------------------------------------ 交互
        private void OnFormMouseDown(object sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            if (e.Y < titleH)
            {
                if (capClose.Contains(e.X, e.Y)) { Close(); return; }
                if (capMin.Contains(e.X, e.Y)) { WindowState = FormWindowState.Minimized; return; }
                Native.DragWindow(Handle);
                return;
            }
            if (linkRect.Contains(e.X, e.Y))
            {
                logVisible = !logVisible;
                Invalidate();
            }
        }

        private void OnFormMouseMove(object sender, MouseEventArgs e)
        {
            bool c = capClose.Contains(e.X, e.Y);
            bool m = capMin.Contains(e.X, e.Y);
            bool l = linkRect.Contains(e.X, e.Y) && linkRect.Width > 0;
            if (c != hoverClose || m != hoverMin || l != hoverLink)
            {
                hoverClose = c; hoverMin = m; hoverLink = l;
                Cursor = l ? Cursors.Hand : Cursors.Default;
                Invalidate();
            }
        }

        /// <summary>进度回调(可能来自后台线程)。</summary>
        public void ReportProgress(int percent, string stage)
        {
            if (InvokeRequired)
            {
                try { BeginInvoke(new ProgressHandler(ReportProgress), new object[] { percent, stage }); }
                catch { }
                return;
            }
            if (percent > progressValue) progressValue = percent;
            if (stage != null && stage.Length > 0) progressStage = stage;
        }

        private void OnAction(string action)
        {
            if (busy) return;
            if (!admin) { Elevate(action); return; }

            if (pendingConfirm != action)
            {
                pendingConfirm = action;
                confirmTimer.Stop();
                confirmTimer.Start();
                if (action == "disable") btnDisable.Text = "再点一次确认";
                else btnRestore.Text = "再点一次确认";
                AddLog(action == "disable" ? "再次点击「禁用更新」以确认" : "再次点击「恢复更新」以确认", LogLevel.Warn);
                return;
            }

            confirmTimer.Stop();
            pendingConfirm = "";
            btnDisable.Text = "禁用更新";
            btnRestore.Text = "恢复更新";

            busy = true;
            hasError = false;
            progressValue = 0;
            progressShown = 0;
            progressStage = "正在启动…";
            progressResult = "";
            logVisible = false;
            btnDisable.Enabled2 = false;
            btnRestore.Enabled2 = false;
            btnRefresh.Enabled2 = false;
            btnDisable.Invalidate(); btnRestore.Invalidate(); btnRefresh.Invalidate();
            heroSub = action == "disable" ? "正在禁用 Windows 更新..." : "正在恢复 Windows 更新...";
            animTimer.Start();
            Invalidate();

            ThreadPool.QueueUserWorkItem(delegate
            {
                string result = "";
                bool failed = false;
                try
                {
                    if (action == "disable")
                    {
                        WuCore.DisableAll(AddLog, ReportProgress);
                        List<string> still = WuCore.GetNonDisabled();
                        if (still.Count > 0)
                        {
                            failed = true;
                            result = "有 " + still.Count + " 个服务没能保持禁用: " + string.Join(", ", still.ToArray());
                        }
                        else result = "5 个更新服务均已禁用, 更新策略已写入";
                    }
                    else
                    {
                        WuCore.RestoreAll(AddLog, ReportProgress);
                        result = "服务已按基线还原, 组策略已删除";
                    }
                }
                catch (Exception ex)
                {
                    failed = true;
                    result = "执行出错: " + ex.Message;
                    AddLog(result, LogLevel.Err);
                }
                try
                {
                    BeginInvoke(new MethodInvoker(delegate
                    {
                        busy = false;
                        hasError = failed;
                        progressValue = 100;
                        progressStage = failed ? "已完成 (有警告)" : "已完成";
                        progressResult = result;
                        if (failed) logVisible = true;
                        btnDisable.Enabled2 = true;
                        btnRestore.Enabled2 = true;
                        btnRefresh.Enabled2 = true;
                        RefreshStatus();
                    }));
                }
                catch { }
            });
        }

        private void Elevate(string action)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(Application.ExecutablePath, "--auto=" + action);
                psi.UseShellExecute = true;
                psi.Verb = "runas";
                Process.Start(psi);
                Close();
            }
            catch
            {
                AddLog("已取消管理员授权", LogLevel.Warn);
            }
        }

        public void RefreshStatus()
        {
            heroSub = "正在检测状态...";
            Invalidate();
            ThreadPool.QueueUserWorkItem(delegate
            {
                List<SvcInfo> s = WuCore.GetServices();
                bool p = WuCore.IsPolicyOn();
                try
                {
                    BeginInvoke(new MethodInvoker(delegate
                    {
                        svcs = s;
                        policyOn = p;
                        int dis = 0;
                        foreach (SvcInfo x in s) if (x.IsDisabled) dis++;
                        heroSub = "服务 " + dis + "/" + WuCore.SvcCore.Length + " 已禁用 · " +
                                  (p ? "自动更新策略已生效" : "自动更新策略未生效");
                        Invalidate();
                    }));
                }
                catch { }
            });
        }

        public void AddLog(string msg, LogLevel lv)
        {
            if (InvokeRequired)
            {
                try { BeginInvoke(new LogHandler(AddLog), new object[] { msg, lv }); }
                catch { }
                return;
            }
            logs.Add(new string[] { msg, ((int)lv).ToString() });
            if (logs.Count > 400) logs.RemoveRange(0, logs.Count - 400);
            Invalidate();
        }

        public void AutoRun(string action)
        {
            if (action != "disable" && action != "restore") return;
            System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();
            t.Interval = 500;
            t.Tick += delegate
            {
                t.Stop();
                t.Dispose();
                OnAction(action);   // 第一次进入确认态
                OnAction(action);   // 第二次真正执行
            };
            t.Start();
        }
    }
}
