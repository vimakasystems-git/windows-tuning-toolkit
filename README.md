# Windows Tuning Toolkit

PowerShell scripts for conservative, reversible Windows performance tuning and on-demand management of optional third-party services.

## Included scripts

- `Windows-IT-Performance.ps1`: audits startup entries, CPU, memory, storage and network; applies supported Windows tuning; creates backups for restoration.
- `Services-OnDemand.ps1`: sets selected optional services to Manual, starts them when their related application opens, and stops them after the application closes.

## Safety principles

- Run an audit and `-WhatIf` before applying changes.
- Microsoft Defender, Windows Update, networking, audio, graphics, storage, TPM and core Windows services are not disabled.
- Unknown startup entries remain review-only unless `-DisableUnknownStartup` is explicitly supplied.
- Original startup, power and pagefile settings are backed up before changes.
- The scripts avoid unsupported registry tweaks, disabling IPv6/QoS, fixed TCP windows and routine RAM purging.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1+
- Administrator privileges for changes

## Performance audit and tuning

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\Windows-IT-Performance.ps1 -Action Audit
.\scripts\Windows-IT-Performance.ps1 -Action Tune -WhatIf
.\scripts\Windows-IT-Performance.ps1 -Action Tune
```

Restart Windows after tuning because pagefile changes take effect after reboot.

Restore settings:

```powershell
.\scripts\Windows-IT-Performance.ps1 -Action RestoreStartup
.\scripts\Windows-IT-Performance.ps1 -Action RestoreTuning
```

## Services on demand

Review the `$Profiles` list inside the script before installation. Then run:

```powershell
.\scripts\Services-OnDemand.ps1 -Action Status
.\scripts\Services-OnDemand.ps1 -Action Install -WhatIf
.\scripts\Services-OnDemand.ps1 -Action Install
```

Remove the monitor and restore original service startup modes:

```powershell
.\scripts\Services-OnDemand.ps1 -Action Restore
```

## Disclaimer

Test on non-production systems first. Hardware, OEM utilities and corporate security policies vary. Use at your own risk.

## License

MIT
