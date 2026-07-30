; ==========================================================================
;  VaultMind - installer con procedura guidata (Inno Setup 6)
;
;  Sostituisce, per chi RICEVE l'app, la costruzione dell'exe sulla sua
;  macchina: la build la facciamo noi una volta (run.bat), l'utente riceve
;  un binario gia' pronto. run.bat resta la strada di sviluppo.
;
;  Scelte deliberate:
;  - Installazione PER-UTENTE, senza privilegi admin: niente UAC, meno
;    SmartScreen (che su un installer non firmato scatta piu' forte se
;    chiede privilegi). E' lo stesso stile dell'installer di Ollama.
;  - Ollama e' una SPUNTA, spenta di default: ~2 GB scaricati in silenzio
;    dentro un installer sono inaccettabili. La spunta non compare se
;    Ollama e' gia' installato.
;  - La disinstallazione NON tocca %USERPROFILE%\.vaultmind senza chiederlo:
;    li' ci sono le password dell'utente e non esiste recupero.
;
;  File in ASCII puro (niente accenti), come run.ps1: stessa ragione.
; ==========================================================================

#define MyAppName "VaultMind"
#define MyAppVersion "6.7"
#define MyAppExeName "VaultMind.exe"
; Percorso dell'exe costruito da run.bat. Prima di compilare l'installer
; l'exe deve essere aggiornato: lo verifica rilascio.ps1.
#define MyAppSource "..\VaultMind_Windows\dist\VaultMind.exe"

[Setup]
; AppId FISSO: e' la chiave con cui Windows riconosce "questa app".
; Cambiarlo fara' credere a Windows che sia un'app diversa (doppioni in
; "App installate", niente aggiornamento in place). Non toccarlo mai.
AppId={{7C1E9B62-4A0D-45F3-9E8B-2D5C6A31F0E4}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=VaultMind
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
; Per-utente: {autopf} con privilegi "lowest" diventa
; %LOCALAPPDATA%\Programs\VaultMind. Niente richiesta admin.
PrivilegesRequired=lowest
; Scrive DIRETTAMENTE nella cartella dei consegnabili: una copia sola, sempre
; quella vera. Con una Output\ separata più la copia nel pacchetto si tenevano
; 108 MB in doppio e bastava una dimenticanza per consegnare la build vecchia.
; Nome senza versione, come gli zip: il file è sempre l'ultimo compilato, la
; versione la dichiara l'installer stesso (e poi "App installate").
OutputDir=..\PACCHETTO X INSTALLAZIONE EVERYWHERE
OutputBaseFilename=VaultMind-Setup
SetupIconFile=..\VaultMind_Windows\VaultMind.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
; Wizard moderno = l'aspetto Windows attuale, barra di avanzamento verde.
WizardStyle=modern
; Se l'app e' aperta durante un aggiornamento, chiede di chiuderla invece
; di fallire a meta' con un errore di file in uso.
CloseApplications=yes
MinVersion=10.0

[Languages]
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
; La spunta Ollama compare solo se Ollama NON e' gia' sul computer.
Name: "ollama"; Description: "Scarica e installa Ollama + modello llama3.2:3b (circa 2 GB di download). Serve solo a rendere piu' naturali le frasi dell'assistente: VaultMind funziona anche senza."; Flags: unchecked; Check: not OllamaPresent

[Files]
Source: "{#MyAppSource}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\VaultMind_Windows\VaultMind.ico"; DestDir: "{app}"; Flags: ignoreversion
; L'estensione viaggia GIA' SPACCHETTATA: chi la vuole punta "Carica estensione
; non pacchettizzata" qui e basta, senza scaricare ed estrarre uno zip a parte
; (e senza il rischio di cancellare per sbaglio la cartella, che ucciderebbe
; l'estensione). Il percorso e' stabile fra un aggiornamento e l'altro: Chrome
; ricava l'ID di un'estensione scompattata dalla sua cartella, quindi cosi'
; l'abbinamento al vault sopravvive agli aggiornamenti.
Source: "..\extension\*"; DestDir: "{app}\estensione"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\VaultMind.ico"; Comment: "Gestore di password 100% locale"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\VaultMind.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  DownloadPage: TDownloadWizardPage;

{ Ollama si installa per-utente in %LOCALAPPDATA%\Programs\Ollama: e' il
  posto giusto dove cercarlo, senza fidarsi del PATH (che nell'ambiente
  dell'installer puo' essere vecchio). }
function OllamaExe(): String;
begin
  Result := ExpandConstant('{localappdata}\Programs\Ollama\ollama.exe');
end;

function OllamaPresent(): Boolean;
begin
  Result := FileExists(OllamaExe());
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing),
    'Download di Ollama in corso...', nil);
end;

{ Il download parte DOPO la pagina di riepilogo, cosi' chi toglie la spunta
  all'ultimo momento non scarica niente. }
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpReady) and WizardIsTaskSelected('ollama') then begin
    DownloadPage.Clear;
    DownloadPage.Add('https://ollama.com/download/OllamaSetup.exe', 'OllamaSetup.exe', '');
    DownloadPage.Show;
    try
      try
        DownloadPage.Download;
      except
        { Niente rete o download interrotto: VaultMind si installa comunque,
          l'assistente restera' in modalita' base. }
        MsgBox('Download di Ollama non riuscito. VaultMind verra'' installato ugualmente: l''assistente usera'' la modalita'' base. Potrai installare Ollama in un secondo momento da ollama.com.', mbInformation, MB_OK);
      end;
    finally
      DownloadPage.Hide;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  R: Integer;
begin
  if CurStep <> ssPostInstall then exit;
  if not WizardIsTaskSelected('ollama') then exit;
  if not FileExists(ExpandConstant('{tmp}\OllamaSetup.exe')) then exit;

  { /SILENT: l'installer di Ollama (anche lui Inno Setup, per-utente)
    mostra solo la barra di avanzamento. }
  Exec(ExpandConstant('{tmp}\OllamaSetup.exe'), '/SILENT', '', SW_SHOW,
       ewWaitUntilTerminated, R);
  if not OllamaPresent() then begin
    MsgBox('Installazione di Ollama non riuscita. VaultMind funziona comunque in modalita'' base.', mbInformation, MB_OK);
    exit;
  end;

  { "ollama pull" parla col server locale: va avviato prima. Se e' gia'
    attivo, "serve" muore da solo per porta occupata: innocuo (stesso
    schema di run.ps1). }
  Exec(OllamaExe(), 'serve', '', SW_HIDE, ewNoWait, R);
  Sleep(2500);

  { Il download del modello (~1,9 GB) in una finestra VISIBILE: l'utente
    ha spuntato la casella sapendo la dimensione, ma deve vedere il
    progresso, non fissare un installer apparentemente bloccato. }
  Exec(ExpandConstant('{cmd}'),
       '/c echo Download del modello llama3.2:3b (~1,9 GB)... && "' + OllamaExe() + '" pull llama3.2:3b',
       '', SW_SHOW, ewWaitUntilTerminated, R);
  if R <> 0 then
    MsgBox('Download del modello non riuscito. VaultMind funziona comunque; per riprovare piu'' tardi: "ollama pull llama3.2:3b".', mbInformation, MB_OK);
end;

{ ------------------------------------------------------- DISINSTALLAZIONE
  Le password dell'utente stanno in %USERPROFILE%\.vaultmind, FUORI dalla
  cartella dell'app: la disinstallazione normale non le tocca. Chiediamo
  esplicitamente, con default "No", perche' l'operazione e' irreversibile:
  non esiste alcun recupero, e' il principio del progetto. }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  VaultDir: String;
begin
  if CurUninstallStep <> usPostUninstall then exit;
  VaultDir := ExpandConstant('{%USERPROFILE}\.vaultmind');
  if not DirExists(VaultDir) then exit;
  if MsgBox('Vuoi eliminare anche il vault con le tue password salvate?' + #13#10 + #13#10 +
            '(' + VaultDir + ')' + #13#10 + #13#10 +
            'ATTENZIONE: l''operazione e'' IRREVERSIBILE. Non esiste alcun recupero: se un domani reinstalli VaultMind, le password eliminate ora saranno perse per sempre.' + #13#10 + #13#10 +
            'Scegli No per conservarle (consigliato).',
            mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    DelTree(VaultDir, True, True, True);
end;
