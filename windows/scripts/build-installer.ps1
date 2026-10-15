param([string]$Version)
$ErrorActionPreference = 'Stop'
if (!$Version) { $Version = [regex]::Match((Get-Content Sources/NarratorCore/NarratorCore.swift -Raw), 'version = "([^"]+)"').Groups[1].Value }
if (!$version) { throw 'Core version not found' }
dotnet publish windows/LifeNarrator.Windows -c Release -r win-x64 --self-contained true -p:Version=$version -o artifacts/shell
if ($LASTEXITCODE -ne 0) { throw 'Shell publish failed' }
New-Item artifacts/shell/brain -ItemType Directory -Force | Out-Null
Copy-Item artifacts/brain/* artifacts/shell/brain -Recurse -Force
$iscc = "${env:ProgramFiles(x86)}/Inno Setup 6/ISCC.exe"
& $iscc /DAppVersion=$version windows/installer/LifeNarrator.iss
if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
$hash = (Get-FileHash artifacts/LifeNarrator-Setup.exe -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  LifeNarrator-Setup.exe" | Set-Content artifacts/checksums-windows.txt -Encoding ascii
