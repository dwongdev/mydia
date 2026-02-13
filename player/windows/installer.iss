; Mydia Player - Inno Setup Installer Script
; Builds a per-user installer (no UAC) for the Flutter Windows release.
;
; Pass the version at compile time:
;   iscc installer.iss /DMyAppVersion=1.2.3

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppName "Mydia Player"
#define MyAppPublisher "dev.mydia"
#define MyAppExeName "mydia-player.exe"
#define MyAppUrl "https://github.com/getmydia/mydia"

; The Flutter release build output, relative to this .iss file
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{E8A3F2B1-7C4D-4E5A-9B6F-1D2E3F4A5B6C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppUrl}
AppSupportURL={#MyAppUrl}/issues
DefaultDirName={localappdata}\MydiaPlayer
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\build\installer
OutputBaseFilename=mydia-player-windows-v{#MyAppVersion}
SetupIconFile=runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Copy the entire Flutter release bundle
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
