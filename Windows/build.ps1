param([string]$Output = "$PSScriptRoot/artifacts/win-x64", [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
if (-not $SkipTests) {
    dotnet run --project "$PSScriptRoot/TimesFrame.Tests/TimesFrame.Tests.csproj" -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Core regression tests failed.' }
}
dotnet publish "$PSScriptRoot/TimesFrame.Windows/TimesFrame.Windows.csproj" -c Release -r win-x64 --self-contained true -p:DebugType=None -p:DebugSymbols=false -o $Output
if ($LASTEXITCODE -ne 0) { throw 'Windows x64 publish failed.' }
Copy-Item "$PSScriptRoot/README.md" "$Output/README-zh-CN.md" -Force
Copy-Item "$PSScriptRoot/THIRD-PARTY-NOTICES" "$Output/THIRD-PARTY-NOTICES" -Recurse -Force
Write-Host "Ready: $Output/TimesFrameAlbum.exe (Windows x64, self-contained)"
