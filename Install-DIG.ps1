#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$AllowedAccount = [Security.Principal.WindowsIdentity]::GetCurrent().Name)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$clock = [Diagnostics.Stopwatch]::StartNew()
$origin = 'https://github.com/dillionharper635/dig-installer/releases/download/v2026.10.12'
$setupUrl = $origin + '/MinimalAgent.exe'
$setupHash = '31d96d82145dcc5061ecaa511a5ff636addc984714933c8a209ea617db24fdc6'
$setupSize = 16037423
$cliHash = '3e5fd92771dcbc80fae7b4d568e87904031b6c78f6fb09b9d31862c11859c1a1'
$coreHash = '6932f50a2d670456ec0766362b9094e2af799c8e075b7bc5fbb7a03b2751cab6'
$staging = $null
$setupLock = $null
$result = [ordered]@{status='Failed'; machineId=$null; receiptId=$null; reportId=$null; changed=$null; elapsedMs=$null; error=$null}

function Assert-OrdinaryPath([string]$Path) {
    $itemPath = $Path
    while ($itemPath) {
        if (Test-Path -LiteralPath $itemPath) {
            if ((Get-Item -LiteralPath $itemPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw ('Installation path contains a reparse point: ' + $itemPath)
            }
        }
        $parent = Split-Path -Path $itemPath -Parent
        if ($parent -eq $itemPath) { break }
        $itemPath = $parent
    }
}

function Assert-Hash([string]$Path, [string]$Expected) {
    Assert-OrdinaryPath $Path
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
        throw ('File checksum mismatch: ' + [IO.Path]::GetFileName($Path))
    }
}

try {
    if (-not [Environment]::Is64BitProcess) { throw 'Open 64-bit PowerShell as Administrator.' }
    $account = $AllowedAccount
    if ($account.Contains('"') -or $account.Contains("`r") -or $account.Contains("`n")) { throw 'Invalid Windows account name.' }
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    Assert-OrdinaryPath $programFiles
    # Program Files inheritance prevents an ordinary account from replacing these files.
    $staging = Join-Path $programFiles ('DIG-PowerShell-' + [Guid]::NewGuid().ToString('D'))
    [void][IO.Directory]::CreateDirectory($staging)
    Assert-OrdinaryPath $staging
    $setup = Join-Path $staging 'MinimalAgent.exe'
    $curl = Join-Path $env:WINDIR 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl -PathType Leaf)) { throw 'Windows curl.exe is required (Windows 10/11 or Server 2019+).' }

    Write-Host 'Downloading DIG setup over HTTPS...'
    # Verify HTTPS for GitHub and its release-asset redirects.
    & $curl --fail --location --proto-redir '=https' --silent --show-error --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 `
        --output $setup $setupUrl
    if ($LASTEXITCODE -ne 0) { throw ('HTTPS download failed; curl exit code ' + $LASTEXITCODE) }
    if ((Get-Item -LiteralPath $setup).Length -ne $setupSize) { throw 'Setup download has the wrong size.' }
    # Preserve Internet provenance; do not unblock the file or alter Windows security settings.
    Set-Content -LiteralPath $setup -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=$setupUrl" -Encoding ASCII
    $setupLock = [IO.File]::Open($setup, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    Assert-Hash $setup $setupHash

    Write-Host 'Verified setup. Installing DIG and checking its backend report...'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $setup
    $start.WorkingDirectory = $staging
    $start.UseShellExecute = $false
    $start.Arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /INSTALLDIG /ALLOWEDACCOUNT="' + $account + '" /LOG="' + (Join-Path $staging 'setup.log') + '"'
    $process = [Diagnostics.Process]::Start($start)
    if (-not $process.WaitForExit(900000)) { throw 'Setup is still running after 15 minutes. Check setup.log before retrying.' }
    if ($process.ExitCode -ne 0) { throw ('Setup failed with exit code ' + $process.ExitCode + '. Check setup.log.') }
    $setupLock.Dispose()
    $setupLock = $null

    $launcher = Join-Path $programFiles 'DIG\Launcher'
    $cli = Join-Path $launcher 'DIG.Launcher.Cli.exe'
    Assert-Hash $cli $cliHash
    Assert-Hash (Join-Path $launcher 'DIG.Launcher.Core.dll') $coreHash
    $jobId = [Guid]::NewGuid().ToString('D')
    # This checks the actual desired state and same-machine receipt; healthy installs return NoChange.
    $stdout = Join-Path $staging 'validation.jsonl'
    $stderr = Join-Path $staging 'validation-error.log'
    $validation = Start-Process -FilePath $cli -ArgumentList @('--install',$jobId,'--wait') -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $handle = $validation.Handle
    if (-not $validation.WaitForExit(900000)) { throw 'Installation validation timed out. Review validation.jsonl.' }
    $validation.Refresh()
    if ($validation.ExitCode -ne 0) { throw ('Validation failed with exit code ' + $validation.ExitCode + '. Review validation.jsonl.') }
    $reply = (Get-Content -LiteralPath $stdout | Where-Object { $_.Trim() } | Select-Object -Last 1) | ConvertFrom-Json
    if (-not $reply.ok -or $reply.job.state -ne 'Succeeded' -or $reply.job.id -ne $jobId) { throw 'Installation did not return the requested successful validation job.' }
    foreach ($name in @('DIG_InstallLauncher','DIG_System')) {
        $service = Get-CimInstance Win32_Service -Filter ("Name='" + $name + "'")
        if ($service.State -ne 'Running' -or $service.StartMode -ne 'Auto' -or $service.StartName -ne 'LocalSystem') {
            throw ('Service is not Running / Automatic / LocalSystem: ' + $name)
        }
    }
    $machine = ([Guid](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid).ToString('D')
    $receiptPath = 'C:\ProgramData\DIGSystemService\last-send.json'
    Assert-OrdinaryPath $receiptPath
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.status -ne 'PASS' -or $receipt.receipt.status -ne 'SUCCESS' -or -not $receipt.receipt.id -or
        $receipt.machine_id -ne $machine -or $receipt.receipt.machine_id -ne $machine -or $reply.job.machineId -ne $machine -or
        $receipt.receipt.id -ne $reply.job.receiptId -or $receipt.report_id -ne $receipt.receipt.report_id) {
        throw 'Backend receipt is missing or belongs to another machine/report.'
    }
    $bootstrap = Get-Content -LiteralPath 'C:\ProgramData\DIG\Launcher\bootstrap-result.json' -Raw | ConvertFrom-Json
    $result.status = 'AutoSuccess'
    $result.machineId = $machine
    $result.receiptId = $receipt.receipt.id
    $result.reportId = $receipt.report_id
    $result.changed = $bootstrap.job.changed
    Write-Host ('Deployment Complete: AutoSuccess. Verified backend receipt ' + $result.receiptId)
} catch {
    $result.error = $_.Exception.Message
    Write-Host ('DIG installation failed: ' + $result.error) -ForegroundColor Red
} finally {
    if ($setupLock) { $setupLock.Dispose() }
    $result.elapsedMs = $clock.ElapsedMilliseconds
    $json = $result | ConvertTo-Json -Depth 6
    if ($staging) {
        try { [IO.File]::WriteAllText((Join-Path $staging 'powershell-result.json'), $json, [Text.UTF8Encoding]::new($false)) } catch { Write-Warning 'Could not save installation result.' }
        Write-Host ('Installation log directory: ' + $staging)
    }
    Write-Output $json
}
if ($result.status -eq 'AutoSuccess') { exit 0 }
exit 1
