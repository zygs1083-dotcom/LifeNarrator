$ErrorActionPreference = 'Stop'
$destination = Join-Path $PSScriptRoot '../../.dev-data/models/Qwen3.5-0.8B-Q4_K_M.gguf'
New-Item (Split-Path $destination) -ItemType Directory -Force | Out-Null
if (!(Test-Path $destination)) {
    Invoke-WebRequest 'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf' -OutFile $destination
}
if ((Get-FileHash $destination -Algorithm SHA256).Hash -ne 'bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517') {
    throw 'Test model SHA-256 mismatch'
}
$path = (Resolve-Path $destination).Path
"NARRATOR_TEST_MODEL=$path" | Out-File $env:GITHUB_ENV -Append
