# Serviços sob demanda

O script `Services-OnDemand.ps1` coloca serviços opcionais em **Manual** e instala uma tarefa elevada no logon. O monitor observa os processos dos programas a cada cinco segundos, inicia os serviços associados e os encerra dois minutos depois que o aplicativo fecha.

Perfis incluídos: Claude, Dell SupportAssist, HP Print Scan Doctor, VMware Workstation, VMware Horizon e Samsung Smart Switch/Kies.

Serviços críticos do Windows, Defender, áudio, vídeo, armazenamento, TPM, Hyper-V, No-IP e Remojo não são alterados.

Execute no **Windows PowerShell como Administrador**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Services-OnDemand.ps1 -Action Status
.\Services-OnDemand.ps1 -Action Install -WhatIf
.\Services-OnDemand.ps1 -Action Install
```

Para verificar depois:

```powershell
.\Services-OnDemand.ps1 -Action Status
```

Para remover o monitor e restaurar os tipos de inicialização originais:

```powershell
.\Services-OnDemand.ps1 -Action Restore
```

O backup e o log ficam em `C:\ProgramData\WindowsITPerformance\OnDemand`.
