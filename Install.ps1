# Fixed DIG setup bootstrap. Downloads only the reviewed GitHub release.
$ErrorActionPreference = 'Stop'
$caller = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
    $shell = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
}
$task = {
    param([string]$account)
    $ErrorActionPreference = 'Stop'
    $url = 'https://github.com/dillionharper635/dig-installer/releases/download/v2026.10.12/Install-DIG.ps1'
    $hash = '46ab76ab56a5c281f4628b6a5112b4e1e21cef62c730546ab130f87dfd6bff79'
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $path = $programFiles
    while ($path) {
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Installation directory contains a reparse point.'
        }
        $parent = Split-Path -Path $path -Parent
        if ($parent -eq $path) { break }
        $path = $parent
    }
    $file = Join-Path $programFiles ('DIG-GitHub-' + [guid]::NewGuid() + '.ps1')
    Write-Host 'Downloading and verifying DIG setup from GitHub...'
    & (Join-Path $env:WINDIR 'System32\curl.exe') --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 --output $file $url
    if ($LASTEXITCODE -ne 0) { throw 'GitHub installer download failed.' }
    $locked = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $hash) {
            throw 'GitHub installer checksum mismatch.'
        }
        & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $file -AllowedAccount $account
        if ($LASTEXITCODE -ne 0) { throw 'DIG setup failed. Check the installation log directory shown above.' }
    } finally { $locked.Dispose() }
    Write-Host 'DIG installation verified.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if ([Environment]::Is64BitProcess -and $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    & $task $caller
} else {
    $literal = [string][char]39 + $caller.Replace([string][char]39, ([string][char]39 + [string][char]39)) + [string][char]39
    $invoke = '& {' + $task.ToString() + '} ' + $literal
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invoke))
    $options = @{FilePath=$shell; PassThru=$true; ArgumentList=('-NoProfile -EncodedCommand ' + $encoded)}
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Approve the Windows administrator prompt to install DIG.'
        $options.Verb = 'RunAs'
    }
    $child = Start-Process @options
    $handle = $child.Handle
    if (-not $child.WaitForExit(1800000)) { throw 'DIG setup is still running. Check its window before retrying.' }
    $child.Refresh()
    if ($child.ExitCode -ne 0) { throw 'Administrator approval was declined or DIG setup failed.' }
    Write-Host 'DIG installation verified.'
}
