# COLABORAR_V2.ps1 — Loop Codex: Claude Cowork escribe en CODEX.md, Codex ejecuta.
param(
    [ValidateRange(1,5)][int]$Rondas = 1
)
$ErrorActionPreference = 'Stop'
$repo    = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$channel = Join-Path $repo 'CODEX.md'
$runtime = Join-Path $repo 'Scripts\GOLD_MASTER_SYSTEM\python\runtime\collaboration'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null

$codex = (Get-Command codex -ErrorAction Stop).Source
if (!(Test-Path -LiteralPath $channel)) { throw 'Falta CODEX.md' }

$lockPath = Join-Path $runtime 'bridge.lock'
$lock = [System.IO.File]::Open(
    $lockPath,
    [System.IO.FileMode]::OpenOrCreate,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
)

try {
    for ($round = 1; $round -le $Rondas; $round++) {
        $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
        $codexOut = Join-Path $runtime "codex-r${round}-${stamp}.txt"
        $promptFile = Join-Path $runtime "prompt_r${round}.txt"

        Write-Host "=== Ronda $round / $Rondas ($stamp) ===" -ForegroundColor Cyan

        # Prompt escrito en archivo para evitar problemas de escape en shell
        $prompt = "Lee CODEX.md desde la seccion 'Sistema Adaptativo de Oro'. "
        $prompt += "Tarea: 1) Verificar sintaxis de python/gm_hypothesis.py y python/gm_rules_db.py "
        $prompt += "con el interprete Python correcto (busca conda, venv o py.exe valido). "
        $prompt += "2) Corregir errores si los hay. "
        $prompt += "3) Crear GOLD_ADAPTIVE_EA.mq5 en Experts/GOLD_MASTER_SYSTEM/ — esqueleto que "
        $prompt += "lee python/runtime/rules_db.json via FileReadString y loguea las reglas activas. "
        $prompt += "4) Diagnosticar por que C:\Python314\python.exe no es app Win32 valida. "
        $prompt += "5) Registrar en CODEX.md bajo 'Codex — Sistema Adaptativo ronda $round': "
        $prompt += "archivos creados/modificados, errores encontrados con evidencia, proximo paso. "
        $prompt += "Restricciones: sin ejecucion real, sin reemplazar .ex5 operativos, "
        $prompt += "sin activar trading, sin declarar rentabilidad."
        $prompt | Set-Content -LiteralPath $promptFile -Encoding utf8

        $promptText = Get-Content -LiteralPath $promptFile -Raw

        & $codex exec `
            -C $repo `
            --skip-git-repo-check `
            -s workspace-write `
            --approve-for-me `
            -o $codexOut `
            $promptText

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Codex exit $LASTEXITCODE en ronda $round — ver $codexOut"
        } else {
            Write-Host "Ronda $round OK — $codexOut" -ForegroundColor Green
        }

        if ($round -lt $Rondas) { Start-Sleep -Seconds 5 }
    }
} finally {
    $lock.Dispose()
    Remove-Item -LiteralPath $lockPath -ErrorAction SilentlyContinue
}

Write-Host "`nLoop completado ($Rondas rondas). Revisa CODEX.md." -ForegroundColor Yellow
