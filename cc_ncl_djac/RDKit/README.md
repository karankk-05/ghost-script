# RDKit: start, stop, and clean up

The toolkit runs portable RustDesk under your Windows account. A controller tracks
that launch and its child processes. It never installs or stops Windows services,
requests elevation, or changes taskbar/tray visibility settings.

## Start

1. Put the updated `RDKit.zip` in your Windows **Downloads** folder.
2. Extract the complete ZIP. Supported full-package layouts are
   `Downloads\RDKit\windows\SessionControl.exe` and Explorer's nested layout
   `Downloads\RDKit\RDKit\windows\SessionControl.exe`.
   The Windows-only ZIP instead uses
   `Downloads\RDKit_windows\SessionControl.exe` and `Downloads\RDKit_windows.zip`.
3. Close any independently running RustDesk copy first.
4. Double-click `launch.bat` normally, without **Run as administrator**.
   `silent.vbs` also starts the same controller without a command window;
   RustDesk's interface and connection indicators remain visible.

Use these exact folder and ZIP names. Keep unrelated files outside the extracted
folder: complete cleanup removes that entire toolkit folder.

Before launch, existing `%APPDATA%\RustDesk` and `%LOCALAPPDATA%\rustdesk`
directories are moved to uniquely named backup siblings on the same volume. The
new run uses fresh directories and the two supplied configuration files. A durable
cleanup record and an account-wide ownership file protect the original data and
allow recovery if a step fails. A second package cannot overwrite an unfinished
cleanup transaction, even after its RustDesk session has stopped.

## Stop and remove this run's files

1. Finish file transfers and save your work.
2. On the controlled Windows computer, open the extracted toolkit folder.
3. Double-click **`Stop and Clean Up.bat`** using the same Windows account and
   login session that started it.
4. Wait for the cleanup window to say **Cleanup complete**. Then press a key to
   close that window.

This shortcut:

- Stops this tracked RustDesk run and verifies that its processes have ended.
- Removes the configurations, application logs, and extracted runtime created for
  this run. If RustDesk data existed before launch, restores those original
  directories intact instead of deleting them.
- Deletes the matching downloaded ZIP and the extracted toolkit folder, including
  this shortcut and its controller.
- Deletes its temporary cleanup executable, script, and folder after the worker
  exits. Success is reported only after their removal is checked.

No Windows event/security logs, browser download history, other accounts' files,
or other remote-access applications are cleared. This is ordinary application
cleanup, not a promise to erase all records of software use.

The ZIP must still match the one present at first launch. A replacement download
is preserved. A missing ZIP is fine. Junctions/symbolic links, changed ownership
records, active independent RustDesk processes, or deletion errors stop cleanup
and produce an error instead of a false success report. If cleanup fails, follow
the specific error and keep any `RDKit-before-...` backups for recovery.

The tray's **Stop service** and closing RustDesk's window do not trigger cleanup.
Use the named shortcut. It cannot clean an old run started before this version,
because that run has no saved record of which files were there beforehand.

## Stop without deleting anything

Use **`Stop RustDesk.bat`** if you want to disconnect but keep the toolkit available.
It stops only the tracked run. You can launch it again, or later use
`Stop and Clean Up.bat` to restore the original files and remove the package.

Stopping forcefully ends the tracked process group, including child processes
started directly by this RustDesk run. It can interrupt a file transfer or settings
write. It does not sign you out of Windows.

## Limitations and recovery

- An installed RustDesk service or another RustDesk process blocks this portable
  workflow. The controller does not take ownership of or stop those components.
- Keep RustDesk in ordinary portable mode. Do not use its Install/Elevate actions;
  a separately elevated component would be outside this controller's ownership.
- Machine application restrictions may block the helper. No permission or policy
  bypass is attempted. PowerShell is not required.
- Use the same Windows login session for stopping and cleanup. If another login
  is still running RustDesk, cleanup refuses to remove shared account data.
- Do not delete the toolkit, its cleanup record, or the `RDKit-before-...` backups
  manually while a run is active or restoration is incomplete.
- If an original helper is still exiting, cleanup briefly retries locked files.
  A persistent lock or permission error is reported with the remaining location.
  If the shortcut is still present, retry it after resolving the error. If package
  removal was already partly completed and the error confirms the original data
  was restored, manually remove the reported remaining toolkit folder.

## Source and validation

Requires Windows 10/11 with .NET Framework 4.8. `SessionControl.exe` is built from
`SessionControl.cs` and `SessionCleanup.cs`; its manifest uses `asInvoker`.
`build-controller.bat` optionally rebuilds it with the .NET Framework compiler.
Normal use does not need compilation, installation, or administrator credentials.

The process group is a Windows Job Object. The portable executable is started
suspended, assigned to the job, then resumed. Child processes remain tracked when
the portable wrapper exits. The cleanup worker runs temporarily outside the
package so it can remove the original executable after it exits. It uses a
visible ordinary Command Prompt wrapper to remove its own temporary files.

Source compilation, isolated filesystem/recovery checks, and archive verification
are performed on the development Mac. Actual Windows process/GUI behaviour still
needs testing on the target PC. First check Start -> connect -> Stop and Clean Up;
confirm that the connection ends, the package/ZIP disappear, and any pre-existing
RustDesk data returns. `Stop RustDesk.bat` remains available for a stop-only check.

References:
- [Microsoft: Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
- [RustDesk 1.5.0 portable wrapper](https://github.com/rustdesk/rustdesk/blob/1.5.0/libs/portable/src/main.rs)
