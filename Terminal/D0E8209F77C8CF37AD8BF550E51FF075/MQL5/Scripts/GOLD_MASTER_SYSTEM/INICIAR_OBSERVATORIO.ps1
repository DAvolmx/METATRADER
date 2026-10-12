param([int]$Port=8766,[switch]$OpenBrowser)
$ErrorActionPreference='Stop'
$projectRoot=$PSScriptRoot
$runtimePython=if($env:GM_PYTHON){$env:GM_PYTHON}else{'D:/ENTRENADOR/ldz_trading_terminal/.venv/Scripts/python.exe'}
if(!(Test-Path -LiteralPath $runtimePython)){throw 'Define GM_PYTHON con un Python que tenga las dependencias del entrenador.'}
$terminalPath=if($env:GM_TERMINAL_PATH){$env:GM_TERMINAL_PATH}else{'C:/Program Files/MetaTrader 5/terminal64.exe'}
$env:GM_TERMINAL_PATH=$terminalPath
& $runtimePython (Join-Path $projectRoot 'python/gm_check_binding.py')
if($LASTEXITCODE -ne 0){throw 'La verificación de la carpeta de MT5 falló.'}
& $runtimePython (Join-Path $projectRoot 'python/gm_rules_bridge.py')
if($LASTEXITCODE -ne 0){throw 'No se pudo exportar el snapshot de reglas para MT5.'}
$pidFile=Join-Path $projectRoot 'python/runtime/observer.pid'
$snapshotFile=Join-Path $projectRoot 'python/runtime/market_snapshot.json'
$observer=$null
if(Test-Path $snapshotFile){
 try {
  $snap=Get-Content -LiteralPath $snapshotFile -Raw | ConvertFrom-Json
  $age=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-[double]$snap.ts
  if($age -ge -2 -and $age -le 10 -and $snap.service.pid){
   $observer=Get-Process -Id ([int]$snap.service.pid) -ErrorAction SilentlyContinue
   if($observer){[int]$snap.service.pid | Set-Content $pidFile}
  }
 } catch { $observer=$null }
}
if(!$observer){
 Start-Process -FilePath $runtimePython -ArgumentList @('"'+(Join-Path $projectRoot 'python/gm_market_service.py')+'"','--terminal','"'+$terminalPath+'"') -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $projectRoot 'python/runtime/observer.out.log') -RedirectStandardError (Join-Path $projectRoot 'python/runtime/observer.err.log') -PassThru | Select-Object -ExpandProperty Id | Set-Content $pidFile
}
$listener=$null
try { $listener=Invoke-RestMethod -Uri "http://127.0.0.1:$Port/openapi.json" -TimeoutSec 2 } catch {}
if($listener -and $listener.info.title -notmatch 'GOLD MASTER|LDZ Trading'){throw "El puerto $Port pertenece a otro servicio."}
if(!$listener){
 Start-Process -FilePath $runtimePython -ArgumentList @('-m','web','--port',"$Port",'--no-browser') -WorkingDirectory (Join-Path $projectRoot 'replay_terminal') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $projectRoot 'python/runtime/replay.out.log') -RedirectStandardError (Join-Path $projectRoot 'python/runtime/replay.err.log') -PassThru | Select-Object -ExpandProperty Id | Set-Content (Join-Path $projectRoot 'python/runtime/replay.pid')
}
if($OpenBrowser){
 for($attempt=0;$attempt -lt 20;$attempt++){
  try { $listener=Invoke-RestMethod -Uri "http://127.0.0.1:$Port/openapi.json" -TimeoutSec 2; break } catch { Start-Sleep -Seconds 1 }
 }
 if(!$listener){throw "El replay no respondió en el puerto $Port. Consulta python/runtime/replay.err.log."}
 Start-Process "http://127.0.0.1:$Port/"
}
Write-Output "Replay y observatorio local: http://127.0.0.1:$Port (ejecución real deshabilitada)"



