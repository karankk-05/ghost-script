// Reversible per-user cleanup for the fixed RDKit download layouts.
// The caller must hold the account-wide controller lock and verify that no
// RustDesk process/service is using these directories before calling Prepare
// or Restore. This file never controls processes or Windows services.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Xml;

public static class SessionCleanup
{
    private const string MarkerName = ".rdkit-cleanup.xml";
    private const string OwnerName = "RDKit-session-owner.xml";
    private static readonly Guid DownloadsId = new Guid("374DE290-123F-4565-9164-39C4925E467B");

    public sealed class DeletionPlan
    {
        public string PackageRoot { get; internal set; }
        public string ControllerFolder { get; internal set; }
        // Null when the original archive is no longer present.
        public string ArchivePath { get; internal set; }
        public string StatePath { get; internal set; }
        public string Token { get; internal set; }
    }

    private sealed class DirectoryState
    {
        internal string Name;
        internal string Path;
        internal string Backup;
        internal bool Existed;
        internal string Phase;
    }

    private sealed class CleanupState
    {
        internal DeletionPlan Layout;
        internal bool ArchiveExisted;
        internal string ArchiveHash;
        internal readonly List<DirectoryState> Directories = new List<DirectoryState>();
    }

    // Resolve the real Windows Downloads folder, including folder redirection.
    public static DeletionPlan ResolveLayout(string controllerFolder)
    {
        return ResolveLayoutAt(controllerFolder, GetDownloadsFolder());
    }

    // Kept pure so the fixed-shape decisions can be verified without Windows.
    private static DeletionPlan ResolveLayoutAt(string controllerFolder, string downloadsFolder)
    {
        string controller = Canonical(controllerFolder);
        string downloads = Canonical(downloadsFolder);
        string fullRoot = Path.Combine(downloads, "RDKit");
        string windowsRoot = Path.Combine(downloads, "RDKit_windows");
        string package;
        string archive;
        if (Same(controller, Path.Combine(fullRoot, "windows")) ||
            Same(controller, Path.Combine(fullRoot, "RDKit", "windows")))
        {
            package = fullRoot;
            archive = Path.Combine(downloads, "RDKit.zip");
        }
        else if (Same(controller, windowsRoot))
        {
            package = windowsRoot;
            archive = Path.Combine(downloads, "RDKit_windows.zip");
        }
        else
            throw new InvalidOperationException("For automatic cleanup, extract RDKit.zip into your Downloads folder and launch its windows copy, or extract RDKit_windows.zip into Downloads\\RDKit_windows. This location is not one of those fixed layouts:\r\n" + controller);
        return new DeletionPlan {
            PackageRoot = Canonical(package), ControllerFolder = controller,
            ArchivePath = Canonical(archive), StatePath = Path.Combine(package, MarkerName)
        };
    }

    public static void Prepare(string controllerFolder)
    {
        PrepareAt(ResolveLayout(controllerFolder),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
    }

    private static void PrepareAt(DeletionPlan layout, string roaming, string local)
    {
        ValidateLayoutFiles(layout);
        CleanupState state;
        if (File.Exists(layout.StatePath))
        {
            state = Load(layout, roaming, local);
            ValidateArchive(state);
            AcquireOwnership(state);
            bool needsFreshTransaction = false;
            foreach (DirectoryState directory in state.Directories)
                if (directory.Phase == "removing" || directory.Phase == "restoring" || directory.Phase == "restored")
                    needsFreshTransaction = true;
            if (needsFreshTransaction)
            {
                RestoreState(state);
                ReleaseOwnership(state);
                state = CreateState(layout, roaming, local, state.ArchiveExisted, state.ArchiveHash);
                Save(state);
                AcquireOwnership(state);
            }
        }
        else
        {
            string ownerPath = Path.Combine(Canonical(local), OwnerName);
            ValidateNoReparse(ownerPath);
            if (Exists(ownerPath))
                throw new IOException("Another RDKit transaction owns this account's RustDesk data. Clean up its original extracted copy before launching this one:\r\n" + ownerPath);
            bool hasArchive = File.Exists(layout.ArchivePath);
            state = CreateState(layout, roaming, local, hasArchive,
                hasArchive ? HashFile(layout.ArchivePath) : null);
            Save(state);
            AcquireOwnership(state);
        }
        try
        {
            foreach (DirectoryState directory in state.Directories)
                PrepareDirectory(state, directory);
        }
        catch (Exception preparationError)
        {
            try
            {
                RestoreState(state);
                ReleaseOwnership(state);
            }
            catch (Exception restoreError)
            {
                throw new IOException(preparationError.Message + "\r\n\r\nAutomatic rollback also needs attention: " + restoreError.Message + "\r\nKeep this extracted toolkit and run Stop and Clean Up again.", preparationError);
            }
            throw;
        }
    }

    private static CleanupState CreateState(DeletionPlan layout, string roaming, string local, bool archiveExisted, string hash)
    {
        layout.Token = Guid.NewGuid().ToString("N");
        CleanupState state = new CleanupState { Layout = layout, ArchiveExisted = archiveExisted, ArchiveHash = hash };
        state.Directories.Add(NewDirectory("profile", roaming, "RustDesk", layout.Token));
        state.Directories.Add(NewDirectory("runtime", local, "rustdesk", layout.Token));
        // Validate both originals completely before moving either one.
        foreach (DirectoryState directory in state.Directories)
        {
            ValidateNoReparse(directory.Path);
            ValidateNoReparse(directory.Backup);
            RequireDirectoryOrMissing(directory.Path);
            if (Exists(directory.Backup))
                throw new IOException("The backup location already exists. It has not been changed:\r\n" + directory.Backup);
            directory.Existed = Directory.Exists(directory.Path);
        }
        return state;
    }

    private static DirectoryState NewDirectory(string name, string parent, string leaf, string token)
    {
        if (String.IsNullOrWhiteSpace(parent))
            throw new InvalidOperationException("Windows did not provide a user-data directory.");
        return new DirectoryState {
            Name = name, Path = Canonical(Path.Combine(parent, leaf)),
            Backup = Canonical(Path.Combine(parent, "RDKit-before-" + token + "-" + leaf)),
            Phase = "planned"
        };
    }

    private static void PrepareDirectory(CleanupState state, DirectoryState directory)
    {
        ValidateDirectoryPaths(directory);
        if (directory.Phase == "active")
        {
            RequireExpectedBackup(directory);
            // The portable wrapper may replace its extraction directory.
            Directory.CreateDirectory(directory.Path);
            return;
        }
        if (directory.Phase == "planned")
        {
            if (directory.Existed != Directory.Exists(directory.Path) || Exists(directory.Backup))
                throw RecoveryError(directory, "The original directory changed before the backup began.");
            SetPhase(state, directory, directory.Existed ? "moving" : "backed-up");
        }
        if (directory.Phase == "moving")
        {
            bool source = Directory.Exists(directory.Path);
            bool backup = Directory.Exists(directory.Backup);
            if (source && !backup)
                Directory.Move(directory.Path, directory.Backup);
            else if (source || !backup)
                throw RecoveryError(directory, "The interrupted backup has an ambiguous directory state.");
            SetPhase(state, directory, "backed-up");
        }
        if (directory.Phase == "backed-up")
        {
            RequireExpectedBackup(directory);
            if (Exists(directory.Path))
                throw RecoveryError(directory, "An unexpected directory appeared where the new session data should be created.");
            SetPhase(state, directory, "creating");
        }
        if (directory.Phase == "creating")
        {
            RequireExpectedBackup(directory);
            Directory.CreateDirectory(directory.Path);
            SetPhase(state, directory, "active");
        }
        if (directory.Phase != "active")
            throw RecoveryError(directory, "This transaction must finish restoring before another session can start.");
    }

    public static void Restore(string controllerFolder)
    {
        RestoreAt(ResolveLayout(controllerFolder),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
    }

    private static void RestoreAt(DeletionPlan layout, string roaming, string local)
    {
        ValidateLayoutFiles(layout);
        CleanupState state = Load(layout, roaming, local);
        AcquireOwnership(state);
        RestoreState(state);
        ReleaseOwnership(state);
    }

    private static void RestoreState(CleanupState state)
    {
        foreach (DirectoryState directory in state.Directories)
            ValidateDirectoryPaths(directory);
        foreach (DirectoryState directory in state.Directories)
            RestoreDirectory(state, directory);
    }

    private static void RestoreDirectory(CleanupState state, DirectoryState directory)
    {
        ValidateDirectoryPaths(directory);
        bool source = Directory.Exists(directory.Path);
        bool backup = Directory.Exists(directory.Backup);
        if (directory.Phase == "restored")
        {
            if (backup)
                throw RecoveryError(directory, "A backup remains after the transaction was marked restored.");
            return;
        }
        if (directory.Phase == "planned")
        {
            if (backup || directory.Existed != source)
                throw RecoveryError(directory, "The untouched original directory has changed unexpectedly.");
            SetPhase(state, directory, "restored");
            return;
        }
        if (directory.Phase == "moving")
        {
            if (source && !backup)
            {
                SetPhase(state, directory, "restored");
                return;
            }
            if (source || !backup)
                throw RecoveryError(directory, "The interrupted backup cannot be restored automatically.");
            SetPhase(state, directory, "restoring");
        }
        else if (directory.Phase == "backed-up")
        {
            RequireExpectedBackup(directory);
            if (source)
                throw RecoveryError(directory, "Unexpected data appeared before the session directory was created.");
            SetPhase(state, directory, "restoring");
        }
        else if (directory.Phase == "creating" || directory.Phase == "active")
        {
            RequireExpectedBackup(directory);
            // Persist deletion ownership before the first file is removed. A
            // failed/partial deletion is safely retryable as 'removing'.
            SetPhase(state, directory, "removing");
        }
        if (directory.Phase == "removing")
        {
            RequireExpectedBackup(directory);
            DeleteTreeNoReparse(directory.Path, null);
            SetPhase(state, directory, "restoring");
        }
        if (directory.Phase == "restoring")
        {
            source = Directory.Exists(directory.Path);
            backup = Directory.Exists(directory.Backup);
            if (directory.Existed)
            {
                if (!source && backup)
                    Directory.Move(directory.Backup, directory.Path);
                else if (!source || backup)
                    throw RecoveryError(directory, "The original backup could not be returned to its exact location.");
                // source && !backup is the crash window after the atomic move.
            }
            else if (source || backup)
                throw RecoveryError(directory, "New data appeared while cleanup was restoring an originally empty location.");
            SetPhase(state, directory, "restored");
        }
    }

    public static DeletionPlan GetDeletionPlan(string controllerFolder)
    {
        return GetDeletionPlanAt(ResolveLayout(controllerFolder),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
    }

    private static DeletionPlan GetDeletionPlanAt(DeletionPlan layout, string roaming, string local)
    {
        ValidateLayoutFiles(layout);
        CleanupState state = Load(layout, roaming, local);
        foreach (DirectoryState directory in state.Directories)
        {
            ValidateDirectoryPaths(directory);
            if (directory.Phase != "restored" || Exists(directory.Backup))
                throw RecoveryError(directory, "User data must be fully restored before the downloaded package can be deleted.");
            if (!directory.Existed && Exists(directory.Path))
                throw RecoveryError(directory, "New RustDesk data appeared after restoration. Cleanup stopped to preserve it.");
        }
        ValidateArchive(state);
        // Restored data no longer belongs to this transaction. A surviving
        // ownership pointer signals an interrupted final restoration step.
        string ownerPath = OwnershipPath(state);
        ValidateNoReparse(ownerPath);
        if (Exists(ownerPath))
            throw new IOException("The account's RDKit ownership record remains. Run Stop and Clean Up again before deleting the toolkit:\r\n" + ownerPath);
        return new DeletionPlan {
            PackageRoot = state.Layout.PackageRoot,
            ControllerFolder = state.Layout.ControllerFolder,
            ArchivePath = File.Exists(state.Layout.ArchivePath) ? state.Layout.ArchivePath : null,
            StatePath = state.Layout.StatePath,
            Token = state.Layout.Token
        };
    }

    // The external worker calls this only after all package executables exit.
    // The marker is kept until the rest of the tree has been removed so a
    // locked file does not discard the recovery record.
    public static void DeleteValidatedPackage(string controllerFolder)
    {
        DeleteValidatedPackageAt(ResolveLayout(controllerFolder),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
    }

    private static void DeleteValidatedPackageAt(DeletionPlan layout, string roaming, string local)
    {
        DeletionPlan plan = GetDeletionPlanAt(layout, roaming, local);
        if (plan.ArchivePath != null)
        {
            ValidateNoReparse(plan.ArchivePath);
            File.Delete(plan.ArchivePath);
            if (Exists(plan.ArchivePath)) throw new IOException("The downloaded ZIP could not be deleted:\r\n" + plan.ArchivePath);
        }
        DeleteTreeNoReparse(plan.PackageRoot, plan.StatePath);
        if (Exists(plan.PackageRoot)) throw new IOException("The extracted toolkit could not be fully deleted:\r\n" + plan.PackageRoot);
    }

    public static void ValidateNoReparse(string path)
    {
        string full = Canonical(path);
        string current = full;
        while (!String.IsNullOrEmpty(current))
        {
            FileAttributes attributes;
            if (TryAttributes(current, out attributes) && (attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Cleanup will not follow a symbolic link, junction, or other reparse point:\r\n" + current);
            string parent = Path.GetDirectoryName(current);
            if (String.Equals(parent, current, StringComparison.OrdinalIgnoreCase)) break;
            current = parent;
        }
        ValidateTree(full);
    }

    private static void ValidateTree(string path)
    {
        FileAttributes attributes;
        if (!TryAttributes(path, out attributes)) return;
        if ((attributes & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Cleanup will not follow a reparse point:\r\n" + path);
        if ((attributes & FileAttributes.Directory) == 0) return;
        foreach (string child in Directory.GetFileSystemEntries(path)) ValidateTree(child);
    }

    private static void DeleteTreeNoReparse(string path, string preserveUntilLast)
    {
        ValidateNoReparse(path);
        FileAttributes attributes;
        if (!TryAttributes(path, out attributes)) return;
        if ((attributes & FileAttributes.Directory) == 0)
            throw new IOException("Expected a directory during cleanup:\r\n" + path);
        foreach (string child in Directory.GetFileSystemEntries(path))
        {
            if (preserveUntilLast != null && Same(child, preserveUntilLast)) continue;
            ValidateNoReparse(child);
            if (Directory.Exists(child)) DeleteTreeNoReparse(child, null);
            else File.Delete(child);
        }
        ValidateNoReparse(path);
        if (preserveUntilLast != null && File.Exists(preserveUntilLast))
            File.Delete(preserveUntilLast);
        Directory.Delete(path, false);
    }

    private static void ValidateLayoutFiles(DeletionPlan layout)
    {
        ValidateNoReparse(layout.PackageRoot);
        ValidateNoReparse(layout.ArchivePath);
        if (!Directory.Exists(layout.PackageRoot))
            throw new DirectoryNotFoundException("The extracted toolkit folder is missing:\r\n" + layout.PackageRoot);
        if (Directory.Exists(layout.ArchivePath))
            throw new IOException("A directory occupies the downloaded ZIP path:\r\n" + layout.ArchivePath);
        if (Directory.Exists(layout.StatePath))
            throw new IOException("A directory occupies the cleanup-record path:\r\n" + layout.StatePath);
    }

    private static void ValidateDirectoryPaths(DirectoryState directory)
    {
        ValidateNoReparse(directory.Path);
        ValidateNoReparse(directory.Backup);
        RequireDirectoryOrMissing(directory.Path);
        RequireDirectoryOrMissing(directory.Backup);
    }

    private static void RequireExpectedBackup(DirectoryState directory)
    {
        ValidateDirectoryPaths(directory);
        if (Directory.Exists(directory.Backup) != directory.Existed)
            throw RecoveryError(directory, "The original backup is missing or an unexpected backup exists.");
    }

    private static void RequireDirectoryOrMissing(string path)
    {
        FileAttributes attributes;
        if (TryAttributes(path, out attributes) && (attributes & FileAttributes.Directory) == 0)
            throw new IOException("Expected a directory, but a file occupies this location:\r\n" + path);
    }

    private static void ValidateArchive(CleanupState state)
    {
        string archive = state.Layout.ArchivePath;
        ValidateNoReparse(archive);
        if (Directory.Exists(archive)) throw new IOException("A directory occupies the downloaded ZIP path:\r\n" + archive);
        if (!File.Exists(archive)) return;
        if (!state.ArchiveExisted || !String.Equals(HashFile(archive), state.ArchiveHash, StringComparison.Ordinal))
            throw new IOException("The ZIP in Downloads is new or has changed since this session was prepared. Cleanup will preserve both it and the extracted toolkit:\r\n" + archive);
    }

    private static CleanupState Load(DeletionPlan layout, string roaming, string local)
    {
        ValidateNoReparse(layout.StatePath);
        if (!File.Exists(layout.StatePath))
            throw new FileNotFoundException("No RDKit cleanup record exists. Start this updated toolkit once before using automatic cleanup. Existing files have not been removed.", layout.StatePath);
        XmlReaderSettings settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 65536 };
        XmlDocument document = new XmlDocument { XmlResolver = null };
        using (XmlReader reader = XmlReader.Create(layout.StatePath, settings)) document.Load(reader);
        XmlElement root = document.DocumentElement;
        if (root == null || root.Name != "rdkit-cleanup" || root.GetAttribute("version") != "1")
            throw new IOException("The RDKit cleanup record is invalid; it has been preserved for recovery.");
        string token = Required(root, "token");
        Guid parsed;
        if (!Guid.TryParseExact(token, "N", out parsed) || token != parsed.ToString("N"))
            throw new IOException("The cleanup-record token is invalid.");
        if (!Same(Required(root, "package"), layout.PackageRoot) ||
            !Same(Required(root, "controller"), layout.ControllerFolder) ||
            !Same(Required(root, "archive"), layout.ArchivePath))
            throw new IOException("The cleanup record belongs to a different toolkit location. No paths from that record will be deleted.");
        layout.Token = token;
        CleanupState state = new CleanupState {
            Layout = layout, ArchiveExisted = ParseBool(Required(root, "archive-existed")),
            ArchiveHash = root.GetAttribute("archive-sha256")
        };
        if (state.ArchiveExisted ? !IsHash(state.ArchiveHash) : state.ArchiveHash.Length != 0)
            throw new IOException("The stored ZIP identity is invalid.");
        Dictionary<string, DirectoryState> expected = new Dictionary<string, DirectoryState>(StringComparer.Ordinal);
        expected.Add("profile", NewDirectory("profile", roaming, "RustDesk", token));
        expected.Add("runtime", NewDirectory("runtime", local, "rustdesk", token));
        foreach (XmlNode node in root.ChildNodes)
        {
            XmlElement element = node as XmlElement;
            if (element == null || element.Name != "directory") throw new IOException("The cleanup record contains an unexpected entry.");
            string name = Required(element, "name");
            DirectoryState directory;
            if (!expected.TryGetValue(name, out directory)) throw new IOException("The cleanup record has an unknown or duplicate directory.");
            expected.Remove(name);
            if (!Same(Required(element, "path"), directory.Path) || !Same(Required(element, "backup"), directory.Backup))
                throw new IOException("The cleanup record contains a directory outside the exact current-user locations.");
            directory.Existed = ParseBool(Required(element, "existed"));
            directory.Phase = Required(element, "phase");
            if (!IsPhase(directory.Phase) || (directory.Phase == "moving" && !directory.Existed))
                throw new IOException("The cleanup record has an invalid recovery phase.");
            state.Directories.Add(directory);
        }
        if (expected.Count != 0) throw new IOException("The cleanup record is incomplete.");
        return state;
    }

    private static void SetPhase(CleanupState state, DirectoryState directory, string phase)
    {
        string previous = directory.Phase;
        directory.Phase = phase;
        try { Save(state); }
        catch { directory.Phase = previous; throw; }
    }

    private static string OwnershipPath(CleanupState state)
    {
        foreach (DirectoryState directory in state.Directories)
            if (directory.Name == "runtime") return Path.Combine(Path.GetDirectoryName(directory.Path), OwnerName);
        throw new IOException("The cleanup record has no runtime directory.");
    }

    private static void AcquireOwnership(CleanupState state)
    {
        string path = OwnershipPath(state);
        ValidateNoReparse(path);
        if (Directory.Exists(path)) throw new IOException("A directory occupies the RDKit account ownership record:\r\n" + path);
        if (File.Exists(path))
        {
            ValidateOwnership(state, path);
            return;
        }
        // The package marker is saved first. A crash here leaves a planned,
        // untouched transaction which can recreate this pointer on retry.
        byte[] bytes;
        using (MemoryStream buffer = new MemoryStream())
        {
            using (XmlWriter writer = XmlWriter.Create(buffer, new XmlWriterSettings { Encoding = new UTF8Encoding(false), Indent = true }))
            {
                writer.WriteStartElement("rdkit-owner");
                writer.WriteAttributeString("version", "1");
                writer.WriteAttributeString("token", state.Layout.Token);
                writer.WriteAttributeString("controller", state.Layout.ControllerFolder);
                writer.WriteEndElement();
            }
            bytes = buffer.ToArray();
        }
        string temporary = path + "." + state.Layout.Token + ".tmp";
        ValidateNoReparse(temporary);
        try
        {
            // A stale temporary pointer is our own exact GUID-scoped file;
            // the authoritative ownership filename is never overwritten.
            if (Directory.Exists(temporary)) throw new IOException("A directory occupies the temporary ownership record:\r\n" + temporary);
            if (File.Exists(temporary)) File.Delete(temporary);
            using (FileStream output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                output.Write(bytes, 0, bytes.Length);
                output.Flush(true);
            }
            ValidateNoReparse(path);
            File.Move(temporary, path);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static void ValidateOwnership(CleanupState state, string path)
    {
        XmlReaderSettings settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 16384 };
        XmlDocument document = new XmlDocument { XmlResolver = null };
        using (XmlReader reader = XmlReader.Create(path, settings)) document.Load(reader);
        XmlElement root = document.DocumentElement;
        if (root == null || root.Name != "rdkit-owner" || root.GetAttribute("version") != "1" ||
            root.ChildNodes.Count != 0 || root.GetAttribute("token") != state.Layout.Token ||
            !Same(Required(root, "controller"), state.Layout.ControllerFolder))
            throw new IOException("Another toolkit copy owns this account's saved RustDesk data, or its ownership record is invalid. Clean up the original copy first. This copy has not changed that ownership record:\r\n" + path);
    }

    private static void ReleaseOwnership(CleanupState state)
    {
        foreach (DirectoryState directory in state.Directories)
            if (directory.Phase != "restored") throw new IOException("Cannot release RDKit ownership before original user data is restored.");
        string path = OwnershipPath(state);
        ValidateNoReparse(path);
        if (!Exists(path)) return;
        ValidateOwnership(state, path);
        File.Delete(path);
    }

    private static void Save(CleanupState state)
    {
        ValidateNoReparse(state.Layout.StatePath);
        string temporary = state.Layout.StatePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            byte[] xml;
            using (MemoryStream buffer = new MemoryStream())
            {
                using (XmlWriter writer = XmlWriter.Create(buffer, new XmlWriterSettings { Encoding = new UTF8Encoding(false), Indent = true }))
                {
                    writer.WriteStartElement("rdkit-cleanup");
                    writer.WriteAttributeString("version", "1");
                    writer.WriteAttributeString("token", state.Layout.Token);
                    writer.WriteAttributeString("package", state.Layout.PackageRoot);
                    writer.WriteAttributeString("controller", state.Layout.ControllerFolder);
                    writer.WriteAttributeString("archive", state.Layout.ArchivePath);
                    writer.WriteAttributeString("archive-existed", state.ArchiveExisted ? "true" : "false");
                    writer.WriteAttributeString("archive-sha256", state.ArchiveHash ?? String.Empty);
                    foreach (DirectoryState directory in state.Directories)
                    {
                        writer.WriteStartElement("directory");
                        writer.WriteAttributeString("name", directory.Name);
                        writer.WriteAttributeString("path", directory.Path);
                        writer.WriteAttributeString("backup", directory.Backup);
                        writer.WriteAttributeString("existed", directory.Existed ? "true" : "false");
                        writer.WriteAttributeString("phase", directory.Phase);
                        writer.WriteEndElement();
                    }
                    writer.WriteEndElement();
                }
                xml = buffer.ToArray();
            }
            using (FileStream output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                output.Write(xml, 0, xml.Length);
                output.Flush(true);
            }
            ValidateNoReparse(state.Layout.StatePath);
            if (File.Exists(state.Layout.StatePath)) File.Replace(temporary, state.Layout.StatePath, null);
            else File.Move(temporary, state.Layout.StatePath);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static string HashFile(string path)
    {
        ValidateNoReparse(path);
        using (SHA256 sha = SHA256.Create())
        using (FileStream input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            return BitConverter.ToString(sha.ComputeHash(input)).Replace("-", String.Empty).ToLowerInvariant();
    }

    private static bool IsHash(string hash)
    {
        if (hash == null || hash.Length != 64) return false;
        foreach (char c in hash) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        return true;
    }

    private static bool IsPhase(string phase)
    {
        return phase == "planned" || phase == "moving" || phase == "backed-up" || phase == "creating" ||
            phase == "active" || phase == "removing" || phase == "restoring" || phase == "restored";
    }

    private static bool ParseBool(string value)
    {
        if (value == "true") return true;
        if (value == "false") return false;
        throw new IOException("The cleanup record contains an invalid boolean.");
    }

    private static string Required(XmlElement element, string name)
    {
        string value = element.GetAttribute(name);
        if (String.IsNullOrEmpty(value)) throw new IOException("The cleanup record is missing '" + name + "'.");
        return value;
    }

    private static bool TryAttributes(string path, out FileAttributes attributes)
    {
        try { attributes = File.GetAttributes(path); return true; }
        catch (FileNotFoundException) { attributes = 0; return false; }
        catch (DirectoryNotFoundException) { attributes = 0; return false; }
    }

    private static bool Exists(string path)
    {
        FileAttributes attributes;
        return TryAttributes(path, out attributes);
    }

    private static string Canonical(string path)
    {
        if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("A cleanup path is missing.");
        string full = Path.GetFullPath(path);
        string root = Path.GetPathRoot(full);
        while (full.Length > root.Length && (full[full.Length - 1] == Path.DirectorySeparatorChar || full[full.Length - 1] == Path.AltDirectorySeparatorChar))
            full = full.Substring(0, full.Length - 1);
        return full;
    }

    private static bool Same(string first, string second)
    {
        return String.Equals(Canonical(first), Canonical(second), StringComparison.OrdinalIgnoreCase);
    }

    private static Exception RecoveryError(DirectoryState directory, string message)
    {
        return new IOException(message + "\r\n\r\nUser data: " + directory.Path + "\r\nOriginal backup: " + directory.Backup + "\r\nThe cleanup record and any original backup have been kept for recovery.");
    }

    private static string GetDownloadsFolder()
    {
        IntPtr pointer;
        Guid id = DownloadsId;
        int result = SHGetKnownFolderPath(ref id, 0, IntPtr.Zero, out pointer);
        if (result != 0) Marshal.ThrowExceptionForHR(result);
        try { return Marshal.PtrToStringUni(pointer); }
        finally { Marshal.FreeCoTaskMem(pointer); }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHGetKnownFolderPath(ref Guid folderId, uint flags, IntPtr token, out IntPtr path);
}
