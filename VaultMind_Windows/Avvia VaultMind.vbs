' ============================================================================
'  Avvia VaultMind.vbs  -  lanciatore cliccabile per Windows
'  Doppio clic -> avvia run.bat (setup automatico + apertura app).
'  Lo script si mette nella cartella vaultmind-app e lancia run.bat.
' ============================================================================
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

' cartella dove si trova questo .vbs
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

' i sorgenti stanno in .\vaultmind-app\run.bat
batPath = fso.BuildPath(scriptDir, "vaultmind-app\run.bat")

If Not fso.FileExists(batPath) Then
  MsgBox "Non trovo vaultmind-app\run.bat accanto a questo file." & vbCrLf & _
         "Tieni 'Avvia VaultMind.vbs' nella stessa cartella di 'vaultmind-app'.", _
         vbCritical, "VaultMind"
  WScript.Quit 1
End If

' avvia run.bat in una finestra normale (1 = finestra visibile, mostra i log)
sh.CurrentDirectory = fso.BuildPath(scriptDir, "vaultmind-app")
sh.Run """" & batPath & """", 1, False
