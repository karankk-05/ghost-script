Option Explicit
Dim shell, files, controller
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
controller = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "SessionControl.exe")
If Not files.FileExists(controller) Then
    MsgBox "SessionControl.exe is missing. Extract the complete updated toolkit first.", vbExclamation, "RDKit"
    WScript.Quit 1
End If
shell.Run Chr(34) & controller & Chr(34) & " start", 1, False
