param([string]$LuaDirectory)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $LuaDirectory) { $LuaDirectory = Join-Path $projectRoot 'tools\lua-5.1.5' }
$lua = Join-Path $LuaDirectory 'lua5.1.exe'
$luac = Join-Path $LuaDirectory 'luac5.1.exe'
if (-not (Test-Path -LiteralPath $lua)) { throw "Interpréteur Lua introuvable : $lua" }
$previousLuaPath = $env:LUA_PATH
Push-Location $projectRoot
try {
    $env:LUA_PATH = '.\TreeExporter.lrplugin\?.lua;.\tests\?.lua;;'
    foreach ($file in Get-ChildItem -LiteralPath '.\TreeExporter.lrplugin' -Filter '*.lua') {
        & $luac -p $file.FullName
        if ($LASTEXITCODE -ne 0) { throw "Syntaxe invalide : $($file.Name)" }
    }
    foreach ($test in 'test_planner.lua', 'test_metadata.lua', 'test_export.lua', 'test_dialog.lua') {
        & $lua (Join-Path $PSScriptRoot $test)
        if ($LASTEXITCODE -ne 0) { throw "Échec : $test" }
    }
    Write-Output '81 tests réussis ; syntaxe Lua 5.1 valide.'
}
finally {
    $env:LUA_PATH = $previousLuaPath
    Pop-Location
}
