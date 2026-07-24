param(
    [int]$Port = 8509
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$logDirectory = Join-Path $projectRoot "logs"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$stdoutPath = Join-Path $logDirectory "streamlit.out.log"
$stderrPath = Join-Path $logDirectory "streamlit.err.log"
$pythonPath = (Get-Command python -ErrorAction Stop).Source
$arguments = @(
    "-m",
    "streamlit",
    "run",
    "streamlit_app.py",
    "--server.port",
    $Port,
    "--server.headless",
    "true"
)
$process = Start-Process `
    -FilePath $pythonPath `
    -ArgumentList $arguments `
    -WorkingDirectory $projectRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -WindowStyle Hidden `
    -PassThru

Write-Output $process.Id
