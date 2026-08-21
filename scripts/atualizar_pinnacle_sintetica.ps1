[CmdletBinding()]
param(
  [switch]$PlanOnly,
  [switch]$SkipDownload,
  [switch]$NoPublish,
  [string]$OracleSourceUrl = 'https://drive.usercontent.google.com/download?id=1hnpbrUpBMS1TZI7IovfpKeZfWJH1Aptm&export=download&confirm=t'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$reportDir = Join-Path $projectRoot ('Relat' + [char]0x00F3 + 'rios de atualiza' + [char]0x00E7 + [char]0x00E3 + 'o')
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$reportPath = Join-Path $reportDir "atualizacao_$stamp.md"
$rscript = 'C:\Program Files\R\R-4.6.1\bin\Rscript.exe'
$oraclePath = Join-Path $projectRoot 'data\raw\oracles_elixir\2026_LoL_esports_match_data_from_OraclesElixir.csv'
$bundlePath = Join-Path $projectRoot 'app_data\synthetic_pinnacle_bundle.json'
$appHealthUrl = 'https://modelo-abates-lol-sry25k3zh76r7ffs2qo8m3.streamlit.app/_stcore/health'
$rawBundleUrl = 'https://raw.githubusercontent.com/SamuSSL/modelo-abates-lol/main/app_data/synthetic_pinnacle_bundle.json'

New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
Set-Content -LiteralPath $reportPath -Encoding utf8 -Value "# Atualização Pinnacle sintética`n`nInício: $(Get-Date -Format o)`n"

function Add-Report([string]$text) {
  Add-Content -LiteralPath $reportPath -Encoding utf8 -Value $text
}
function Invoke-Stage([string]$name, [scriptblock]$action) {
  Add-Report "`n## $name`nInício: $(Get-Date -Format o)"
  & $action
  Add-Report "Concluído: $(Get-Date -Format o)"
}
function Get-Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() }
function Invoke-R([string]$scriptName) {
  & $rscript (Join-Path $projectRoot "scripts\$scriptName") 2>&1 | Tee-Object -FilePath $reportPath -Append
  if ($LASTEXITCODE -ne 0) { throw "Falha em $scriptName (código $LASTEXITCODE)." }
}
function Download-OracleCsv {
  if (-not (Test-Path -LiteralPath $oraclePath)) { throw 'CSV Oracle 2026 atual não encontrado.' }
  $oldHash = Get-Sha256 $oraclePath
  $temporaryPath = "$oraclePath.download-$stamp"
  try {
    Invoke-WebRequest -Uri $OracleSourceUrl -OutFile $temporaryPath -MaximumRedirection 5
    if ((Get-Item -LiteralPath $temporaryPath).Length -lt 1024) { throw 'Download do Oracle é pequeno demais para ser um CSV válido.' }
    $head = Get-Content -LiteralPath $temporaryPath -TotalCount 1
    if ($head -match '<html|<!doctype' -or $head -notmatch ',') { throw 'Download do Oracle não é um CSV; provavelmente o Drive exigiu autenticação.' }
    $newHash = Get-Sha256 $temporaryPath
    if ($newHash -eq $oldHash) { throw 'O CSV baixado é idêntico ao CSV atual; nenhuma atualização foi publicada.' }
    Move-Item -LiteralPath $temporaryPath -Destination $oraclePath -Force
    Add-Report "SHA-256 anterior: $oldHash`nSHA-256 novo: $newHash"
  } finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
  }
}
function Publish-SyntheticBundle {
  if (-not (Test-Path -LiteralPath $bundlePath)) { throw 'Bundle sintético não foi gerado.' }
  $bundleRelative = 'app_data/synthetic_pinnacle_bundle.json'
  git diff --quiet -- $bundleRelative
  if ($LASTEXITCODE -eq 0) { throw 'O bundle sintético não mudou; publicação cancelada.' }
  git add -- $bundleRelative
  git commit -m "chore: refresh synthetic Pinnacle bundle $stamp" 2>&1 | Tee-Object -FilePath $reportPath -Append
  if ($LASTEXITCODE -ne 0) { throw 'Não foi possível criar o commit do bundle sintético.' }
  git push origin HEAD:main 2>&1 | Tee-Object -FilePath $reportPath -Append
  if ($LASTEXITCODE -ne 0) { throw 'Não foi possível publicar o commit no GitHub.' }
  $localHash = Get-Sha256 $bundlePath
  $remoteTemp = Join-Path $env:TEMP "synthetic-bundle-$stamp.json"
  try {
    Invoke-WebRequest -Uri $rawBundleUrl -OutFile $remoteTemp
    if ((Get-Sha256 $remoteTemp) -ne $localHash) { throw 'O bundle remoto do GitHub não corresponde ao bundle publicado.' }
  } finally { if (Test-Path $remoteTemp) { Remove-Item $remoteTemp -Force } }
  $health = Invoke-WebRequest -Uri $appHealthUrl -MaximumRedirection 5
  if ($health.StatusCode -ne 200) { throw "Streamlit não respondeu com HTTP 200: $($health.StatusCode)." }
  Add-Report 'GitHub confirmado pelo hash do bundle. Streamlit acessível pelo endpoint de saúde.'
}

try {
  if ($PlanOnly) { Add-Report 'Modo de plano: nenhuma alteração, treino ou publicação foi executada.'; exit 0 }
  if (-not $SkipDownload) { Invoke-Stage 'Download e validação do CSV Oracle' { Download-OracleCsv } }
  if (-not (Test-Path -LiteralPath $rscript)) { throw "Rscript não encontrado em $rscript" }
  if (-not $env:BETTINGISCOOL_API_KEY) { throw 'BETTINGISCOOL_API_KEY não está definida no processo.' }
  Invoke-Stage 'Registro e auditoria Oracle' { '01_register_raw_data.R','02_audit_and_normalize.R','03_build_canonical_games.R','04_write_processed_store.R' | ForEach-Object { Invoke-R $_ } }
  Invoke-Stage 'Features pré-abertura' { '07_build_team_metrics.R','09_build_rolling_team_features.R','10_build_map_feature_table.R','14_build_player_draft_audit.R','62_build_premap_ratio_features.R' | ForEach-Object { Invoke-R $_ } }
  Invoke-Stage 'Mercado BettingIsCool' { '51_collect_bettingiscool_odds.R','52_match_bettingiscool_games.R' | ForEach-Object { Invoke-R $_ } }
  Invoke-Stage 'Treino Pinnacle sintética' { Invoke-R '124_train_synthetic_pinnacle_direct_market.R' }
  Invoke-Stage 'Testes' { Invoke-R '99_run_full_tests.R'; python -m pytest tests_python -q 2>&1 | Tee-Object -FilePath $reportPath -Append; if ($LASTEXITCODE -ne 0) { throw "Falha nos testes Python ($LASTEXITCODE)." } }
  if (-not $NoPublish) { Invoke-Stage 'Publicação' { Publish-SyntheticBundle } }
  Add-Report "`n## Resultado`nDeu tudo certo!`nFim: $(Get-Date -Format o)"
} catch {
  Add-Report "`n## Resultado`nErro: $($_.Exception.Message)`nFim: $(Get-Date -Format o)"
  Write-Error "Atualização interrompida. Consulte $reportPath"
  exit 1
}
