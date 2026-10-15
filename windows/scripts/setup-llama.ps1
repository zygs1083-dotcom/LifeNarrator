$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '../..' | Resolve-Path
$destination = Join-Path $root '.dev-data/llama'
New-Item "$destination/include", "$destination/lib", "$destination/bin" -ItemType Directory -Force | Out-Null
function Download-Verified($url, $path, $sha256) {
    if (!(Test-Path $path)) { Invoke-WebRequest $url -OutFile $path }
    if ((Get-FileHash $path -Algorithm SHA256).Hash -ne $sha256) { throw "SHA-256 mismatch: $path" }
}
$release = 'https://github.com/ggml-org/llama.cpp/releases/download/b11429'
Download-Verified "$release/llama-b11429-bin-win-cpu-x64.zip" "$destination/cpu.zip" '1283323272b04cd07905816a597a0da810918102de958f4ff6f7bbaa70ed2efe'
Download-Verified "$release/llama-b11429-bin-win-vulkan-x64.zip" "$destination/vulkan.zip" '1bfe78ad9168b79fa02bf67f6af9f5e17a966d824d77238517f7bef12ac73b36'
Expand-Archive "$destination/cpu.zip" "$destination/cpu" -Force
Expand-Archive "$destination/vulkan.zip" "$destination/vulkan" -Force
# CPU variants and Vulkan are loaded at runtime, so they are absent from the PE import table.
Copy-Item "$destination/cpu/llama.dll", "$destination/cpu/ggml.dll", "$destination/cpu/ggml-base.dll", "$destination/cpu/ggml-cpu-*.dll", "$destination/cpu/libomp.dll", "$destination/vulkan/ggml-vulkan.dll" "$destination/bin"
Copy-Item "$destination/cpu/LICENSE-LLVM-OpenMP" "$destination/bin"
$commit = 'd81235049384534c167caea52b85a694f6103d14'
Download-Verified "https://raw.githubusercontent.com/ggml-org/llama.cpp/$commit/LICENSE" "$destination/bin/LICENSE-llama" '94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d'
$headers = @{
    'llama.h' = 'c9a5f025ad7dbf07eda6660c8ff2c32cd80c07ba440d80728707a9c9d13c1bc3'
    'ggml.h' = '12ee71f99db7db9b353bc02b1fbb57c344ee17c01ac5fb7952b41a637a747ea9'
    'ggml-cpu.h' = '316279e004cdeb8e6ef78599acb602bf79a8abdf897fed9fd1914808c1518c6e'
    'ggml-backend.h' = '5791edae1fb7622027621d15bc7a160198bd3b75ed8f96d06cb7b85e2b873756'
    'ggml-opt.h' = '3586de1bc8a934b5c72339e2b6937b0641e8f149b512231e666f67de0736eea2'
    'ggml-alloc.h' = 'd114067f9099c4a0e2bbc0625c676d4894d9cf0ea27168ee072c7de0e71bb51d'
    'gguf.h' = 'e56714aab702e5ce62ee587a409643c08f7e93e8fbb77f48ef7cc85075f96fa4'
}
foreach ($name in $headers.Keys) {
    $directory = if ($name -eq 'llama.h') { 'include' } else { 'ggml/include' }
    Download-Verified "https://raw.githubusercontent.com/ggml-org/llama.cpp/$commit/$directory/$name" "$destination/include/$name" $headers[$name]
}
# Official Windows archives contain DLLs but no import libraries; derive them from those exact exports.
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$tools = & $vswhere -latest -products '*' -find 'VC/Tools/MSVC/**/bin/Hostx64/x64/dumpbin.exe' | Select-Object -Last 1 | Split-Path
foreach ($name in @('llama', 'ggml')) {
    $exports = & "$tools/dumpbin.exe" /nologo /exports "$destination/bin/$name.dll"
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed: $name" }
    $symbols = $exports | ForEach-Object { if ($_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\w+)') { $Matches[1] } }
    @("LIBRARY $name.dll", 'EXPORTS') + $symbols | Set-Content "$destination/lib/$name.def"
    & "$tools/lib.exe" /nologo /machine:x64 "/def:$destination/lib/$name.def" "/out:$destination/lib/$name.lib"
    if ($LASTEXITCODE -ne 0) { throw "lib failed: $name" }
}
# The linked DLLs are also needed by Swift test executables.
$env:PATH = "$destination/bin;$env:PATH"
if ($env:GITHUB_PATH) { "$destination/bin" | Out-File $env:GITHUB_PATH -Append }
