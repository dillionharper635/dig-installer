# DIG classroom installer

Installs the approved DIG synthetic classroom reporting service and its fixed-package launcher on Windows x64. Reporting goes to the existing DIG backend. This is a pilot installer, not a production security certification.

Paste this command in Windows PowerShell:

```powershell
irm 'https://raw.githubusercontent.com/dillionharper635/dig-installer/main/Install.ps1' | iex
```

Approve the Windows administrator prompt if requested. Download, SHA-256 verification, installation, and service/backend-receipt validation then run automatically. Existing healthy installations are verified.

Requires Windows 10/11 or Windows Server 2019+ x64 with curl.exe and access to GitHub and the DIG backend. Windows protections remain enabled. Setup is currently an unsigned pilot executable.

The bootstrap preserves the initiating Windows account when a different administrator approves elevation. It accepts no arbitrary package, command, or target from a web page. Logs are kept in the displayed Program Files staging directory.

This bootstrap pins release `v2026.10.12` and its script/setup hashes. It does not implement unattended future updates. No API administrator token, SSH credential, Vault recovery key, or live database belongs in this repository.
