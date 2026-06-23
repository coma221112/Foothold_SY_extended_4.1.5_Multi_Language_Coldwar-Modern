$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutDir = Join-Path $Root "build"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$VcVars = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path -LiteralPath $VcVars)) {
    throw "vcvars64.bat not found: $VcVars"
}

$Cmd = @"
call "$VcVars"
cd /d "$Root"
cl /nologo /std:c++17 /EHsc /O2 /MT /LD llmbridge.cpp /link /NOLOGO /OUT:"$OutDir\llmbridge.dll" winhttp.lib
"@

$CmdPath = Join-Path $OutDir "build.cmd"
Set-Content -LiteralPath $CmdPath -Value $Cmd -Encoding ASCII
cmd /c "`"$CmdPath`""
if ($LASTEXITCODE -ne 0) {
    throw "cl build failed with exit code $LASTEXITCODE"
}

Write-Host "Built $OutDir\llmbridge.dll"
