import { execFile as execFileCallback } from "node:child_process";
import { randomUUID } from "node:crypto";
import { basename, join } from "node:path";
import { promisify } from "node:util";

const execFile = promisify(execFileCallback);
const userProfile = process.env.USERPROFILE;
const suppliedRunId = process.env.AGENT_PROCESS_LIFECYCLE_TEST_RUN_ID;
const effectiveRunId = suppliedRunId || randomUUID();
const runIdPattern = /^[A-Za-z0-9][A-Za-z0-9-]{0,63}$/u;

if (!userProfile) throw new Error("USERPROFILE is required for protected Windows test fixtures.");
if (!runIdPattern.test(effectiveRunId)) {
  throw new Error("AGENT_PROCESS_LIFECYCLE_TEST_RUN_ID must match ^[A-Za-z0-9][A-Za-z0-9-]{0,63}$.");
}

const fixtureRunRoot = join(userProfile, `.agent-process-lifecycle-test-${effectiveRunId}`);
const suiteFileName = process.argv.slice(1).find((argument) => /\.test\.[cm]?js$/iu.test(basename(argument))) ?? "suite";

export const fixtureRoot = join(fixtureRunRoot, `${fixtureBaseName(suiteFileName, 8)}-${process.pid}-${randomUUID()}`);

function powerShellLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

function fixtureBaseName(prefix, maximumLength = 64) {
  const baseName = prefix
    .split(/[\\/]/u)
    .at(-1)
    .replace(/[^a-z0-9-]/giu, "-")
    .replace(/-+/gu, "-")
    .replace(/^-|-$/gu, "");
  if (!baseName) throw new Error(`Fixture prefix has no safe basename: ${prefix}`);
  return baseName.slice(0, maximumLength);
}

async function runFixturePowerShell(script) {
  try {
    return await execFile("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], { windowsHide: true });
  } catch (error) {
    throw new Error([error.stderr, error.stdout, error.message].filter(Boolean).join("\n"), { cause: error });
  }
}

function fixtureDirectorySecurityFunctions() {
  return `$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User

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
    try {
      [IO.FileSystemAclExtensions]::CreateDirectory((New-CurrentUserDirectorySecurity), $path) | Out-Null
    } catch {
      $existing = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
      if ($null -eq $existing) { throw }
      if ($mustBeNew) { throw "Fixture child already exists: $path" }
    }
  }
  Assert-ProtectedCurrentUserDirectory $path
}`;
}

export async function mkdtemp(prefix) {
  const directory = join(fixtureRoot, `${fixtureBaseName(prefix, 8)}-${randomUUID()}`);
  const script = `$runRoot = ${powerShellLiteral(fixtureRunRoot)}
$suiteRoot = ${powerShellLiteral(fixtureRoot)}
$fixture = ${powerShellLiteral(directory)}
${fixtureDirectorySecurityFunctions()}

Ensure-ProtectedCurrentUserDirectory $runRoot
Ensure-ProtectedCurrentUserDirectory $suiteRoot
Ensure-ProtectedCurrentUserDirectory $fixture $true`;
  await runFixturePowerShell(script);
  return directory;
}

export async function cleanupFixtureRoot() {
  const script = `$runRoot = ${powerShellLiteral(fixtureRunRoot)}
$suiteRoot = ${powerShellLiteral(fixtureRoot)}
${fixtureDirectorySecurityFunctions()}

$suite = Get-Item -LiteralPath $suiteRoot -Force -ErrorAction SilentlyContinue
if ($null -ne $suite) {
  Assert-ProtectedCurrentUserDirectory $suiteRoot
  if (@(Get-ChildItem -LiteralPath $suiteRoot -Force).Count -ne 0) {
    throw "Fixture suite root is not empty: $suiteRoot"
  }
  [IO.Directory]::Delete($suiteRoot)
}

try {
  $run = Get-Item -LiteralPath $runRoot -Force -ErrorAction SilentlyContinue
  if ($null -ne $run) {
    Assert-ProtectedCurrentUserDirectory $runRoot
    try {
      [IO.Directory]::Delete($runRoot)
    } catch [IO.DirectoryNotFoundException] {
    } catch [Management.Automation.ItemNotFoundException] {
    } catch [IO.IOException] {
    }
  }
} catch [Management.Automation.ItemNotFoundException] {
} catch [IO.DirectoryNotFoundException] {
}

exit 0`;
  await runFixturePowerShell(script);
}
