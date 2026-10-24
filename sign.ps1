# =====================================================================
#  Sign UpdateGuard.exe with a self-signed code signing certificate.
#
#  NOTE: a self-signed certificate does NOT remove SmartScreen warnings
#  on machines that don't trust it. It only removes "Unknown publisher"
#  for people who imported UpdateGuard.cer into their Trusted Root /
#  Trusted Publishers store (see dist\trust-cert.bat).
#
#  ASCII only - Windows PowerShell 5.1 reads BOM-less files as ANSI.
#
#  Usage:
#     powershell -NoProfile -ExecutionPolicy Bypass -File .\sign.ps1
# =====================================================================
param(
    [string]$Exe       = (Join-Path $PSScriptRoot 'dist\UpdateGuard.exe'),
    [string]$CerOut    = (Join-Path $PSScriptRoot 'dist\UpdateGuard.cer'),
    [string]$Subject   = 'CN=Update Guard, O=Update Guard Self-Signed',
    [string]$Timestamp = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Exe)) { throw "not found: $Exe" }

# a running instance locks the exe
try { Get-Process UpdateGuard -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
Start-Sleep -Milliseconds 600

# ---------------------------------------------------------------- cert
$cert = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Subject -and $_.HasPrivateKey } |
        Sort-Object NotAfter -Descending | Select-Object -First 1

if (-not $cert) {
    Write-Host 'Creating a self-signed code signing certificate...' -ForegroundColor Cyan
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $Subject `
        -CertStoreLocation Cert:\CurrentUser\My `
        -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA -KeyLength 3072 `
        -HashAlgorithm SHA256 `
        -NotAfter (Get-Date).AddYears(10)
}
Write-Host ('Subject    : ' + $cert.Subject)
Write-Host ('Thumbprint : ' + $cert.Thumbprint)
Write-Host ('Expires    : ' + $cert.NotAfter)

# ---------------------------------------------------------------- sign
# 注意: 时间戳服务失败时 Set-AuthenticodeSignature 不会抛异常, 而是返回
# Status=UnknownError 且不带时间戳。所以必须显式检查, 否则会静默签出一个
# "没有时间戳"的签名 —— 证书一过期, 签名就失效了。
Write-Host 'Signing...' -ForegroundColor Cyan
$sig = $null
foreach ($ts in @($Timestamp, 'http://timestamp.sectigo.com')) {
    if ([string]::IsNullOrEmpty($ts)) { continue }
    try {
        $sig = Set-AuthenticodeSignature -FilePath $Exe -Certificate $cert `
                 -HashAlgorithm SHA256 -TimestampServer $ts
        if ($sig -and $sig.TimeStamperCertificate) {
            Write-Host ('Timestamp  : ok via ' + $ts) -ForegroundColor Green
            break
        }
        Write-Host ('Timestamp  : failed via ' + $ts) -ForegroundColor Yellow
    } catch {
        Write-Host ('Timestamp  : unreachable (' + $ts + ')') -ForegroundColor Yellow
    }
}
if (-not $sig -or -not $sig.TimeStamperCertificate) {
    Write-Host 'Falling back to signing WITHOUT a timestamp.' -ForegroundColor Yellow
    $sig = Set-AuthenticodeSignature -FilePath $Exe -Certificate $cert -HashAlgorithm SHA256
}
Write-Host ('Result     : ' + $sig.Status)
if (-not $sig.TimeStamperCertificate) {
    Write-Host 'WARNING    : signature has no timestamp - it will expire with the certificate.' -ForegroundColor Yellow
}

# ------------------------------------------- export public cert (.cer)
Export-Certificate -Cert $cert -FilePath $CerOut -Type CERT | Out-Null
Write-Host ('Exported   : ' + $CerOut) -ForegroundColor Green

# ---------------------------------------------------------------- check
Write-Host ''
Write-Host '=== verification ===' -ForegroundColor Cyan
$check = Get-AuthenticodeSignature -FilePath $Exe
Write-Host ('Status     : ' + $check.Status)
Write-Host ('Message    : ' + $check.StatusMessage)
if ($check.SignerCertificate) {
    Write-Host ('Signer     : ' + $check.SignerCertificate.Subject)
    Write-Host ('NotAfter   : ' + $check.SignerCertificate.NotAfter)
}
Write-Host ''
Write-Host 'Reminder: recipients must run tools\trust-cert.bat once so that Windows'
Write-Host 'stops calling the publisher "unknown". UAC (consent.exe) reads only the'
Write-Host 'LOCAL MACHINE stores, so that step needs one admin confirmation.'
Write-Host 'SmartScreen ("Windows protected your PC") is a separate thing and a'
Write-Host 'self-signed certificate can never remove it.'
