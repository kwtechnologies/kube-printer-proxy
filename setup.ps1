$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = "kwtechnologies/kube-printer-proxy"
$bin = "printer-proxy-setup.exe"
$tmp = "$env:TEMP\$bin"
Write-Host "Downloading installer..."
(New-Object System.Net.WebClient).DownloadFile("https://github.com/$repo/releases/latest/download/$bin", $tmp)
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath $tmp -Verb RunAs -Wait
} else {
    & $tmp
}
