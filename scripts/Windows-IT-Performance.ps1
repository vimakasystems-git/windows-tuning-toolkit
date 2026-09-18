#requires -Version 5.1
<#+
.SYNOPSIS
  Auditoria e otimizacao conservadora do Windows para estacao de projetos de TI.

.EXAMPLE
  .\Windows-IT-Performance.ps1 -Action Audit
  .\Windows-IT-Performance.ps1 -Action Tune -WhatIf
  .\Windows-IT-Performance.ps1 -Action Tune
  .\Windows-IT-Performance.ps1 -Action CleanMemory -WhatIf
  .\Windows-IT-Performance.ps1 -Action RestoreStartup
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Audit','Tune','CleanMemory','RestoreStartup','RestoreTuning')]
    [string]$Action = 'Audit',
    [int]$TempFileAgeDays = 7,
    [int]$MemoryTrimThresholdMB = 500,
    [switch]$DisableUnknownStartup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Auditorias comuns gravam no perfil do usuario; execucoes elevadas usam ProgramData.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$script:IsAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:ToolRoot = if ($script:IsAdministrator) {
    Join-Path $env:ProgramData 'WindowsITPerformance'
} else {
    Join-Path $PSScriptRoot 'WindowsITPerformance-Data'
}
$script:ReportRoot = Join-Path $script:ToolRoot 'Reports'
$script:BackupFile = Join-Path $script:ToolRoot 'startup-backup.json'
$script:PerformanceBackupFile = Join-Path $script:ToolRoot 'performance-backup.json'
$script:DisabledStartup = Join-Path $script:ToolRoot 'DisabledStartup'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-Folders {
    foreach ($path in @($script:ToolRoot, $script:ReportRoot, $script:DisabledStartup)) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
}

function Get-StartupInventory {
    $items = [Collections.Generic.List[object]]::new()
    $registryPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($path in $registryPaths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $properties = (Get-ItemProperty -LiteralPath $path).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' }
        foreach ($property in $properties) {
            $items.Add([pscustomobject]@{ Type='Registry'; Name=$property.Name; Command=[string]$property.Value; Location=$path })
        }
    }
    $folders = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        Get-ChildItem -LiteralPath $folder -Force | Where-Object Name -ne 'desktop.ini' | ForEach-Object {
            $items.Add([pscustomobject]@{ Type='Shortcut'; Name=$_.Name; Command=$_.FullName; Location=$folder })
        }
    }
    return $items
}

function Get-StartupDecision([object]$Item) {
    $text = ($Item.Name + ' ' + $Item.Command).ToLowerInvariant()
    # Manter: seguranca, drivers/perifericos e ferramentas usadas nos projetos de TI.
    $keep = @('securityhealth','windows defender','wavessvc','maxxaudio','displaylink','vmware','ollama','docker','wsl','wireguard','tailscale','openvpn','onedrive','grammarly')
    $disable = @('sunjavaupdatesched','jusched','virtualclonedrive','vcddaemon','hp lj network pc fax')
    if ($disable | Where-Object { $text.Contains($_) }) { return 'Disable' }
    if ($keep | Where-Object { $text.Contains($_) }) { return 'Keep' }
    if ($DisableUnknownStartup) { return 'Disable' }
    if ($text -match 'antivirus|endpoint|vpn|credential|audio|display|graphics|touchpad') { return 'Review-Sensitive' }
    return 'Review'
}

function Write-AuditReport {
    Initialize-Folders
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportFile = Join-Path $script:ReportRoot "audit-$timestamp.txt"
    $startup = @(Get-StartupInventory | ForEach-Object {
        [pscustomobject]@{ Decision=(Get-StartupDecision $_); Name=$_.Name; Type=$_.Type; Command=$_.Command; Location=$_.Location }
    })
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $physicalDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    $volumes = Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
    $top = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 ProcessName,Id,@{n='RAM_MB';e={[math]::Round($_.WorkingSet64/1MB)}}
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("WINDOWS IT PERFORMANCE - AUDITORIA - $(Get-Date)")
    $lines.Add('')
    if ($os) {
        $lines.Add("Windows: $($os.Caption), build $($os.BuildNumber)")
        $lines.Add("RAM total/livre: $([math]::Round($os.TotalVisibleMemorySize/1MB,1)) GB / $([math]::Round($os.FreePhysicalMemory/1MB,1)) GB")
        $lines.Add("Ultimo boot: $($os.LastBootUpTime)")
    }
    if ($cpu) { $lines.Add("CPU: $($cpu.Name); nucleos/logicos: $($cpu.NumberOfCores)/$($cpu.NumberOfLogicalProcessors)") }
    $lines.Add('')
    $lines.Add('INICIALIZACAO (Disable = candidato automatico; Review = decidir manualmente):')
    $lines.Add(($startup | Sort-Object Decision,Name | Format-Table -AutoSize | Out-String -Width 260))
    $lines.Add('DISCOS:')
    $lines.Add(($physicalDisks | Select-Object FriendlyName,MediaType,HealthStatus,@{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}} | Format-Table -AutoSize | Out-String))
    $lines.Add(($volumes | Select-Object DriveLetter,FileSystem,HealthStatus,@{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},@{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}} | Format-Table -AutoSize | Out-String))
    $lines.Add('REDE ATIVA:')
    $lines.Add(($adapters | Select-Object Name,InterfaceDescription,LinkSpeed | Format-Table -AutoSize | Out-String))
    $lines.Add('MAIORES CONSUMIDORES DE RAM:')
    $lines.Add(($top | Format-Table -AutoSize | Out-String))
    $lines | Set-Content -LiteralPath $reportFile -Encoding UTF8
    Write-Host "Relatorio criado: $reportFile" -ForegroundColor Green
    $startup | Sort-Object Decision,Name | Format-Table Decision,Name,Type,Command -AutoSize
}

function Disable-ApprovedStartupItems {
    $targets = @(Get-StartupInventory | Where-Object { (Get-StartupDecision $_) -eq 'Disable' })
    if (-not $targets) { Write-Host 'Nenhum candidato automatico encontrado.'; return }
    $backup = @()
    if (Test-Path -LiteralPath $script:BackupFile) { $backup = @(Get-Content -LiteralPath $script:BackupFile -Raw | ConvertFrom-Json) }
    foreach ($item in $targets) {
        if (-not $PSCmdlet.ShouldProcess($item.Name, 'Remover da inicializacao com backup reversivel')) { continue }
        $backup += [pscustomobject]@{ Type=$item.Type; Name=$item.Name; Command=$item.Command; Location=$item.Location; DisabledAt=(Get-Date).ToString('o') }
        if ($item.Type -eq 'Registry') {
            Remove-ItemProperty -LiteralPath $item.Location -Name $item.Name -Force
        } else {
            $destination = Join-Path $script:DisabledStartup $item.Name
            Move-Item -LiteralPath $item.Command -Destination $destination -Force
        }
        Write-Host "Desativado: $($item.Name)" -ForegroundColor Yellow
    }
    if ($backup.Count -gt 0 -and -not $WhatIfPreference) { $backup | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:BackupFile -Encoding UTF8 }
}

function Restore-StartupItems {
    Initialize-Folders
    if (-not (Test-Path -LiteralPath $script:BackupFile)) { Write-Host 'Backup de inicializacao nao encontrado.'; return }
    $backup = @(Get-Content -LiteralPath $script:BackupFile -Raw | ConvertFrom-Json)
    foreach ($item in $backup) {
        if (-not $PSCmdlet.ShouldProcess($item.Name, 'Restaurar na inicializacao')) { continue }
        if ($item.Type -eq 'Registry') {
            if (-not (Test-Path -LiteralPath $item.Location)) { New-Item -Path $item.Location -Force | Out-Null }
            Set-ItemProperty -LiteralPath $item.Location -Name $item.Name -Value $item.Command -Type String
        } else {
            $disabled = Join-Path $script:DisabledStartup $item.Name
            if (Test-Path -LiteralPath $disabled) { Move-Item -LiteralPath $disabled -Destination (Join-Path $item.Location $item.Name) -Force }
        }
        Write-Host "Restaurado: $($item.Name)" -ForegroundColor Green
    }
}

function Remove-OldTempFiles {
    $cutoff = (Get-Date).AddDays(-[math]::Abs($TempFileAgeDays))
    $roots = @($env:TEMP, (Join-Path $env:WINDIR 'Temp')) | Select-Object -Unique
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue |
            Where-Object LastWriteTime -lt $cutoff | ForEach-Object {
                if ($PSCmdlet.ShouldProcess($_.FullName, "Excluir temporario sem uso ha $TempFileAgeDays dias")) {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
    }
}

function Get-PowerSettingValues([string]$PowerCfg, [string]$Alias) {
    $text = (& $PowerCfg /Q SCHEME_CURRENT SUB_PROCESSOR $Alias 2>&1 | Out-String)
    $hex = @([regex]::Matches($text, '0x[0-9a-fA-F]+') | ForEach-Object Value)
    if ($hex.Count -lt 2) { return $null }
    [pscustomobject]@{ AC=[Convert]::ToInt32($hex[-2],16); DC=[Convert]::ToInt32($hex[-1],16) }
}

function Save-PerformanceBackup([string]$PowerCfg) {
    if (Test-Path -LiteralPath $script:PerformanceBackupFile) { return }
    $memoryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $paging = @((Get-ItemProperty -LiteralPath $memoryPath -Name PagingFiles).PagingFiles)
    $backup = [pscustomobject]@{
        CreatedAt=(Get-Date).ToString('o')
        PagingFiles=$paging
        ProcessorMin=(Get-PowerSettingValues $PowerCfg 'PROCTHROTTLEMIN')
        ProcessorMax=(Get-PowerSettingValues $PowerCfg 'PROCTHROTTLEMAX')
        EnergyPreference=(Get-PowerSettingValues $PowerCfg 'PERFEPP')
    }
    $backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:PerformanceBackupFile -Encoding UTF8
}

function Restore-PerformanceSettings {
    if (-not (Test-IsAdministrator)) { throw 'Execute RestoreTuning em um PowerShell como Administrador.' }
    Initialize-Folders
    if (-not (Test-Path -LiteralPath $script:PerformanceBackupFile)) { Write-Warning 'Backup de tuning nao encontrado.'; return }
    $backup = Get-Content -LiteralPath $script:PerformanceBackupFile -Raw | ConvertFrom-Json
    $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if ($PSCmdlet.ShouldProcess('Energia e arquivo de paginacao', 'Restaurar configuracao anterior')) {
        if ($backup.ProcessorMin) {
            & $powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN ([int]$backup.ProcessorMin.AC) | Out-Null
            & $powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN ([int]$backup.ProcessorMin.DC) | Out-Null
        }
        if ($backup.ProcessorMax) {
            & $powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX ([int]$backup.ProcessorMax.AC) | Out-Null
            & $powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX ([int]$backup.ProcessorMax.DC) | Out-Null
        }
        if ($backup.EnergyPreference) {
            & $powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFEPP ([int]$backup.EnergyPreference.AC) | Out-Null
            & $powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFEPP ([int]$backup.EnergyPreference.DC) | Out-Null
        }
        & $powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
        $memoryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        Set-ItemProperty -LiteralPath $memoryPath -Name PagingFiles -Value @($backup.PagingFiles) -Type MultiString
    }
    Write-Host 'Tuning anterior restaurado. Reinicie o Windows para concluir a restauracao da paginacao.' -ForegroundColor Green
}

function Invoke-ConservativeTune {
    if (-not (Test-IsAdministrator) -and -not $WhatIfPreference) { throw 'Execute a acao Tune em um PowerShell como Administrador.' }
    Initialize-Folders
    Write-AuditReport
    if ($PSCmdlet.ShouldProcess('Sistema', 'Criar ponto de restauracao')) {
        Enable-ComputerRestore -Drive "$($env:SystemDrive)\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'Antes-Windows-IT-Performance' -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue
    }
    Disable-ApprovedStartupItems
    Remove-OldTempFiles
    $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $ipconfig = Join-Path $env:SystemRoot 'System32\ipconfig.exe'
    $defrag = Join-Path $env:SystemRoot 'System32\defrag.exe'
    $fsutil = Join-Path $env:SystemRoot 'System32\fsutil.exe'
    if (-not $WhatIfPreference) { Save-PerformanceBackup $powercfg }
    # Mantem frequencia baixa em repouso e permite turbo/desempenho total sob carga.
    if ($PSCmdlet.ShouldProcess('Plano de energia atual', 'CPU 5-100%; desempenho em tomada e equilibrio na bateria')) {
        & $powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 | Out-Null
        & $powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
        & $powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 | Out-Null
        & $powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
        & $powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFEPP 25 | Out-Null
        & $powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFEPP 50 | Out-Null
        & $powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
    }
    # Substitui tres pagefiles fixos por um gerenciado pelo Windows no disco C:, que tem espaco livre.
    if ($PSCmdlet.ShouldProcess('Arquivo de paginacao', 'Usar tamanho gerenciado pelo sistema em C:')) {
        $memoryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        Set-ItemProperty -LiteralPath $memoryPath -Name PagingFiles -Value @('C:\pagefile.sys 0 0') -Type MultiString
    }
    # Usa o autotuning suportado pelo Windows; nao altera MTU, QoS nem DNS.
    if ($PSCmdlet.ShouldProcess('Pilha TCP/IP', 'Definir auto-tuning normal e limpar cache DNS')) {
        & $netsh interface tcp set global autotuninglevel=normal | Out-Null
        & $ipconfig /flushdns | Out-Null
    }
    # Habilita TRIM e usa /O, que escolhe a operacao correta para SSD ou HDD.
    if ($PSCmdlet.ShouldProcess('Discos locais', 'Habilitar TRIM e executar otimizacao adequada ao tipo de disco')) {
        & $fsutil behavior set DisableDeleteNotify 0 | Out-Null
        & $defrag /C /O /U
    }
    Write-Host 'Tuning concluido. Reinicie o Windows e rode -Action Audit novamente.' -ForegroundColor Green
}

function Invoke-MemoryTrim {
    Write-Warning 'Isso reduz working sets, mas pode aumentar page faults. Use apenas para aliviar pressao momentanea; reiniciar apps costuma ser melhor.'
    if (-not ('NativeMemoryTools' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeMemoryTools {
  [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr hProcess);
}
'@
    }
    $excluded = @('Idle','System','Registry','Memory Compression','MsMpEng','csrss','wininit','services','lsass','svchost','dwm','explorer','powershell','pwsh')
    $targets = Get-Process | Where-Object { $_.WorkingSet64 -ge ($MemoryTrimThresholdMB * 1MB) -and $_.ProcessName -notin $excluded }
    foreach ($process in $targets) {
        if ($PSCmdlet.ShouldProcess("$($process.ProcessName) PID $($process.Id)", 'Solicitar reducao do working set')) {
            try { [void][NativeMemoryTools]::EmptyWorkingSet($process.Handle); Write-Host "RAM aparada: $($process.ProcessName)" }
            catch { Write-Warning "Nao foi possivel aparar $($process.ProcessName): $($_.Exception.Message)" }
        }
    }
}

switch ($Action) {
    'Audit'          { Write-AuditReport }
    'Tune'           { Invoke-ConservativeTune }
    'CleanMemory'    { Invoke-MemoryTrim }
    'RestoreStartup' { Restore-StartupItems }
    'RestoreTuning'  { Restore-PerformanceSettings }
}
