# Windows packaging: build, copy ffmpeg next to the exe, make the Inno Setup installer.
$ErrorActionPreference = "Stop"
$version = ((Get-Content pubspec.yaml | Select-String '^version:').ToString() -split ' ')[1] -split '\+' | Select-Object -First 1
flutter build windows --release
$build = "build\windows\x64\runner\Release"
New-Item -ItemType Directory -Force -Path "$build\ffmpeg" | Out-Null
Copy-Item vendor\ffmpeg\win\ffmpeg.exe, vendor\ffmpeg\win\ffprobe.exe "$build\ffmpeg\"
Get-ChildItem vendor\ffmpeg\win -Include COPYING*,LICENSE* -Recurse | Copy-Item -Destination "$build\ffmpeg\"
if (-not (Get-Command iscc -ErrorAction SilentlyContinue)) { choco install innosetup -y --no-progress | Out-Null }
$env:SOUNDBITES_VERSION = $version
$env:SOUNDBITES_BUILD_DIR = (Resolve-Path $build).Path
New-Item -ItemType Directory -Force -Path dist | Out-Null
iscc /O"$((Resolve-Path dist).Path)" installer\windows\soundbites.iss
if (-not (Get-ChildItem dist -Filter *.exe)) { throw "no installer in dist" }
Get-ChildItem dist
