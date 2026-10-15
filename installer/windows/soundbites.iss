; Inno Setup script for the Windows installer. Built by .github/workflows/build.yml on a Windows
; runner after `flutter build windows --release` and after ffmpeg has been copied into the build.
#define AppName "Soundbites"
#define AppVersion GetEnv("SOUNDBITES_VERSION")
#define BuildDir GetEnv("SOUNDBITES_BUILD_DIR")

[Setup]
AppId={{7D2F2C1E-4B0C-4E1A-9F2B-5B9D1C0A5A11}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Jak Lusty
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
UninstallDisplayIcon={app}\soundbites.exe
OutputDir=..\..\dist
OutputBaseFilename=Soundbites-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
DisableProgramGroupPage=yes

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\soundbites.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\soundbites.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Run]
Filename: "{app}\soundbites.exe"; Description: "Open Soundbites"; Flags: nowait postinstall skipifsilent
