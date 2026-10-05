; ملف تثبيت Order Ly لـ Windows (Inno Setup 6).
; البناء: tool\build_installer.ps1 (بيبني البرنامج وبيجهز ملفات Windows الناقصة وبيعمل الـ Setup).
#define AppName "Order Ly"
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\builds"
#endif

[Setup]
; المعرّف ده لازم يفضل ثابت عشان التحديثات تتسطب فوق النسخة القديمة
AppId={{7FDB53C7-7161-4124-81CD-6B1DAA795D0C}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Order Ly
DefaultDirName={autopf}\Order Ly
DefaultGroupName=Order Ly
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=OrderLy-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\orderly.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no

[Languages]
Name: "arabic"; MessagesFile: "compiler:Languages\Arabic.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
arabic.DesktopIcon=أيقونة على سطح المكتب
arabic.AutoStart=شغّل Order Ly لوحده مع تشغيل الكمبيوتر (مهم لو الجهاز ده هو كمبيوتر الكاشير)
arabic.LaunchApp=افتح Order Ly دلوقتي
english.DesktopIcon=Create a desktop shortcut
english.AutoStart=Start Order Ly automatically with Windows (recommended for the cafe server (cashier PC))
english.LaunchApp=Launch Order Ly now

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"
Name: "autostart"; Description: "{cm:AutoStart}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Order Ly"; Filename: "{app}\orderly.exe"
Name: "{autodesktop}\Order Ly"; Filename: "{app}\orderly.exe"; Tasks: desktopicon
Name: "{commonstartup}\Order Ly"; Filename: "{app}\orderly.exe"; Tasks: autostart

[Run]
; الـ Firewall: بنسمح للبرنامج بس (مش بورتات مفتوحة لأي حاجة) عشان الموبايلات تتصل بالسيرفر.
; profile=any لأن شبكة الواي فاي في كافيهات كتير Windows بيعتبرها "عامة".
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Order Ly"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Order Ly"" dir=in action=allow program=""{app}\orderly.exe"" enable=yes profile=any"; Flags: runhidden waituntilterminated
Filename: "{app}\orderly.exe"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Order Ly"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveFirewallRule"

; بيانات الكافيه (في AppData) مش بتتمسح مع إلغاء التثبيت، عشان مايضيعش حاجة بالغلط.
