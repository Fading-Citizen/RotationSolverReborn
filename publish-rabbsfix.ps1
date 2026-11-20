<#
publish-rabbsfix.ps1 - Rebase the Rabbs BLM fix on upstream RSR, rebuild, release and update pluginmaster.json.

Version scheme: upstream tag a.b.c.d  ->  a.b.c.(d*100 + n), n = 1,2,3... per fork release on that upstream version.
  e.g. upstream 7.5.8.7 -> 7.5.8.701, 7.5.8.702 ; upstream 7.5.8.8 -> 7.5.8.801 (always higher than the previous one).
Tag: rabbsfix-a_b_c_x (no dots on purpose: upstream's publish workflow triggers on tags like *.*.*.*).
pluginmaster.json lives on the fork's main branch:
  https://raw.githubusercontent.com/Fading-Citizen/RotationSolverReborn/main/pluginmaster.json

Usage (from the repo folder):  .\publish-rabbsfix.ps1            # fetch upstream, rebase, build, release
                               .\publish-rabbsfix.ps1 -NoRebase  # release current branch as is
                               .\publish-rabbsfix.ps1 -RefreshDalamud  # re-download Dalamud assemblies first
Note: after a rebase the branch is pushed with --force-with-lease (it is this fork's own patch branch).
#>
param(
    [switch]$NoRebase,
    [switch]$RefreshDalamud,
    [string]$Version
)
$ErrorActionPreference = 'Stop'
$Repo   = 'Fading-Citizen/RotationSolverReborn'
$Branch = 'rabbs-2target-fix'
$Root   = $PSScriptRoot
Set-Location $Root
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')

function Run([string]$exe, [string[]]$argv) {
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { throw "$exe $($argv -join ' ') failed ($LASTEXITCODE)" }
}

if ((git status --porcelain --untracked-files=no) ) { throw 'Working tree has uncommitted changes.' }
Run git @('checkout', $Branch)

# 1. Upstream sync
Run git @('fetch', 'upstream', '--tags')
$rebased = $false
if (-not $NoRebase) {
    $before = (git rev-parse HEAD).Trim()
    Run git @('rebase', 'upstream/main')
    $rebased = ((git rev-parse HEAD).Trim() -ne $before)
}

# 2. Version
if (-not $Version) {
    $up = (git describe --tags --abbrev=0 upstream/main).Trim()
    $p = $up.Split('.')
    if ($p.Count -ne 4) { throw "Unexpected upstream tag '$up'" }
    $existing = @(gh release list -R $Repo --limit 200 --json tagName --jq '.[].tagName')
    $n = 1
    do {
        $Version = '{0}.{1}.{2}.{3}' -f $p[0], $p[1], $p[2], ([int]$p[3] * 100 + $n)
        $tag = 'rabbsfix-' + $Version.Replace('.', '_')
        $n++
    } while ($existing -contains $tag)
}
$Tag = 'rabbsfix-' + $Version.Replace('.', '_')
Write-Host "Version $Version  tag $Tag"

# 3. Dalamud assemblies (local, not XIVLauncher)
$dal = Join-Path $Root '.dalamud'
if ($RefreshDalamud -or -not (Test-Path (Join-Path $dal 'Dalamud.dll'))) {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri 'https://goatcorp.github.io/dalamud-distrib/latest.zip' -OutFile (Join-Path $Root 'dalamud-latest.zip') -UseBasicParsing
    Expand-Archive -Force (Join-Path $Root 'dalamud-latest.zip') -DestinationPath $dal
}
$env:DALAMUD_HOME = $dal + '\'

# 4. Build
Run dotnet @('build', '-c', 'Release', 'RotationSolver/RotationSolver.csproj', "-p:AssemblyVersion=$Version", "-p:FileVersion=$Version", "-p:PackageVersion=$Version", "-p:InformationalVersion=$Version")
$zip = Join-Path $Root 'RotationSolver\bin\Release\RotationSolver\latest.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$za = [IO.Compression.ZipFile]::OpenRead($zip)
$rd = New-Object IO.StreamReader($za.GetEntry('RotationSolver.json').Open())
$manifest = $rd.ReadToEnd() | ConvertFrom-Json
$rd.Close(); $za.Dispose()
if ($manifest.AssemblyVersion -ne $Version) { throw "Zip manifest version $($manifest.AssemblyVersion) != $Version" }

# 5. Push branch + release
if ($rebased) { Run git @('push', '--force-with-lease', 'origin', $Branch) } else { Run git @('push', 'origin', $Branch) }
Run gh @('release', 'create', $Tag, $zip, '-R', $Repo, '--target', $Branch, '--title', "RSR $Version (Rabbs fix)", '--notes', "Upstream RSR $((git describe --tags --abbrev=0 upstream/main).Trim()) + Rabbs BLM 2-target/AoE fix. Install via custom repo https://raw.githubusercontent.com/$Repo/main/pluginmaster.json")

# 6. pluginmaster.json on main (separate worktree)
$dl = "https://github.com/$Repo/releases/download/$Tag/latest.zip"
$entry = [ordered]@{
    Author              = $manifest.Author
    Name                = 'Rotation Solver Reborn (Rabbs fix)'
    InternalName        = $manifest.InternalName
    AssemblyVersion     = $Version
    TestingAssemblyVersion = $Version
    Description         = "Fork of Rotation Solver Reborn with a fix for the Rabbs Blackest Mage rotation (2-target cycle optional, respects AoE usage Off).`n`n" + $manifest.Description
    ApplicableVersion   = $manifest.ApplicableVersion
    RepoUrl             = "https://github.com/$Repo/tree/$Branch"
    Tags                = $manifest.Tags
    CategoryTags        = $manifest.CategoryTags
    DalamudApiLevel     = $manifest.DalamudApiLevel
    LoadPriority        = $manifest.LoadPriority
    IconUrl             = $manifest.IconUrl
    Punchline           = $manifest.Punchline
    AcceptsFeedback     = $false
    IsHide              = $false
    IsTestingExclusive  = $false
    DownloadLinkInstall = $dl
    DownloadLinkTesting = $dl
    DownloadLinkUpdate  = $dl
    LastUpdate          = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}
$wt = Join-Path $Root '.pm-main'
if (-not (Test-Path $wt)) { Run git @('worktree', 'add', $wt, 'main') }
Push-Location $wt
try {
    Run git @('pull', '--ff-only', 'origin', 'main')
    $json = ConvertTo-Json -InputObject @($entry) -Depth 5
    [IO.File]::WriteAllText((Join-Path $wt 'pluginmaster.json'), $json, (New-Object Text.UTF8Encoding($false)))
    Run git @('add', 'pluginmaster.json')
    Run git @('commit', '-m', "pluginmaster: Rabbs fix $Version")
    Run git @('push', 'origin', 'main')
} finally { Pop-Location }

# 7. Verify
foreach ($u in @("https://raw.githubusercontent.com/$Repo/main/pluginmaster.json", $dl)) {
    $code = (curl.exe -s -o NUL -L -w '%{http_code}' $u)
    Write-Host "$code  $u"
}
Write-Host "Done: $Version"