# =====================================================================
#  Trust the Update Guard self-signed certificate.
#
#  IMPORTANT
#  ---------
#  The UAC prompt is verified by consent.exe running as SYSTEM, which only
#  reads the LOCAL MACHINE certificate stores. Installing the .cer into the
#  current-user stores is NOT enough - UAC keeps saying "Unknown publisher".
#
#  certutil has no "-machine" switch: omitting -user means the machine store.
#
#  So the default here is machine-wide (all users, triggers UAC once).
#  Use -User if you only want Get-AuthenticodeSignature to report Valid
#  for the current user without admin rights.
#
#  Undo:
#     certutil -delstore Root "Update Guard"
#     certutil -delstore TrustedPublisher "Update Guard"
#     (add -user in front if you installed with -User)
# =====================================================================
param(
    [string]$Cer = (Join-Path $PSScriptRoot 'UpdateGuard.cer'),
    [switch]$User
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Cer)) {
    Write-Host ("Certificate not found: " + $Cer) -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}

if ($User) {
    $where = 'CurrentUser  (this user only)'
} else {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                 [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host 'Requesting administrator rights (UAC)...' -ForegroundColor Yellow
        $extra = @()
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (@(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',("`"$PSCommandPath`"")
        ) + $extra)
        exit
    }
    $where = 'LocalMachine (all users)'
}

Write-Host ''
Write-Host ('Installing the Update Guard certificate into ' + $where) -ForegroundColor Cyan
Write-Host 'Stores: Trusted Root Certification Authorities + Trusted Publishers' -ForegroundColor Cyan
Write-Host 'It is a SELF-SIGNED certificate (created by sign.ps1), not a public CA.' -ForegroundColor Yellow
Write-Host 'It removes the "Unknown publisher" text, but NOT SmartScreen warnings.' -ForegroundColor Yellow
Write-Host ''

foreach ($store in @('Root', 'TrustedPublisher')) {
    Write-Host ("  adding to " + $store + " ...")
    $certArgs = @()
    if ($User) { $certArgs += '-user' }
    $certArgs += @('-addstore', $store, ('"' + $Cer + '"'))
    $out = & certutil.exe $certArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("    FAILED: " + ($out -join ' ')) -ForegroundColor Red
    } else {
        Write-Host '    ok' -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '=== verification ===' -ForegroundColor Cyan
$scopeName = if ($User) { 'CurrentUser' } else { 'LocalMachine' }
foreach ($store in @('Root', 'TrustedPublisher')) {
    $hit = Get-ChildItem ("Cert:\" + $scopeName + "\" + $store) -ErrorAction SilentlyContinue |
           Where-Object { $_.Subject -like '*Update Guard*' }
    if ($hit) { Write-Host ("  [OK] " + $scopeName + '\' + $store) -ForegroundColor Green }
    else      { Write-Host ("  [--] " + $scopeName + '\' + $store) -ForegroundColor Red }
}

$exe = Join-Path $PSScriptRoot 'UpdateGuard.exe'
if (Test-Path -LiteralPath $exe) {
    $s = Get-AuthenticodeSignature -FilePath $exe
    Write-Host ('  signature status : ' + $s.Status)
    if ($s.SignerCertificate) { Write-Host ('  signer           : ' + $s.SignerCertificate.Subject) }
}

if (-not $User) {
    Write-Host ''
    Write-Host 'Done. The UAC prompt should now show "Update Guard" instead of' -ForegroundColor Green
    Write-Host '"Unknown publisher".' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Note: the blue "Windows protected your PC" SmartScreen window is' -ForegroundColor Yellow
    Write-Host 'separate - a self-signed certificate can never remove it.' -ForegroundColor Yellow
}
