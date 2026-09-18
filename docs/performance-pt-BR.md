# Windows IT Performance

Kit conservador para auditar e melhorar uma estacao Windows usada em projetos de TI.

## O que foi identificado nesta maquina

- Manter na inicializacao: Windows Security, Waves/MaxxAudio, DisplayLink, VMware e Ollama.
- Desativar automaticamente: Java Update Scheduler, Virtual CloneDrive e HP LJ Network PC Fax.
- Revisar manualmente: Spybot tray e qualquer item nao reconhecido.
- Na captura atual, os maiores consumidores de memoria foram Edge, ChatGPT, Grammarly, Windows Defender e Dell TechHub. Isso nao significa que devam ser removidos; feche os que nao estiver usando.

## Como usar

Abra **Windows PowerShell como Administrador**, navegue ate a pasta do script e execute primeiro:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Windows-IT-Performance.ps1 -Action Audit
.\Windows-IT-Performance.ps1 -Action Tune -WhatIf
```

Confira a simulacao. Para aplicar:

```powershell
.\Windows-IT-Performance.ps1 -Action Tune
```

Depois, reinicie o Windows. Os relatorios e backups ficam em `C:\ProgramData\WindowsITPerformance`.

Para restaurar os itens removidos da inicializacao:

```powershell
.\Windows-IT-Performance.ps1 -Action RestoreStartup
```

## RAM

O Windows usa RAM livre como cache; esvazia-la rotineiramente costuma piorar a performance. A acao abaixo e opcional e so reduz o working set de aplicativos com mais de 500 MB:

```powershell
.\Windows-IT-Performance.ps1 -Action CleanMemory -WhatIf
.\Windows-IT-Performance.ps1 -Action CleanMemory
```

Ela nao encerra processos e exclui processos criticos, Defender e Explorer. Use apenas quando houver pressao de memoria; fechar/reabrir o aplicativo pesado geralmente produz resultado melhor.

## O que o tuning faz

- cria ponto de restauracao quando o Windows permite;
- faz backup e remove apenas os candidatos conhecidos da inicializacao;
- limpa temporarios com mais de 7 dias;
- mantem o plano de energia Equilibrado e permite 100% de CPU quando ligado na tomada;
- corrige CPU minima travada em 100% para uma faixa de 5-100%, com preferencia por desempenho na tomada;
- troca pagefiles fixos em C:, E: e X: por um pagefile gerenciado pelo Windows em C: (requer reinicializacao);
- restaura o TCP auto-tuning suportado e limpa o cache DNS;
- habilita TRIM e chama a otimizacao nativa adequada para SSD/HDD.

Para restaurar energia e paginacao aos valores anteriores:

```powershell
.\Windows-IT-Performance.ps1 -Action RestoreTuning
```

Mantenha o Windows em uma versao com suporte pelo Windows Update. A atualizacao de sistema operacional nao e automatizada por este script.

O script deliberadamente nao desativa Defender, Windows Update, servicos, telemetria, arquivo de paginacao, QoS, IPv6 nem muda DNS/MTU. Essas alteracoes genericas frequentemente reduzem seguranca, estabilidade ou desempenho.
