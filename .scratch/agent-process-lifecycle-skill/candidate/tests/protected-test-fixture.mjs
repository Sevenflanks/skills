import { execFile as execFileCallback } from "node:child_process";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { promisify } from "node:util";

const execFile = promisify(execFileCallback);
const userProfile = process.env.USERPROFILE;

if (!userProfile) throw new Error("USERPROFILE is required for protected Windows test fixtures.");

const fixtureRoot = join(userProfile, ".agent-process-lifecycle", "Tests");

function powerShellLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

function fixtureBaseName(prefix) {
  const baseName = prefix.split(/[\\/]/u).at(-1).replace(/[^a-z0-9-]/giu, "");
  if (!baseName) throw new Error(`Fixture prefix has no safe basename: ${prefix}`);
  return baseName;
}

export async function mkdtemp(prefix) {
  const directory = join(fixtureRoot, `${fixtureBaseName(prefix)}${randomUUID()}`);
  const script = `$root = ${powerShellLiteral(join(userProfile, ".agent-process-lifecycle"))}
$tests = ${powerShellLiteral(fixtureRoot)}
$fixture = ${powerShellLiteral(directory)}
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User

function New-CurrentUserDirectorySecurity {
  $security = [Security.AccessControl.DirectorySecurity]::new()
  $security.SetOwner($sid)
  $security.SetAccessRuleProtection($true, $false)
  $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
  return $security
}

function Assert-ProtectedCurrentUserDirectory([string]$path) {
  $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
  if (-not ($item -is [IO.DirectoryInfo])) { throw "Fixture node is not a directory: $path" }
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Fixture node is a reparse point: $path" }

  $security = [IO.FileSystemAclExtensions]::GetAccessControl($item)
  if (-not $security.AreAccessRulesProtected) { throw "Fixture node ACL inheritance is not protected: $path" }
  if ($security.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value) { throw "Fixture node owner is not the current user: $path" }

  $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  if ($rules.Count -ne 1) { throw "Fixture node has unexpected ACL entries: $path" }
  $rule = $rules[0]
  if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
      $rule.IdentityReference.Value -ne $sid.Value -or
      [uint32]$rule.FileSystemRights -ne [uint32][Security.AccessControl.FileSystemRights]::FullControl -or
      $rule.InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]::None -or
      $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) {
    throw "Fixture node ACL is not current-user-only FullControl: $path"
  }
}

function Ensure-ProtectedCurrentUserDirectory([string]$path, [bool]$mustBeNew = $false) {
  $existing = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if ($null -ne $existing -and $mustBeNew) {
    throw "Fixture child already exists: $path"
  }
  if ($null -eq $existing) {
    [IO.FileSystemAclExtensions]::CreateDirectory((New-CurrentUserDirectorySecurity), $path) | Out-Null
  }
  Assert-ProtectedCurrentUserDirectory $path
}

Ensure-ProtectedCurrentUserDirectory $root
Ensure-ProtectedCurrentUserDirectory $tests
Ensure-ProtectedCurrentUserDirectory $fixture $true`;
  await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
  return directory;
}
