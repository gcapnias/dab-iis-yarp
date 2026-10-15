Set-StrictMode -Version Latest

$script:BrowserScratchOperatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:BrowserScratchSystemSid = 'S-1-5-18'
$script:BrowserScratchAdministratorsSid = 'S-1-5-32-544'
$script:BrowserScratchTrustedOwners = @(
    $script:BrowserScratchOperatorSid,
    $script:BrowserScratchSystemSid,
    $script:BrowserScratchAdministratorsSid
)
$script:BrowserScratchTrustedInstallerSid = $null
try {
    $script:BrowserScratchTrustedInstallerSid = ([Security.Principal.NTAccount]'NT SERVICE\TrustedInstaller').Translate([Security.Principal.SecurityIdentifier]).Value
}
catch {
    # The service may not be present on non-Windows hosts; no broad-name fallback is used.
}

if (-not ('Codex.BrowserScratchNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Codex {
    public static class BrowserScratchNative {
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes {
            public uint Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime { public uint Low; public uint High; }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation {
            public uint Attributes;
            public FileTime CreationTime;
            public FileTime LastAccessTime;
            public FileTime LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateDirectoryW(string path, IntPtr securityAttributes);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string descriptor, uint revision, out IntPtr securityDescriptor, out uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr memory);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint shareMode, IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation information);

        public static bool CreateDirectoryExclusive(string path, string operatorSid) {
            string descriptor = "O:" + operatorSid + "D:P" +
                "(A;OICI;FA;;;" + operatorSid + ")" +
                "(A;OICI;FA;;;S-1-5-18)" +
                "(A;OICI;FA;;;S-1-5-32-544)";
            IntPtr securityDescriptor;
            uint descriptorSize;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(descriptor, 1, out securityDescriptor, out descriptorSize)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            try {
                SecurityAttributes attributes = new SecurityAttributes();
                attributes.Length = (uint)Marshal.SizeOf(typeof(SecurityAttributes));
                attributes.SecurityDescriptor = securityDescriptor;
                attributes.InheritHandle = false;
                IntPtr attributesPointer = Marshal.AllocHGlobal((int)attributes.Length);
                try {
                    Marshal.StructureToPtr(attributes, attributesPointer, false);
                    if (CreateDirectoryW(path, attributesPointer)) return true;
                    int error = Marshal.GetLastWin32Error();
                    if (error == 183) return false;
                    throw new Win32Exception(error);
                }
                finally {
                    Marshal.FreeHGlobal(attributesPointer);
                }
            }
            finally {
                LocalFree(securityDescriptor);
            }
        }

        public static string GetFileIdentity(string path) {
            const uint ShareRead = 0x1;
            const uint ShareWrite = 0x2;
            const uint ShareDelete = 0x4;
            const uint OpenExisting = 3;
            const uint BackupSemantics = 0x02000000;
            const uint OpenReparsePoint = 0x00200000;
            using (SafeFileHandle handle = CreateFileW(path, 0, ShareRead | ShareWrite | ShareDelete, IntPtr.Zero, OpenExisting, BackupSemantics | OpenReparsePoint, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                return information.VolumeSerialNumber.ToString("X8") + ":" + information.FileIndexHigh.ToString("X8") + information.FileIndexLow.ToString("X8");
            }
        }
    }
}
'@ -ErrorAction Stop | Out-Null
}

function Get-BrowserScratchCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw 'scratch_path_unavailable'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals($fullPath, $pathRoot, [StringComparison]::OrdinalIgnoreCase)) { return $pathRoot }
    $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-BrowserScratchSystemVolumeRoot {
    param([Parameter(Mandatory)][string]$PathRoot)

    $systemRoot = [IO.Path]::GetPathRoot([Environment]::SystemDirectory)
    [string]::Equals(
        (Get-BrowserScratchCanonicalPath $PathRoot),
        (Get-BrowserScratchCanonicalPath $systemRoot),
        [StringComparison]::OrdinalIgnoreCase)
}

function Get-BrowserScratchPathComponents {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Get-BrowserScratchCanonicalPath $Path
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root) -or $root.StartsWith('\\')) {
        throw 'scratch_path_unavailable'
    }

    $paths = [Collections.Generic.List[string]]::new()
    $paths.Add($root)
    $relative = $fullPath.Substring($root.Length).Trim('\', '/')
    $current = $root
    foreach ($segment in $relative.Split(@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        $paths.Add($current)
    }
    $paths.ToArray()
}

function Get-BrowserScratchSecurityDescriptor {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'scratch_path_reparse_point'
        }
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        [pscustomobject]@{ Item = $item; Acl = $acl; OwnerSid = $owner }
    }
    catch {
        if ($_.Exception.Message -in @('scratch_path_reparse_point', 'scratch_path_unavailable')) { throw }
        throw 'scratch_path_unavailable'
    }
}

function Test-BrowserScratchComponentPolicy {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PathRoot,
        [switch]$HasExistingChild
    )

    $entry = Get-BrowserScratchSecurityDescriptor $Path
    if (-not $entry.Item.PSIsContainer) { throw 'scratch_path_unavailable' }
    $isVolumeRoot = [string]::Equals((Get-BrowserScratchCanonicalPath $Path), (Get-BrowserScratchCanonicalPath $PathRoot), [StringComparison]::OrdinalIgnoreCase)
    $isSystemVolumeRoot = $isVolumeRoot -and (Test-BrowserScratchSystemVolumeRoot -PathRoot $PathRoot)
    $permittedOwnerSids = @($script:BrowserScratchTrustedOwners)
    if ($isSystemVolumeRoot -and $script:BrowserScratchTrustedInstallerSid) {
        $permittedOwnerSids += $script:BrowserScratchTrustedInstallerSid
    }
    if ($entry.OwnerSid -notin $permittedOwnerSids) {
        throw 'scratch_path_untrusted_owner'
    }

    $controlRights = [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
    if (-not $isVolumeRoot) {
        $controlRights = $controlRights -bor [Security.AccessControl.FileSystemRights]::Delete
    }
    foreach ($rule in $entry.Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        if (($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        $sid = $rule.IdentityReference.Value
        $rights = [Security.AccessControl.FileSystemRights]$rule.FileSystemRights
        $mayControl = (($rights -band $controlRights) -ne 0)
        if ($HasExistingChild -and (($rights -band [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles) -ne 0)) {
            $mayControl = $true
        }
        if (-not $mayControl) { continue }

        $permittedControlSids = @($script:BrowserScratchTrustedOwners)
        if ($isSystemVolumeRoot -and $script:BrowserScratchTrustedInstallerSid) {
            $permittedControlSids += $script:BrowserScratchTrustedInstallerSid
        }
        if ($sid -notin $permittedControlSids) {
            throw 'scratch_path_untrusted_grant'
        }
    }
    $entry
}

function Test-ProtectedBrowserScratchBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeLeafDeleteChild
    )

    $components = @(Get-BrowserScratchPathComponents $Path)
    $root = [IO.Path]::GetPathRoot((Get-BrowserScratchCanonicalPath $Path))
    for ($index = 0; $index -lt $components.Count; $index++) {
        $hasChild = $index -lt $components.Count - 1 -or ($IncludeLeafDeleteChild -and $index -eq $components.Count - 1)
        $null = Test-BrowserScratchComponentPolicy -Path $components[$index] -PathRoot $root -HasExistingChild:$hasChild
    }
    $true
}

function Assert-ProtectedBrowserScratchAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunDirectoryPath,
        [switch]$RunDirectory
    )

    $entry = Get-BrowserScratchSecurityDescriptor $Path
    if (($entry.Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'scratch_path_reparse_point' }
    $fullRunPath = Get-BrowserScratchCanonicalPath $RunDirectoryPath
    $fullPath = Get-BrowserScratchCanonicalPath $Path
    $expectedOwner = @($script:BrowserScratchTrustedOwners)
    if ($entry.OwnerSid -notin $expectedOwner) { throw 'scratch_acl_untrusted_owner' }
    if (-not [string]::Equals($fullPath, $fullRunPath, [StringComparison]::OrdinalIgnoreCase) -and
        -not $fullPath.StartsWith($fullRunPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'scratch_path_identity_changed'
    }

    if ($RunDirectory -and -not $entry.Acl.AreAccessRulesProtected) {
        throw 'scratch_acl_inheritance_enabled'
    }
    $allowSids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $allowedRights = [Security.AccessControl.FileSystemRights]::FullControl
    foreach ($rule in $entry.Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = $rule.IdentityReference.Value
        if ($sid -notin $script:BrowserScratchTrustedOwners) { throw 'scratch_acl_untrusted_grant' }
        $allowSids.Add($sid) | Out-Null
        $rights = [Security.AccessControl.FileSystemRights]$rule.FileSystemRights
        if ($RunDirectory) {
            if ($rights -ne $allowedRights) { throw 'scratch_acl_unexpected_rights' }
            $requiredInheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
            if (($rule.InheritanceFlags -band $requiredInheritance) -ne $requiredInheritance -or
                $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) {
                throw 'scratch_acl_unexpected_inheritance'
            }
        } elseif (($rights -band $allowedRights) -ne $rights) {
            throw 'scratch_acl_unexpected_rights'
        }
    }
    if ($RunDirectory) {
        foreach ($sid in $script:BrowserScratchTrustedOwners) {
            if (-not $allowSids.Contains($sid)) { throw 'scratch_acl_missing_trusted_grant' }
        }
    }
    $true
}

function New-ProtectedBrowserScratchDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]+$')][string]$NamePrefix
    )

    $base = Get-BrowserScratchCanonicalPath $BasePath
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw 'scratch_path_unavailable' }
    $null = Test-ProtectedBrowserScratchBoundary -Path $base -IncludeLeafDeleteChild
    $directoryPath = Join-Path $base ($NamePrefix + '-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $directoryPath) { throw 'scratch_collision' }
    $createdScratch = $null
    try {
        $created = [Codex.BrowserScratchNative]::CreateDirectoryExclusive($directoryPath, $script:BrowserScratchOperatorSid)
        if (-not $created) { throw 'scratch_collision' }
        $createdScratch = [pscustomobject]@{
            Path = $directoryPath
            CreationTimeUtc = $null
            FileIdentity = $null
            OperatorSid = $script:BrowserScratchOperatorSid
        }
        $createdScratch.FileIdentity = [Codex.BrowserScratchNative]::GetFileIdentity($directoryPath)
        $createdItem = Get-Item -LiteralPath $directoryPath -Force -ErrorAction Stop
        $createdScratch.CreationTimeUtc = $createdItem.CreationTimeUtc
    }
    catch {
        if ($_.Exception.Message -eq 'scratch_collision') { throw 'scratch_collision' }
        $failure = [InvalidOperationException]::new('scratch_creation_failed')
        if ($null -ne $createdScratch) { $failure.Data['Scratch'] = $createdScratch }
        throw $failure
    }

    try {
        $null = Test-ProtectedBrowserScratchBoundary -Path $directoryPath
        $null = Assert-ProtectedBrowserScratchAcl -Path $directoryPath -RunDirectoryPath $directoryPath -RunDirectory
        $createdScratch
    }
    catch {
        $failure = [InvalidOperationException]::new('scratch_creation_unverified')
        if ($null -ne $createdScratch) { $failure.Data['Scratch'] = $createdScratch }
        throw $failure
    }
}

function Test-ProtectedBrowserScratchArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Scratch,
        [Parameter(Mandatory)][string]$Path
    )

    $fullRunPath = Get-BrowserScratchCanonicalPath $Scratch.Path
    $fullPath = Get-BrowserScratchCanonicalPath $Path
    if (-not $fullPath.StartsWith($fullRunPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'scratch_path_identity_changed'
    }
    $null = Test-ProtectedBrowserScratchBoundary -Path $fullRunPath
    $null = Assert-ProtectedBrowserScratchAcl -Path $fullPath -RunDirectoryPath $fullRunPath
    $true
}

function Remove-ProtectedBrowserScratchDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Scratch)

    try {
        $path = Get-BrowserScratchCanonicalPath $Scratch.Path
        $base = Split-Path -Parent $path
        $null = Test-ProtectedBrowserScratchBoundary -Path $base -IncludeLeafDeleteChild
        $null = Test-ProtectedBrowserScratchBoundary -Path $path
        $entry = Assert-ProtectedBrowserScratchAcl -Path $path -RunDirectoryPath $path -RunDirectory
        try {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            $fileIdentity = [Codex.BrowserScratchNative]::GetFileIdentity($path)
        }
        catch {
            throw 'scratch_path_identity_unavailable'
        }
        if ($entry -ne $true -or
            $item.CreationTimeUtc -ne $Scratch.CreationTimeUtc -or
            $fileIdentity -ne $Scratch.FileIdentity -or
            $Scratch.OperatorSid -ne $script:BrowserScratchOperatorSid) {
            return [pscustomobject]@{ Success = $false; Code = 'scratch_cleanup_unsafe' }
        }
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $path) { return [pscustomobject]@{ Success = $false; Code = 'scratch_cleanup_failed' } }
        [pscustomobject]@{ Success = $true; Code = $null }
    }
    catch {
        $code = if ($_.Exception.Message -like 'scratch_path_*' -or $_.Exception.Message -like 'scratch_acl_*') {
            'scratch_cleanup_unsafe'
        } else {
            'scratch_cleanup_failed'
        }
        [pscustomobject]@{ Success = $false; Code = $code }
    }
}
