<#
.SYNOPSIS
    Compiles all Contoso apps (in dependency order) without a BC container.
.DESCRIPTION
    Uses BcContainerHelper Run-AlPipeline with a compiler folder:
      - downloads BC artifacts (cached under C:\bcartifacts.cache)
      - resolves build order from app.json dependencies
      - compiles apps + test apps with CodeCop/UICop
      - writes .app files to <OutputFolder>\Apps and \TestApps
    Same script runs in GitHub Actions and on a dev machine.
.EXAMPLE
    ./scripts/Invoke-CIBuild.ps1 -BcVersion 25 -BuildNumber 42
#>
[CmdletBinding()]
param(
    [string]$BaseFolder = (Split-Path -Path $PSScriptRoot -Parent),
    [string]$BcVersion = '25',
    [string]$Country = 'w1',
    [int]$BuildNumber = 0,
    [string]$OutputFolder = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'output')
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name BcContainerHelper)) {
    Install-Module BcContainerHelper -Force -AllowClobber -Scope CurrentUser
}
Import-Module BcContainerHelper -DisableNameChecking

$artifactUrl = Get-BCArtifactUrl -type Sandbox -country $Country -version $BcVersion -select Latest
if (-not $artifactUrl) { throw "No BC artifact found for version '$BcVersion' / country '$Country'." }
Write-Host "Using artifact: $artifactUrl"

$appDirs = Get-ChildItem -Path $BaseFolder -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'app.json') }
$appFolders = @($appDirs | Where-Object { $_.Name -notlike '*.Test' } | ForEach-Object Name)
$testFolders = @($appDirs | Where-Object { $_.Name -like '*.Test' }    | ForEach-Object Name)

Write-Host "App folders : $($appFolders -join ', ')"
Write-Host "Test folders: $($testFolders -join ', ')"

if (Test-Path $OutputFolder) { Remove-Item $OutputFolder -Recurse -Force }

# Workaround: the pipeline does not copy the Library Assert symbol into the package
# cache when compiling test apps (AL1022). Copy it ourselves before each test app compile.
$packagesFolder = Join-Path $BaseFolder '.packages'

$preCompileApp = {
    Param([string] $appType, [ref] $compilationParams)

    Write-Host "PreCompileApp: fired. appType='$appType'"
    if ($compilationParams -and $compilationParams.Value -is [System.Collections.IDictionary]) {
        Write-Host "PreCompileApp: params = $($compilationParams.Value.Keys -join ', ')"
    }

    if ($appType -ne 'testApp') { return }

    $p = $compilationParams.Value

    # Where alc.exe looks for symbols
    $target = $packagesFolder
    if ($p -is [System.Collections.IDictionary] -and $p['appSymbolsFolder']) {
        $target = $p['appSymbolsFolder']
    }
    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

    if (Get-ChildItem -Path $target -Filter 'Microsoft_Library Assert*.app' -ErrorAction SilentlyContinue) {
        Write-Host "PreCompileApp: Library Assert already in $target"
        return
    }

    # Candidate places to find the symbol
    $searchRoots = @()
    if ($p -is [System.Collections.IDictionary] -and $p['CompilerFolder']) {
        $searchRoots += (Join-Path $p['CompilerFolder'] 'symbols')
    }
    $compilerRoot = 'C:\ProgramData\BcContainerHelper\compiler'
    if (Test-Path $compilerRoot) {
        $searchRoots += Get-ChildItem $compilerRoot -Directory |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { Join-Path $_.FullName 'symbols' }
    }
    $searchRoots += 'C:\bcartifacts.cache'

    $found = $null
    foreach ($root in $searchRoots) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem -Path $root -Filter 'Microsoft_Library Assert*.app' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) { break }
    }

    if ($found) {
        Write-Host "PreCompileApp: copying '$($found.FullName)' to '$target'"
        Copy-Item -Path $found.FullName -Destination $target -Force
    }
    else {
        Write-Host "PreCompileApp: Library Assert symbol NOT FOUND. Searched: $($searchRoots -join '; ')"
    }
}.GetNewClosure()

$pipelineParams = @{
    pipelineName         = 'Contoso-CI'
    baseFolder           = $BaseFolder
    appFolders           = $appFolders
    testFolders          = $testFolders
    artifact             = $artifactUrl
    useCompilerFolder    = $true
    doNotPublishApps     = $true
    doNotRunTests        = $true
    installTestFramework = $true
    installTestLibraries = $true
    enableCodeCop        = $true
    enableUICop          = $true
    failOn               = 'error'
    appBuild             = $BuildNumber
    appRevision          = 0
    buildArtifactFolder  = $OutputFolder
    PreCompileApp        = $preCompileApp
}
if ($env:GITHUB_ACTIONS -eq 'true') { $pipelineParams.gitHubActions = $true }

Run-AlPipeline @pipelineParams

# Job summary for GitHub Actions
$apps = Get-ChildItem -Path $OutputFolder -Filter '*.app' -Recurse
if (-not $apps) { throw "Build produced no .app files." }

if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @('## Built apps', '', '| File | Type | Size (KB) |', '|---|---|---|')
    foreach ($a in $apps) {
        $lines += "| $($a.Name) | $($a.Directory.Name) | $([math]::Round($a.Length / 1KB, 1)) |"
    }
    $lines += '', "Artifact: ``$artifactUrl``"
    $lines | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

$apps | Select-Object Name, @{n = 'Folder'; e = { $_.Directory.Name } } | Format-Table -AutoSize