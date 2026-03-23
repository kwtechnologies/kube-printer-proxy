# printer-proxy installer for Windows
# Self-elevating, interactive, menu-driven

$ErrorActionPreference = "Stop"

$InstallDir   = "C:\printer-proxy"
$ServiceName  = "PrinterProxy"
$CfServiceName = "CloudflaredTunnel"
$NssmUrl      = "https://nssm.cc/release/nssm-2.24.zip"
$CfUrl        = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
$GhRepo       = "kwtechnologies/kube-printer-proxy"

# --------------- Self-elevate to admin ---------------
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
    if ($PSCommandPath) {
        $relaunchArgs = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    } else {
        # Running via iex (one-liner) — download script to temp, then re-launch
        $tempScript = "$env:TEMP\printer-proxy-install.ps1"
        $scriptUrl = "https://github.com/$GhRepo/releases/latest/download/install.ps1"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (New-Object System.Net.WebClient).DownloadFile($scriptUrl, $tempScript)
        $relaunchArgs = "-ExecutionPolicy Bypass -File `"$tempScript`""
    }
    Start-Process powershell -Verb RunAs -ArgumentList $relaunchArgs
    exit
}

# --------------- Helpers ---------------
function Write-Banner {
    Write-Host ""
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host "  Printer Proxy Installer" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host ""
}

function Get-LatestRelease {
    $release = Invoke-RestMethod "https://api.github.com/repos/$GhRepo/releases/latest"
    return $release
}

function Download-File($url, $dest) {
    Write-Host "  Downloading: $url" -ForegroundColor Gray
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($url, $dest)
}

function Stop-And-Remove-Service($name) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq "Running") {
            Write-Host "  Stopping service $name..." -ForegroundColor Yellow
            & "$InstallDir\nssm.exe" stop $name 2>$null
            Start-Sleep -Seconds 2
        }
        Write-Host "  Removing service $name..." -ForegroundColor Yellow
        & "$InstallDir\nssm.exe" remove $name confirm 2>$null
    }
}

# --------------- Install ---------------
function Do-Install {
    Write-Host ""
    Write-Host "--- Step 1/5: Gather configuration ---" -ForegroundColor Green

    $tunnelToken = Read-Host "Enter your Cloudflare Tunnel token"
    if ([string]::IsNullOrWhiteSpace($tunnelToken)) {
        Write-Host "Tunnel token is required. Aborting." -ForegroundColor Red
        return
    }

    $apiKey = Read-Host "Enter the API key for the print proxy"
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Host "API key is required. Aborting." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "--- Step 2/5: Create install directory ---" -ForegroundColor Green
    if (!(Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir | Out-Null }
    Write-Host "  Directory: $InstallDir"

    Write-Host ""
    Write-Host "--- Step 3/5: Download binaries ---" -ForegroundColor Green

    # printer-proxy.exe
    $release = Get-LatestRelease
    $exeAsset = $release.assets | Where-Object { $_.name -eq "printer-proxy.exe" }
    if (-not $exeAsset) {
        Write-Host "Could not find printer-proxy.exe in latest release. Aborting." -ForegroundColor Red
        return
    }
    Download-File $exeAsset.browser_download_url "$InstallDir\printer-proxy.exe"

    # nssm.exe
    $nssmZip = "$env:TEMP\nssm.zip"
    Download-File $NssmUrl $nssmZip
    Expand-Archive -Path $nssmZip -DestinationPath "$env:TEMP\nssm" -Force
    $nssmExe = Get-ChildItem "$env:TEMP\nssm" -Recurse -Filter "nssm.exe" | Where-Object { $_.DirectoryName -match "win64" } | Select-Object -First 1
    Copy-Item $nssmExe.FullName "$InstallDir\nssm.exe" -Force

    # cloudflared.exe
    Download-File $CfUrl "$InstallDir\cloudflared.exe"

    Write-Host ""
    Write-Host "--- Step 4/5: Create configuration ---" -ForegroundColor Green
    $envContent = "API_KEY=$apiKey`nPORT=9191"
    Set-Content -Path "$InstallDir\.env" -Value $envContent -Encoding UTF8
    Write-Host "  Created $InstallDir\.env"

    Write-Host ""
    Write-Host "--- Step 5/5: Install Windows Services ---" -ForegroundColor Green

    # Remove existing services if present
    Stop-And-Remove-Service $ServiceName
    Stop-And-Remove-Service $CfServiceName

    # Install printer-proxy service
    & "$InstallDir\nssm.exe" install $ServiceName "$InstallDir\printer-proxy.exe"
    & "$InstallDir\nssm.exe" set $ServiceName AppDirectory "$InstallDir"
    & "$InstallDir\nssm.exe" set $ServiceName AppEnvironmentExtra "+API_KEY=$apiKey" "+PORT=9191"
    & "$InstallDir\nssm.exe" set $ServiceName DisplayName "Printer Proxy"
    & "$InstallDir\nssm.exe" set $ServiceName Description "Local ZPL print relay for Kube"
    & "$InstallDir\nssm.exe" set $ServiceName Start SERVICE_AUTO_START
    & "$InstallDir\nssm.exe" set $ServiceName AppStdout "$InstallDir\proxy.log"
    & "$InstallDir\nssm.exe" set $ServiceName AppStderr "$InstallDir\proxy.log"
    & "$InstallDir\nssm.exe" start $ServiceName

    # Install cloudflared service
    & "$InstallDir\nssm.exe" install $CfServiceName "$InstallDir\cloudflared.exe" "tunnel run --token $tunnelToken"
    & "$InstallDir\nssm.exe" set $CfServiceName DisplayName "Cloudflared Tunnel"
    & "$InstallDir\nssm.exe" set $CfServiceName Description "Cloudflare tunnel for Printer Proxy"
    & "$InstallDir\nssm.exe" set $CfServiceName Start SERVICE_AUTO_START
    & "$InstallDir\nssm.exe" set $CfServiceName AppStdout "$InstallDir\cloudflared.log"
    & "$InstallDir\nssm.exe" set $CfServiceName AppStderr "$InstallDir\cloudflared.log"
    & "$InstallDir\nssm.exe" start $CfServiceName

    # Health check
    Write-Host ""
    Write-Host "Waiting for services to start..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    try {
        $health = Invoke-RestMethod "http://localhost:9191/health" -TimeoutSec 5
        Write-Host "Health check passed: $($health.status)" -ForegroundColor Green
    } catch {
        Write-Host "Health check failed - the service may still be starting. Check $InstallDir\proxy.log" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Installation complete!" -ForegroundColor Green
    Write-Host "  Install directory : $InstallDir" -ForegroundColor White
    Write-Host "  Proxy service     : $ServiceName" -ForegroundColor White
    Write-Host "  Tunnel service    : $CfServiceName" -ForegroundColor White
    Write-Host "  Logs              : $InstallDir\proxy.log / cloudflared.log" -ForegroundColor White
}

# --------------- Update ---------------
function Do-Update {
    Write-Host ""
    Write-Host "--- Updating printer-proxy.exe ---" -ForegroundColor Green

    if (!(Test-Path "$InstallDir\nssm.exe")) {
        Write-Host "Installation not found at $InstallDir. Please install first." -ForegroundColor Red
        return
    }

    $release = Get-LatestRelease
    $exeAsset = $release.assets | Where-Object { $_.name -eq "printer-proxy.exe" }
    if (-not $exeAsset) {
        Write-Host "Could not find printer-proxy.exe in latest release. Aborting." -ForegroundColor Red
        return
    }

    & "$InstallDir\nssm.exe" stop $ServiceName 2>$null
    Start-Sleep -Seconds 2
    Download-File $exeAsset.browser_download_url "$InstallDir\printer-proxy.exe"
    & "$InstallDir\nssm.exe" start $ServiceName

    Write-Host ""
    Write-Host "Update complete! Service restarted." -ForegroundColor Green
}

# --------------- Uninstall ---------------
function Do-Uninstall {
    Write-Host ""
    $confirm = Read-Host "This will remove all services and files. Type YES to confirm"
    if ($confirm -ne "YES") {
        Write-Host "Aborted." -ForegroundColor Yellow
        return
    }

    Stop-And-Remove-Service $ServiceName
    Stop-And-Remove-Service $CfServiceName

    if (Test-Path $InstallDir) {
        Remove-Item -Recurse -Force $InstallDir
        Write-Host "Removed $InstallDir" -ForegroundColor Green
    }

    Write-Host "Uninstall complete." -ForegroundColor Green
}

# --------------- Main menu ---------------
Write-Banner

Write-Host "  1) Install (fresh)"
Write-Host "  2) Update (download latest binary)"
Write-Host "  3) Uninstall (remove everything)"
Write-Host ""
$choice = Read-Host "Choose an option (1/2/3)"

switch ($choice) {
    "1" { Do-Install }
    "2" { Do-Update }
    "3" { Do-Uninstall }
    default { Write-Host "Invalid choice." -ForegroundColor Red }
}

Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
