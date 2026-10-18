# Starts the second (guest) game install for one-PC testing.
param(
    [string]$Guest = 'C:\Program Files (x86)\Steam\steamapps\common\SurrounDead_Guest',
    [int]$ResX = 1280,
    [int]$ResY = 720
)
$exe = Join-Path $Guest 'SurrounDead\Binaries\Win64\SurrounDead-Win64-Shipping.exe'
if (-not (Test-Path $exe)) { throw "Guest install not found - run tools\setup-guest.ps1 first." }
Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) `
    -ArgumentList @('-saveddirsuffix=Guest', '-windowed', "-ResX=$ResX", "-ResY=$ResY")
Write-Host "guest launched (log: $(Split-Path $exe)\ue4ss\UE4SS.log)"
