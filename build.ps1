# =====================================================================
#  Update Guard - build script
#  Compiles with the .NET Framework csc.exe shipped with Windows,
#  producing a single dependency-free exe.
#  NOTE: ASCII only. Windows PowerShell 5.1 reads BOM-less files as ANSI.
#        Always use [Type]::new(...) instead of New-Object Type(...) to
#        avoid PowerShell's ambiguous argument parsing.
# =====================================================================
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'dist'),
    [switch]$Sign
)

$ErrorActionPreference = 'Stop'
$root  = $PSScriptRoot
$src   = Join-Path $root 'src'
$build = Join-Path $root 'build'
$csc   = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe not found' }

Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- icon
function New-RoundedPath([System.Drawing.RectangleF]$r, [float]$radius) {
    $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = [float]($radius * 2)
    if ($d -gt $r.Width)  { $d = $r.Width }
    if ($d -gt $r.Height) { $d = $r.Height }
    $p.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-IconBitmap([int]$size) {
    $px = $size * 4
    $bmp = [System.Drawing.Bitmap]::new($px, $px, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $m = [float](0.045 * $px)
    $tile = [System.Drawing.RectangleF]::new($m, $m, [float]($px - 2 * $m), [float]($px - 2 * $m))
    $path = New-RoundedPath $tile ([float](0.235 * $px))
    $c1 = [System.Drawing.Color]::FromArgb(255, 124, 92, 255)
    $c2 = [System.Drawing.Color]::FromArgb(255, 43, 198, 240)
    $br = [System.Drawing.Drawing2D.LinearGradientBrush]::new($tile, $c1, $c2, [float]50.0)
    $g.FillPath($br, $path)

    $hl = [System.Drawing.RectangleF]::new($tile.X, $tile.Y, $tile.Width, [float]($tile.Height * 0.55))
    $br2 = [System.Drawing.Drawing2D.LinearGradientBrush]::new($hl,
        [System.Drawing.Color]::FromArgb(95, 255, 255, 255),
        [System.Drawing.Color]::FromArgb(0, 255, 255, 255), [float]90.0)
    $g.FillPath($br2, $path)

    $w = 0.50 * $px; $h = 0.58 * $px; $cx = 0.5 * $px; $top = 0.20 * $px
    [System.Drawing.PointF[]]$pts = @(
        [System.Drawing.PointF]::new([float]$cx, [float]$top),
        [System.Drawing.PointF]::new([float]($cx + $w / 2), [float]($top + $h * 0.16)),
        [System.Drawing.PointF]::new([float]($cx + $w / 2), [float]($top + $h * 0.58)),
        [System.Drawing.PointF]::new([float]$cx, [float]($top + $h)),
        [System.Drawing.PointF]::new([float]($cx - $w / 2), [float]($top + $h * 0.58)),
        [System.Drawing.PointF]::new([float]($cx - $w / 2), [float]($top + $h * 0.16))
    )
    $sp = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $sp.AddPolygon($pts)
    $wb = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(245, 255, 255, 255))
    $g.FillPath($wb, $sp)

    $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 84, 62, 214), [float](0.085 * $px))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    [System.Drawing.PointF[]]$chk = @(
        [System.Drawing.PointF]::new([float]($cx - 0.13 * $px), [float]($top + 0.42 * $h)),
        [System.Drawing.PointF]::new([float]($cx - 0.02 * $px), [float]($top + 0.56 * $h)),
        [System.Drawing.PointF]::new([float]($cx + 0.17 * $px), [float]($top + 0.27 * $h))
    )
    $g.DrawLines($pen, $chk)
    $g.Dispose()
    $br.Dispose(); $br2.Dispose(); $wb.Dispose(); $pen.Dispose(); $path.Dispose(); $sp.Dispose()

    $out = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g2 = [System.Drawing.Graphics]::FromImage($out)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g2.DrawImage($bmp, [System.Drawing.Rectangle]::new(0, 0, $size, $size))
    $g2.Dispose(); $bmp.Dispose()
    return $out
}

function Get-PngBytes($bmp) {
    $ms = [System.IO.MemoryStream]::new()
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $b = $ms.ToArray()
    $ms.Dispose()
    return $b
}

function New-AppIcon([string]$path) {
    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $pngs = @{}
    foreach ($s in $sizes) {
        $bmp = New-IconBitmap $s
        $pngs[$s] = Get-PngBytes $bmp
        $bmp.Dispose()
    }
    $ms = [System.IO.MemoryStream]::new()
    $bw = [System.IO.BinaryWriter]::new($ms)
    $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    foreach ($s in $sizes) {
        [byte[]]$bytes = $pngs[$s]
        if ($s -ge 256) { $dim = 0 } else { $dim = $s }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim)
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([UInt16]1); $bw.Write([UInt16]32)
        $bw.Write([UInt32]$bytes.Length); $bw.Write([UInt32]$offset)
        $offset += $bytes.Length
    }
    foreach ($s in $sizes) {
        [byte[]]$bytes = $pngs[$s]
        $bw.Write($bytes)
    }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

# ---------------------------------------------------------------- encoding
# Sources are UTF-8 (usually without BOM). csc.exe would otherwise assume the
# ANSI codepage and mangle the Chinese literals, so always pass /codepage:65001.
# (No file rewriting here - that would fight the editor's change tracking.)
Write-Host 'Source encoding: UTF-8 via /codepage:65001' -ForegroundColor Cyan

# ---------------------------------------------------------------- build
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$icon = Join-Path $build 'app.ico'
Write-Host 'Generating icon...' -ForegroundColor Cyan
New-AppIcon $icon
Write-Host ("  app.ico  {0} bytes" -f (Get-Item $icon).Length)

$exe = Join-Path $OutDir 'UpdateGuard.exe'
if (Test-Path $exe) { Remove-Item $exe -Force }
$refs = @(
    '/r:System.dll',
    '/r:System.Core.dll',
    '/r:System.Drawing.dll',
    '/r:System.Windows.Forms.dll'
)

$sources = Get-ChildItem (Join-Path $src '*.cs') | ForEach-Object { $_.FullName }

$cscArgs = @(
    '/nologo',
    '/target:winexe',
    '/platform:anycpu',
    '/optimize+',
    '/langversion:5',
    '/codepage:65001',
    "/win32icon:$icon",
    "/win32manifest:$(Join-Path $build 'app.manifest')",
    "/out:$exe"
) + $refs + $sources

Write-Host 'Compiling...' -ForegroundColor Cyan
$output = & $csc @cscArgs 2>&1
if ($output) { $output | ForEach-Object { Write-Host $_ } }

if (Test-Path $exe) {
    Write-Host ''
    Write-Host ("BUILD OK: {0}" -f $exe) -ForegroundColor Green
    Write-Host ("size: {0:N0} bytes ({1:N1} KB)" -f (Get-Item $exe).Length, ((Get-Item $exe).Length / 1KB))
    if ($Sign) {
        Write-Host ''
        & (Join-Path $root 'sign.ps1') -Exe $exe
    } else {
        Write-Host 'note: not signed - run ".\sign.ps1" or ".\build.ps1 -Sign" to sign it.'
    }
} else {
    Write-Host 'BUILD FAILED' -ForegroundColor Red
    exit 1
}
