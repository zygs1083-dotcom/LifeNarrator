$ErrorActionPreference = 'Stop'
$destination = Join-Path $PSScriptRoot '../../.dev-data/models/Qwen3-1.7B-Q8_0.gguf'
New-Item (Split-Path $destination) -ItemType Directory -Force | Out-Null
if (!(Test-Path $destination)) {
    Invoke-WebRequest 'https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/90862c4b9d2787eaed51d12237eafdfe7c5f6077/Qwen3-1.7B-Q8_0.gguf' -OutFile $destination
}
if ((Get-FileHash $destination -Algorithm SHA256).Hash -ne '061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a') {
    throw 'Test model SHA-256 mismatch'
}
$path = (Resolve-Path $destination).Path
"NARRATOR_TEST_MODEL=$path" | Out-File $env:GITHUB_ENV -Append
