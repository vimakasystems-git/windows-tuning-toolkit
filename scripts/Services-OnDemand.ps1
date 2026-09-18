#requires -Version 5.1
<#+
.SYNOPSIS
  Inicia servicos opcionais quando o programa relacionado e aberto e os encerra apos o uso.

.EXAMPLE
  .\Services-OnDemand.ps1 -Action Status
  .\Services-OnDemand.ps1 -Action Install -WhatIf
  .\Services-OnDemand.ps1 -Action Install
  .\Services-OnDemand.ps1 -Action Restore
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Status','Configure','Monitor','Install','Uninstall','Restore')]
    [string]$Action = 'Status',
    [ValidateRange(5,300)]
    [int]$PollSeconds = 5,
    [ValidateRange(30,3600)]
    [int]$IdleSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:TaskName = 'WindowsIT-Services-OnDemand'
$script:DataRoot = Join-Path $env:ProgramData 'WindowsITPerformance\OnDemand'
$script:BackupFile = Join-Path $script:DataRoot 'service-startup-backup.json'
$script:LogFile = Join-Path $script:DataRoot 'monitor.log'

# Edite esta lista para adicionar outros programas. ProcessNames nao levam ".exe".
# Somente servicos opcionais de terceiros entram aqui.
$script:Profiles = @(
    [pscustomobject]@{
        Name = 'Claude'
        ProcessNames = @('Claude')
        Services = @('CoworkVMService')
        StopAfterExit = $true
        ManageStartType = $false
    },
    [pscustomobject]@{
        Name = 'Dell SupportAssist'
        ProcessNames = @('SupportAssist','SupportAssistUI','SupportAssistInstaller')
        Services = @('DellClientManagementService','SupportAssistAgent','Dell SupportAssist Remediation','DellTechHub')
        StopAfterExit = $true
        ManageStartType = $true
    },
    [pscustomobject]@{
        Name = 'HP Print Scan Doctor'
        ProcessNames = @('HPPSdr','HPPrintScanDoctor','HPDiagnosticCoreUI')
        Services = @('HPPrintScanDoctorService')
        StopAfterExit = $true
        ManageStartType = $true
    },
    [pscustomobject]@{
        Name = 'VMware Workstation'
        ProcessNames = @('vmware','vmplayer')
        Services = @('VMAuthdService','VMnetDHCP','VMware NAT Service','VMUSBArbService')
        StopAfterExit = $true
        ManageStartType = $true
    },
    [pscustomobject]@{
        Name = 'VMware Horizon'
        ProcessNames = @('vmware-view','horizon-client','wswc')
        Services = @('client_service','ftnlsv3hv','ftscanmgrhv','vmwsprrdpwks')
        StopAfterExit = $true
        ManageStartType = $true
    },
    [pscustomobject]@{
        Name = 'Samsung Smart Switch/Kies'
        ProcessNames = @('SmartSwitchPC','SmartSwitchPDLR','Kies','Kies3')
        Services = @('ss_conn_service')
        StopAfterExit = $true
        ManageStartType = $true
    }
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-IsAdministrator) -and -not $WhatIfPreference) {
        throw 'Execute esta acao em um Windows PowerShell como Administrador.'
    }
}

function Initialize-DataRoot {
    if (-not (Test-Path -LiteralPath $script:DataRoot)) {
        New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
    }
}

function Write-MonitorLog([string]$Message) {
    Initialize-DataRoot
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Add-Content -LiteralPath $script:LogFile -Encoding UTF8
    # Evita crescimento ilimitado do log.
    if ((Get-Item -LiteralPath $script:LogFile).Length -gt 2MB) {
        Get-Content -LiteralPath $script:LogFile -Tail 2000 | Set-Content -LiteralPath "$script:LogFile.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$script:LogFile.tmp" -Destination $script:LogFile -Force
    }
}

function Get-InstalledProfiles {
    foreach ($profile in $script:Profiles) {
        $installed = @($profile.Services | Where-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue })
        if ($installed.Count -gt 0) {
            [pscustomobject]@{
                Name=$profile.Name
                ProcessNames=$profile.ProcessNames
                Services=$installed
                StopAfterExit=$profile.StopAfterExit
                ManageStartType=$profile.ManageStartType
            }
        }
    }
}

function Get-ServiceStartInfo([string]$Name) {
    $reg = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -ErrorAction Stop
    $delayedProperty = $reg.PSObject.Properties['DelayedAutoStart']
    $delayedValue = if ($null -ne $delayedProperty) { [int]$delayedProperty.Value } else { 0 }
    [pscustomobject]@{
        Name=$Name
        Start=[int]$reg.Start
        DelayedAutoStart=$delayedValue
    }
}

function Save-StartupBackup {
    Initialize-DataRoot
    if (Test-Path -LiteralPath $script:BackupFile) { return }
    $names = @(Get-InstalledProfiles | ForEach-Object Services | Sort-Object -Unique)
    @($names | ForEach-Object { Get-ServiceStartInfo $_ }) |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:BackupFile -Encoding UTF8
}

function Test-ProfileRunning([object]$Profile) {
    foreach ($name in $Profile.ProcessNames) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Start-ProfileServices([object]$Profile) {
    foreach ($name in $Profile.Services) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Running') {
            try {
                Start-Service -Name $name -ErrorAction Stop
                Write-MonitorLog "START profile='$($Profile.Name)' service='$name'"
            } catch {
                Write-MonitorLog "ERROR start profile='$($Profile.Name)' service='$name' message='$($_.Exception.Message)'"
            }
        }
    }
}

function Stop-ProfileServices([object]$Profile) {
    # Ordem inversa ajuda quando ha dependencias entre servicos do mesmo pacote.
    foreach ($name in @($Profile.Services)[-1..-($Profile.Services.Count)]) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') {
            try {
                Stop-Service -Name $name -Force -ErrorAction Stop
                Write-MonitorLog "STOP profile='$($Profile.Name)' service='$name'"
            } catch {
                Write-MonitorLog "ERROR stop profile='$($Profile.Name)' service='$name' message='$($_.Exception.Message)'"
            }
        }
    }
}

function Set-OnDemandConfiguration {
    Assert-Administrator
    Initialize-DataRoot
    Save-StartupBackup
    foreach ($profile in Get-InstalledProfiles) {
        foreach ($name in $profile.Services) {
            if (-not $profile.ManageStartType) { continue }
            if ($PSCmdlet.ShouldProcess("$name ($($profile.Name))", 'Definir inicializacao Manual')) {
                try {
                    Set-Service -Name $name -StartupType Manual -ErrorAction Stop
                } catch {
                    # Alguns servicos de aplicativos empacotados recusam Set-Service;
                    # tenta a API nativa do Service Control Manager e continua se protegidos.
                    $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
                    $scOutput = & $sc config $name 'start=' demand 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $message = ($scOutput | Out-String).Trim()
                        Write-Warning "Nao foi possivel colocar '$name' em Manual. Servico protegido ou permissao insuficiente. $message"
                    }
                }
            }
        }
        if (-not (Test-ProfileRunning $profile) -and $PSCmdlet.ShouldProcess($profile.Name, 'Parar servicos opcionais sem aplicativo aberto')) {
            Stop-ProfileServices $profile
        }
    }
}

function Start-Monitor {
    Assert-Administrator
    Initialize-DataRoot
    $profiles = @(Get-InstalledProfiles)
    $lastSeen = @{}
    foreach ($profile in $profiles) { $lastSeen[$profile.Name] = Get-Date }
    Write-MonitorLog "MONITOR START pid=$PID poll=$PollSeconds idle=$IdleSeconds"
    while ($true) {
        foreach ($profile in $profiles) {
            if (Test-ProfileRunning $profile) {
                $lastSeen[$profile.Name] = Get-Date
                Start-ProfileServices $profile
            } elseif ($profile.StopAfterExit -and ((Get-Date) - $lastSeen[$profile.Name]).TotalSeconds -ge $IdleSeconds) {
                Stop-ProfileServices $profile
                # Evita tentar parar repetidamente a cada ciclo.
                $lastSeen[$profile.Name] = (Get-Date).AddYears(10)
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Install-MonitorTask {
    Assert-Administrator
    Set-OnDemandConfiguration
    $powerShell = Join-Path $PSHOME 'powershell.exe'
    $arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action Monitor -PollSeconds $PollSeconds -IdleSeconds $IdleSeconds"
    if ($PSCmdlet.ShouldProcess($script:TaskName, 'Criar tarefa no logon para monitorar programas')) {
        $taskAction = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $script:TaskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $script:TaskName
        Write-Host "Instalado e iniciado: $script:TaskName" -ForegroundColor Green
    }
}

function Uninstall-MonitorTask {
    Assert-Administrator
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($script:TaskName, 'Parar e remover tarefa agendada')) {
            Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
        }
    }
}

function Restore-ServiceConfiguration {
    Assert-Administrator
    Uninstall-MonitorTask
    if (-not (Test-Path -LiteralPath $script:BackupFile)) { Write-Warning 'Backup nao encontrado.'; return }
    foreach ($item in @(Get-Content -LiteralPath $script:BackupFile -Raw | ConvertFrom-Json)) {
        if (-not (Get-Service -Name $item.Name -ErrorAction SilentlyContinue)) { continue }
        if ($PSCmdlet.ShouldProcess($item.Name, 'Restaurar tipo de inicializacao original')) {
            switch ([int]$item.Start) {
                2 { Set-Service -Name $item.Name -StartupType Automatic }
                3 { Set-Service -Name $item.Name -StartupType Manual }
                4 { Set-Service -Name $item.Name -StartupType Disabled }
            }
            if ([int]$item.Start -eq 2) {
                Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$($item.Name)" -Name DelayedAutoStart -Value ([int]$item.DelayedAutoStart) -Type DWord -ErrorAction SilentlyContinue
            }
        }
    }
    Write-Host 'Configuracao original restaurada.' -ForegroundColor Green
}

function Show-Status {
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Write-Host "Tarefa: $(if($task){$task.State}else{'Nao instalada'})"
    $rows = foreach ($profile in Get-InstalledProfiles) {
        foreach ($name in $profile.Services) {
            $svc = Get-Service -Name $name
            $reg = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
            $startType = switch ([int]$reg.Start) {
                2 { 'Automatic' }
                3 { 'Manual' }
                4 { 'Disabled' }
                default { [string]$reg.Start }
            }
            if (-not $profile.ManageStartType) { $startType = "$startType (Package)" }
            [pscustomobject]@{Software=$profile.Name;Service=$name;Status=$svc.Status;StartType=$startType;AppOpen=(Test-ProfileRunning $profile)}
        }
    }
    $rows | Format-Table -AutoSize
}

switch ($Action) {
    'Status'    { Show-Status }
    'Configure' { Set-OnDemandConfiguration }
    'Monitor'   { Start-Monitor }
    'Install'   { Install-MonitorTask }
    'Uninstall' { Uninstall-MonitorTask }
    'Restore'   { Restore-ServiceConfiguration }
}
