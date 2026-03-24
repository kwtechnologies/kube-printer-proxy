# printer-proxy installer for Windows
# Self-elevating, interactive, menu-driven
# Supports automatic Cloudflare Tunnel creation via API

param(
    [string]$TunnelName = "",
    [string]$CfToken = "",
    [string]$ProxyApiKey = ""
)

$ErrorActionPreference = "Stop"

$InstallDir   = "C:\printer-proxy"
$ServiceName  = "PrinterProxy"
$CfServiceName = "CloudflaredTunnel"
$NssmUrl      = "https://github.com/dkxce/NSSM/releases/download/v2.25/NSSM_v2.25.zip"
$NssmUrlFallback = "https://nssm.cc/release/nssm-2.24.zip"
$CfUrl        = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
$GhRepo       = "kwtechnologies/kube-printer-proxy"
$CfDomain     = "kwtech.dev"
$CfApiBase    = "https://api.cloudflare.com/client/v4"

# --------------- Self-elevate to admin ---------------
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
    if ($PSCommandPath) {
        $relaunchArgs = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($TunnelName) { $relaunchArgs += " -TunnelName `"$TunnelName`"" }
        if ($CfToken)    { $relaunchArgs += " -CfToken `"$CfToken`"" }
        if ($ProxyApiKey) { $relaunchArgs += " -ProxyApiKey `"$ProxyApiKey`"" }
    } else {
        $tempScript = "$env:TEMP\printer-proxy-install.ps1"
        $scriptUrl = "https://github.com/$GhRepo/releases/latest/download/install.ps1"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (New-Object System.Net.WebClient).DownloadFile($scriptUrl, $tempScript)
        $relaunchArgs = "-ExecutionPolicy Bypass -File `"$tempScript`""
        if ($TunnelName) { $relaunchArgs += " -TunnelName `"$TunnelName`"" }
        if ($CfToken)    { $relaunchArgs += " -CfToken `"$CfToken`"" }
        if ($ProxyApiKey) { $relaunchArgs += " -ProxyApiKey `"$ProxyApiKey`"" }
    }
    Start-Process powershell -Verb RunAs -ArgumentList $relaunchArgs
    exit
}

# --------------- Helpers ---------------
function Write-Banner {
    Write-Host ""
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host "  Printer Proxy Installer (Windows)" -ForegroundColor Cyan
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

function Generate-ApiKey {
    $bytes = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

# --------------- Cloudflare API helpers ---------------
function Cf-Get($endpoint) {
    $headers = @{ "Authorization" = "Bearer $script:cfApiToken" }
    return Invoke-RestMethod -Uri "${CfApiBase}${endpoint}" -Headers $headers -Method Get
}

function Cf-Post($endpoint, $body) {
    $headers = @{
        "Authorization" = "Bearer $script:cfApiToken"
        "Content-Type"  = "application/json"
    }
    return Invoke-RestMethod -Uri "${CfApiBase}${endpoint}" -Headers $headers -Method Post -Body $body
}

function Cf-Put($endpoint, $body) {
    $headers = @{
        "Authorization" = "Bearer $script:cfApiToken"
        "Content-Type"  = "application/json"
    }
    return Invoke-RestMethod -Uri "${CfApiBase}${endpoint}" -Headers $headers -Method Put -Body $body
}

function Setup-Tunnel($tunnelName) {
    $subdomain = "print-proxy-$tunnelName"
    $hostname = "$subdomain.$CfDomain"

    Write-Host ""
    Write-Host "  Verifying Cloudflare API token and fetching account..." -ForegroundColor Green
    try {
        $accounts = Cf-Get "/accounts?per_page=1"
    } catch {
        Write-Host "  API token is invalid or lacks permissions: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
    if (-not $accounts.success) {
        Write-Host "  API token verification failed. Errors: $($accounts.errors | ConvertTo-Json -Compress)" -ForegroundColor Red
        return $null
    }
    $accountId = $null
    if ($accounts.result -and $accounts.result.Count -gt 0) {
        $accountId = $accounts.result[0].id
    }
    if (-not $accountId) {
        Write-Host "  Token cannot list accounts. Trying zone lookup to infer account..." -ForegroundColor Yellow
        try {
            $zonesResp = Cf-Get "/zones?name=${CfDomain}&per_page=1"
            if ($zonesResp.result -and $zonesResp.result.Count -gt 0) {
                $accountId = $zonesResp.result[0].account.id
            }
        } catch {}
        if (-not $accountId) {
            Write-Host "  Could not determine account ID. Ensure the token has account and zone permissions." -ForegroundColor Red
            return $null
        }
    }
    Write-Host "  Token verified. Account: $accountId" -ForegroundColor Green

    Write-Host ""
    Write-Host "  Fetching zone ID for ${CfDomain}..." -ForegroundColor Green
    $zones = Cf-Get "/zones?name=${CfDomain}&per_page=1"
    $zoneId = $zones.result[0].id
    if (-not $zoneId) {
        Write-Host "  Could not find zone ${CfDomain}. Aborting." -ForegroundColor Red
        return $null
    }
    Write-Host "  Zone: $zoneId"

    Write-Host ""
    Write-Host "  Checking for existing tunnel '$tunnelName'..." -ForegroundColor Green
    $existing = Cf-Get "/accounts/${accountId}/cfd_tunnel?name=${tunnelName}&is_deleted=false"
    $tunnelId = $null
    if ($existing.result -and $existing.result.Count -gt 0) {
        $tunnelId = $existing.result[0].id
        Write-Host "  Found existing tunnel: $tunnelId - reusing it." -ForegroundColor Yellow
    } else {
        Write-Host "  Creating new tunnel '$tunnelName'..." -ForegroundColor Green
        $secretBytes = New-Object byte[] 32
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($secretBytes)
        $tunnelSecret = [Convert]::ToBase64String($secretBytes)
        $createBody = @{
            name = $tunnelName
            config_src = "cloudflare"
            tunnel_secret = $tunnelSecret
        } | ConvertTo-Json
        $createResp = Cf-Post "/accounts/${accountId}/cfd_tunnel" $createBody
        $tunnelId = $createResp.result.id
        if (-not $tunnelId) {
            Write-Host "  Failed to create tunnel. Aborting." -ForegroundColor Red
            return $null
        }
        Write-Host "  Created tunnel: $tunnelId" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  Configuring ingress rules ($hostname -> http://localhost:9191)..." -ForegroundColor Green
    $configBody = @{
        config = @{
            ingress = @(
                @{ hostname = $hostname; service = "http://localhost:9191" },
                @{ service = "http_status:404" }
            )
        }
    } | ConvertTo-Json -Depth 4
    $configResp = Cf-Put "/accounts/${accountId}/cfd_tunnel/${tunnelId}/configurations" $configBody
    if (-not $configResp.success) {
        Write-Host "  Failed to configure ingress. Aborting." -ForegroundColor Red
        return $null
    }
    Write-Host "  Ingress configured." -ForegroundColor Green

    Write-Host ""
    Write-Host "  Creating DNS CNAME record ($hostname -> ${tunnelId}.cfargotunnel.com)..." -ForegroundColor Green
    $dnsCheck = Cf-Get "/zones/${zoneId}/dns_records?name=${hostname}&type=CNAME"
    if ($dnsCheck.result -and $dnsCheck.result.Count -gt 0) {
        $existingDnsId = $dnsCheck.result[0].id
        Write-Host "  DNS record already exists - updating it." -ForegroundColor Yellow
        $dnsBody = @{ type = "CNAME"; name = $hostname; content = "${tunnelId}.cfargotunnel.com"; proxied = $true } | ConvertTo-Json
        Cf-Put "/zones/${zoneId}/dns_records/${existingDnsId}" $dnsBody | Out-Null
    } else {
        $dnsBody = @{ type = "CNAME"; name = $hostname; content = "${tunnelId}.cfargotunnel.com"; proxied = $true } | ConvertTo-Json
        Cf-Post "/zones/${zoneId}/dns_records" $dnsBody | Out-Null
    }
    Write-Host "  DNS record set." -ForegroundColor Green

    Write-Host ""
    Write-Host "  Retrieving tunnel token..." -ForegroundColor Green
    $tokenResp = Cf-Get "/accounts/${accountId}/cfd_tunnel/${tunnelId}/token"
    $token = $tokenResp.result
    if (-not $token) {
        Write-Host "  Failed to get tunnel token. Aborting." -ForegroundColor Red
        return $null
    }
    Write-Host "  Tunnel setup complete!" -ForegroundColor Green

    return @{
        Token = $token
        ProxyUrl = "https://$hostname"
    }
}

# --------------- Install ---------------
function Do-Install {
    Write-Host ""
    Write-Host "--- Step 1/6: Tunnel setup ---" -ForegroundColor Green
    Write-Host ""

    $tunnelToken = ""
    $proxyUrl = ""
    $apiKey = ""

    if ($script:CfToken -and $script:TunnelName) {
        $setupMode = "auto"
    } else {
        Write-Host "  How would you like to configure the Cloudflare Tunnel?"
        Write-Host ""
        Write-Host "    a) I have a tunnel token already"
        Write-Host "    b) Create a new tunnel automatically (requires Cloudflare API token)"
        Write-Host ""
        $setupMode = Read-Host "  Choose (a/b)"
    }

    switch ($setupMode) {
        "a" {
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
        }
        { $_ -eq "b" -or $_ -eq "auto" } {
            $script:cfApiToken = $script:CfToken
            if ([string]::IsNullOrWhiteSpace($script:cfApiToken)) {
                $script:cfApiToken = Read-Host "Enter your Cloudflare API token"
                if ([string]::IsNullOrWhiteSpace($script:cfApiToken)) {
                    Write-Host "Cloudflare API token is required. Aborting." -ForegroundColor Red
                    return
                }
            }

            $tName = $script:TunnelName
            if ([string]::IsNullOrWhiteSpace($tName)) {
                $tName = Read-Host "Enter a tunnel name (e.g. alvin-office)"
                if ([string]::IsNullOrWhiteSpace($tName)) {
                    Write-Host "Tunnel name is required. Aborting." -ForegroundColor Red
                    return
                }
            }

            $result = Setup-Tunnel $tName
            if (-not $result) {
                Write-Host "Tunnel setup failed. Aborting." -ForegroundColor Red
                return
            }
            $tunnelToken = $result.Token
            $proxyUrl = $result.ProxyUrl

            $apiKey = $script:ProxyApiKey
            if ([string]::IsNullOrWhiteSpace($apiKey)) {
                $apiKey = Generate-ApiKey
                Write-Host "  Generated API key: $apiKey" -ForegroundColor Green
            }
        }
        default {
            Write-Host "Invalid choice. Aborting." -ForegroundColor Red
            return
        }
    }

    Write-Host ""
    Write-Host "--- Step 2/6: Create install directory ---" -ForegroundColor Green
    if (!(Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir | Out-Null }
    Write-Host "  Directory: $InstallDir"

    Write-Host ""
    Write-Host "--- Step 3/6: Download binaries ---" -ForegroundColor Green

    # printer-proxy.exe
    $release = Get-LatestRelease
    $exeAsset = $release.assets | Where-Object { $_.name -eq "printer-proxy.exe" }
    if (-not $exeAsset) {
        Write-Host "Could not find printer-proxy.exe in latest release. Aborting." -ForegroundColor Red
        return
    }
    Download-File $exeAsset.browser_download_url "$InstallDir\printer-proxy.exe"

    # nssm.exe (try GitHub mirror first, fallback to nssm.cc)
    $nssmZip = "$env:TEMP\nssm.zip"
    try {
        Download-File $NssmUrl $nssmZip
    } catch {
        Write-Host "  Primary mirror failed, trying fallback..." -ForegroundColor Yellow
        Download-File $NssmUrlFallback $nssmZip
    }
    Expand-Archive -Path $nssmZip -DestinationPath "$env:TEMP\nssm" -Force
    $nssmExe = Get-ChildItem "$env:TEMP\nssm" -Recurse -Filter "nssm.exe" | Where-Object { $_.DirectoryName -match "win64" } | Select-Object -First 1
    Copy-Item $nssmExe.FullName "$InstallDir\nssm.exe" -Force

    # cloudflared.exe
    Download-File $CfUrl "$InstallDir\cloudflared.exe"

    Write-Host ""
    Write-Host "--- Step 4/6: Create configuration ---" -ForegroundColor Green
    $envContent = "API_KEY=$apiKey`nPORT=9191"
    Set-Content -Path "$InstallDir\.env" -Value $envContent -Encoding UTF8
    Write-Host "  Created $InstallDir\.env"

    Write-Host ""
    Write-Host "--- Step 5/6: Install Windows Services ---" -ForegroundColor Green

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
    Write-Host "--- Step 6/6: Verify ---" -ForegroundColor Green
    Write-Host "Waiting for services to start..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    try {
        $health = Invoke-RestMethod "http://localhost:9191/health" -TimeoutSec 5
        Write-Host "Health check passed: $($health.status)" -ForegroundColor Green
    } catch {
        Write-Host "Health check failed - the service may still be starting. Check $InstallDir\proxy.log" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host "  Installation Complete!" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Install directory : $InstallDir" -ForegroundColor White
    Write-Host "  Proxy service     : $ServiceName" -ForegroundColor White
    Write-Host "  Tunnel service    : $CfServiceName" -ForegroundColor White
    Write-Host "  Logs              : $InstallDir\proxy.log / cloudflared.log" -ForegroundColor White

    if ($proxyUrl) {
        Write-Host ""
        Write-Host "====================================" -ForegroundColor Cyan
        Write-Host "  Enter these in Portal > Print Proxy" -ForegroundColor Cyan
        Write-Host "====================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Proxy URL : $proxyUrl" -ForegroundColor White
        Write-Host "  API Key   : $apiKey" -ForegroundColor White
        Write-Host ""

        # Save credentials to install dir (same as macOS)
        $credContent = "Printer Proxy Credentials`r`n" +
            "========================`r`n" +
            "Proxy URL : $proxyUrl`r`n" +
            "API Key   : $apiKey`r`n" +
            "`r`nEnter these values in Portal > Print Proxy settings."
        $credFile = "$InstallDir\credentials.txt"
        Set-Content -Path $credFile -Value $credContent -Encoding UTF8
        Write-Host "  Credentials saved to: $credFile" -ForegroundColor Yellow

        # Also save a copy to Desktop for easy access
        $desktopCred = [Environment]::GetFolderPath("Desktop") + "\printer-proxy-credentials.txt"
        Set-Content -Path $desktopCred -Value $credContent -Encoding UTF8
        Write-Host "  Credentials also saved to: $desktopCred" -ForegroundColor Yellow
    }
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
try {
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
} catch {
    Write-Host ""
    Write-Host "An error occurred: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
} finally {
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
