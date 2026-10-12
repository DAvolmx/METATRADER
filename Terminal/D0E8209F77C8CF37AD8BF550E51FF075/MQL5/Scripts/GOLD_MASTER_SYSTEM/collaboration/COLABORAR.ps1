param(
    [ValidateRange(1,3)][int]$Rondas=1,
    [ValidateRange(0.01,5.00)][decimal]$PresupuestoClaudeUSD=0.25
)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$channel=Join-Path $repo 'CODEX.md'
$runtime=Join-Path $repo 'Scripts/GOLD_MASTER_SYSTEM/python/runtime/collaboration'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$claude=(Get-Command claude -ErrorAction Stop).Source
$codex=(Get-Command codex -ErrorAction Stop).Source
if(!(Test-Path -LiteralPath $channel)){throw 'Falta CODEX.md'}
$lockPath=Join-Path $runtime 'bridge.lock'
$lock=[System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
try {
  for($round=1;$round -le $Rondas;$round++){
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $claudeOut=Join-Path $runtime "claude-$stamp.txt"
    $codexOut=Join-Path $runtime "codex-$stamp.txt"
    $promptClaude='Lee CODEX.md y audita las fuentes GOLD MASTER SYSTEM. Solo lectura, sin trading. Devuelve hallazgos NUEVOS con ruta, línea, evidencia e impacto. Distingue hechos de hipótesis. No repitas el informe histórico.'
    $claudeText=& $claude -p $promptClaude --allowedTools Read,Glob,Grep --max-budget-usd "$PresupuestoClaudeUSD" --output-format text 2>&1 | Out-String
    if($LASTEXITCODE -ne 0){
      $claudeText | Set-Content -LiteralPath $claudeOut -Encoding utf8
      throw "Claude CLI falló; diagnóstico en $claudeOut. La ronda no se envió a Codex."
    }
    $claudeText | Set-Content -LiteralPath $claudeOut -Encoding utf8
    @("", "## Claude CLI — ronda $round ($stamp)", "", "Archivo de respuesta: $claudeOut", "", $claudeText) | Add-Content -LiteralPath $channel -Encoding utf8
    $promptCodex='Lee CODEX.md empezando por la última ronda de Claude CLI. Contrasta los hallazgos con el código antes de editar. Trabaja solo en este proyecto, sin órdenes de trading ni activación real, y sin sustituir binarios operativos. Corrige problemas justificados, verifica lo necesario y añade una entrada nueva en CODEX.md con archivos, evidencia y pendientes. Conserva todas las entradas previas y evita sobrescribir archivos que otro agente esté editando.'
    & $codex exec -C $repo --skip-git-repo-check -s workspace-write --approve-for-me -o $codexOut $promptCodex
    if($LASTEXITCODE -ne 0){throw "Codex CLI falló en ronda $round; revisar $codexOut"}
    Write-Output "Ronda $round completada. Claude: $claudeOut; Codex: $codexOut"
  }
} finally {
  $lock.Dispose()
}
