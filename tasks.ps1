# PowerShell wrapper around the Makefile targets for native Windows users.
# Usage: .\tasks.ps1 <target>          e.g.  .\tasks.ps1 up

param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('help','up','down','logs','wait','check','psql','migrate','seed','bench','test','fmt','lint','clean','nuke')]
  [string]$Target
)

$ErrorActionPreference = 'Stop'

function Invoke-DockerCompose { param([string[]]$Args) & docker compose @Args }

switch ($Target) {
  'help' {
    Write-Output "QuantumSettle PowerShell tasks. Same targets as Makefile."
    Write-Output "  up | down | logs | wait | check | psql | migrate | seed | bench | test | fmt | lint | clean | nuke"
  }
  'up' {
    Invoke-DockerCompose @('up','-d')
    Write-Output ""
    Write-Output "Oracle starting. First boot can take ~2 minutes."
    Write-Output "Run: .\tasks.ps1 wait    -- to block until healthy"
    Write-Output "Run: .\tasks.ps1 logs    -- to tail startup logs"
  }
  'down'  { Invoke-DockerCompose @('stop') }
  'logs'  { Invoke-DockerCompose @('logs','-f','oracle') }
  'wait'  {
    Write-Output "Waiting for Oracle to report healthy..."
    while ($true) {
      $status = (docker inspect --format '{{.State.Health.Status}}' quantumsettle-oracle 2>$null)
      if ($status -eq 'healthy') { break }
      Start-Sleep -Seconds 5; Write-Host -NoNewline '.'
    }
    Write-Output ""; Write-Output "Oracle is healthy."
  }
  'check'   { python -m quantumsettle.scripts.check_db }
  'psql'    { Invoke-DockerCompose @('exec','oracle','bash','-lc','sqlplus -L $APP_USER/$APP_USER_PASSWORD@$ORACLE_DATABASE') }
  'migrate' { python -m quantumsettle.scripts.migrate }
  'seed'    { python -m quantumsettle.faker.run --trades 10000000 --lifecycle-multiplier 5 }
  'bench'   { python -m quantumsettle.bench.run }
  'test'    {
    pytest tests/py -v
    Write-Output ""
    Write-Output "TODO Phase 7: invoke utPLSQL test suite"
  }
  'fmt'   { ruff format py tests }
  'lint'  { ruff check py tests }
  'clean' { Invoke-DockerCompose @('stop') }
  'nuke'  { Invoke-DockerCompose @('down','-v') }
}
