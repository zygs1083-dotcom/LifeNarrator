$ErrorActionPreference = 'Stop'
$release = (swift build -c release --show-bin-path).Trim()
$destination = Join-Path $PWD 'artifacts/brain'
New-Item $destination -ItemType Directory -Force | Out-Null
Copy-Item "$release/narrator-brain.exe" $destination
Get-ChildItem $release -Directory -Filter '*.resources' | Copy-Item -Destination $destination -Recurse
# Resolve the actual PE import closure, rather than copying the entire Swift SDK.
$search = @((Split-Path (Get-Command swift).Source)) + ($env:PATH -split ';')
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$dumpbin = & $vswhere -latest -products '*' -find 'VC/Tools/MSVC/**/bin/Hostx64/x64/dumpbin.exe'
$queue = [System.Collections.Generic.Queue[string]]::new()
$queue.Enqueue((Join-Path $destination 'narrator-brain.exe'))
$seen = @{}
while ($queue.Count -gt 0) {
    $binary = $queue.Dequeue()
    $imports = & $dumpbin /nologo /dependents $binary
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed: $binary" }
    foreach ($line in $imports) {
        if ($line -notmatch '^\s+(\S+\.dll)\s*$') { continue }
        $name = $Matches[1]
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $source = $search | ForEach-Object { Join-Path $_ $name } | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
        if (!$source) {
            if (!(Test-Path "$env:SystemRoot/System32/$name") -and $name -notlike 'api-ms-*' -and $name -notlike 'ext-ms-*') {
                throw "Unresolved runtime import: $name"
            }
            continue
        }
        if ($source.StartsWith($env:SystemRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
        Copy-Item $source $destination
        $queue.Enqueue((Join-Path $destination $name))
    }
}
$files = @(Get-ChildItem $destination -File -Recurse | ForEach-Object {
    @{ name = [IO.Path]::GetRelativePath($destination, $_.FullName); bytes = $_.Length }
})
@{ files = $files; totalBytes = ($files | Measure-Object -Property bytes -Sum).Sum } |
    ConvertTo-Json -Depth 5 | Set-Content artifacts/brain-size.json
