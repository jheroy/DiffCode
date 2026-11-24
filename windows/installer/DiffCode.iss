; The Windows installer, built with Inno Setup 6 by .github/workflows/windows.yml:
;   ISCC /DAppVersion=0.4.5 /DAppBuild=12 windows\installer\DiffCode.iss
; after, in windows\, `cargo build -p diffcode --release` and `python installer\notices.py target\THIRD-PARTY-NOTICES.txt`.
;
; It installs for the current user (no administrator prompt) into %LOCALAPPDATA%\Programs\DiffCode, with a Start
; menu entry and, if asked, a desktop shortcut; /ALLUSERS on the command line installs for everyone instead.
; Settings live in %APPDATA%\DiffCode and stay when DiffCode is uninstalled, as they do on the Mac.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppBuild
  #define AppBuild "0"
#endif
#ifndef AppExe
  #define AppExe "..\target\release\DiffCode.exe"
#endif

[Setup]
; Never change the AppId: Windows knows an installed DiffCode, to upgrade or remove it, by this.
AppId={{B34CFEDD-3263-436E-AE18-FAFB2E68772B}
AppName=DiffCode
AppVersion={#AppVersion}
AppVerName=DiffCode {#AppVersion}
AppPublisher=DiffCode
AppPublisherURL=https://ihou.github.io/DiffCode/
AppSupportURL=https://github.com/ihou/DiffCode/issues
AppUpdatesURL=https://github.com/ihou/DiffCode/releases
VersionInfoVersion={#AppVersion}.{#AppBuild}
VersionInfoProductName=DiffCode
VersionInfoDescription=DiffCode Setup
DefaultDirName={autopf}\DiffCode
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
; 64-bit Windows 10 1809 or later: the integrated terminal needs the pseudo console that version brought.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
; The single-instance lock DiffCode holds while it runs (Local\DiffCode.Instance).
AppMutex=DiffCode.Instance
CloseApplications=yes
RestartApplications=no
SetupIconFile=..\crates\app\res\DiffCode.ico
UninstallDisplayIcon={app}\DiffCode.exe
UninstallDisplayName=DiffCode
WizardStyle=modern dynamic
WizardImageFile=WizardImage.png
WizardSmallImageFile=WizardSmall.png
ShowLanguageDialog=auto
OutputDir=..\target\dist
OutputBaseFilename=DiffCode-Setup-x64
Compression=lzma2/ultra64
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
; Inno Setup 7 ships Simplified Chinese; 6 has it only as a user translation, kept here (from Inno Setup 6.7.1's
; Files/Languages/Unofficial).
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#else
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\target\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\DiffCode"; Filename: "{app}\DiffCode.exe"
Name: "{autodesktop}\DiffCode"; Filename: "{app}\DiffCode.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\DiffCode.exe"; Description: "{cm:LaunchProgram,DiffCode}"; Flags: nowait postinstall skipifsilent
