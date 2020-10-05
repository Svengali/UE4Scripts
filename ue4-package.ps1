[CmdletBinding()] # Fail on unknown args
param (
    [string]$src,
    [switch]$major = $false,
    [switch]$minor = $false,
    [switch]$patch = $false,
    [switch]$hotfix = $false,
    # Don't incrememnt version
    [switch]$noversionbump = $false,
    # Force move tag
    [switch]$forcetag = $false,
    # Name of variant to build (optional, uses DefaultVariants from packageconfig.json if unspecified)
    [array]$variant,
    # Testing mode; skips clean checks, tags
    [switch]$test = $false,
    # Dry-run; does nothing but report what *would* have happened
    [switch]$dryrun = $false,
    [switch]$help = $false
)

. $PSScriptRoot\inc\platform.ps1
. $PSScriptRoot\inc\packageconfig.ps1
. $PSScriptRoot\inc\projectversion.ps1
. $PSScriptRoot\inc\uproject.ps1
. $PSScriptRoot\inc\ueinstall.ps1


function Write-Usage {
    Write-Output "Steve's UE4 packaging tool"
    Write-Output "Usage:"
    Write-Output "  ue4-package.ps1 [-src:sourcefolder] [-major|-minor|-patch|-hotfix] [-keepversion] [-force] [-variant=VariantName] [-test] [-dryrun]"
    Write-Output " "
    Write-Output "  -src          : Source folder (current folder if omitted), must contain buildconfig.json"
    Write-Output "  -major        : Increment major version i.e. [x++].0.0.0"
    Write-Output "  -minor        : Increment minor version i.e. x.[x++].0.0"
    Write-Output "  -patch        : Increment patch version i.e. x.x.[x++].0 (default)"
    Write-Output "  -hotfix       : Increment hotfix version i.e. x.x.x.[x++]"
    Write-Output "  -keepversion  : Keep current version number, doesn't tag unless -forcetag"
    Write-Output "  -forcetag     : Move any existing version tag"
    Write-Output "  -variant=Name : Build only a named variant instead of DefaultVariants from packageconfig.json"
    Write-Output "  -test         : Testing mode, separate builds, allow dirty working copy"
    Write-Output "  -dryrun       : Don't perform any actual actions, just report on what you would do"
    Write-Output "  -help         : Print this help"
}

if ($src.Length -eq 0) {
    $src = "."
    Write-Verbose "-src not specified, assuming current directory"
}

$ErrorActionPreference = "Stop"

if ($help) {
    Write-Usage
    Exit 0
}

Write-Output "~-~-~ UE4 Packaging Helper Start ~-~-~"

if ($test) {
    Write-Output "TEST MODE: No tagging, version bumping"
}

if (([bool]$major + [bool]$minor + [bool]$patch + [bool]$hotfix) -gt 1) {
    Write-Output "ERROR: Can't set more than one of major/minor/patch/hotfix at the same time!"
    Print-Usage
    Exit 5
}
if (($major -or $minor -or $patch -or $hotfix) -and $keepversion) {
    Write-Output  "ERROR: Can't set keepversion at the same time as major/minor/patch/hotfix!"
    Print-Usage
    Exit 5
}

# Detect Git
if ($src -ne ".") { Push-Location $src }
$isGit = Test-Path ".git"
if ($src -ne ".") { Pop-Location }

# Check working copy is clean (Git only)
if (-not $test -and $isGit) {
    if ($src -ne ".") { Push-Location $src }

    if (Test-Path ".git") {
        git diff --no-patch --exit-code
        if ($LASTEXITCODE -ne 0) {
            Write-Output "Working copy is not clean (unstaged changes)"
            if ($dryrun) {
                Write-Output "dryrun: Continuing but this will fail without -dryrun"
            } else {
                Exit $LASTEXITCODE
            }
        }
        git diff --no-patch --cached --exit-code
        if ($LASTEXITCODE -ne 0) {
            Write-Output "Working copy is not clean (staged changes)"
            if ($dryrun) {
                Write-Output "dryrun: Continuing but this will fail without -dryrun"
            } else {
                Exit $LASTEXITCODE
            }
        }
    }
    if ($src -ne ".") { Pop-Location }
}


try {
    # Import config & project settings
    $config = Read-Package-Config -srcfolder:$src
    $projfile = Get-Uproject-Filename -srcfolder:$src -config:$config
    $proj = Read-Uproject $projfile
    $ueVersion = Get-UE-Version $proj
    $ueinstall = Get-UE-Install $ueVersion
    $exeSuffix = ""
    $batchSuffix = ".sh"
    if ($IsWindows) {
        $exeSuffix = ".exe"
    }
    if ($IsWindows) {
        $batchSuffix = ".bat"
    }

    Write-Output ""
    Write-Output "Project file : $projfile"
    Write-Output "UE Version   : $ueVersion"
    Write-Output "UE Install   : $ueinstall"
    Write-Output ""
    Write-Output "Package configuration:"
    Write-Output $config


    if (([bool]$major + [bool]$minor + [bool]$patch + [bool]$hotfix) -eq 0) {
        $patch = $true
    }
    $versionNumber = $null
    if ($keepversion) {
        $versionNumber = Get-Project-Version $src
    } else {
        # Bump up version, passthrough options
        try {
            $versionNumber = Increment-Project-Version -srcfolder:$src -major:$major -minor:$minor -patch:$patch -hotfix:$hotfix -dryrun:$dryrun
            if (-not $dryrun -and $isGit) {
                if ($src -ne ".") { Push-Location $src }

                $verIniFile = Get-Project-Version-Ini-Filename $src
                git add "$($verIniFile)"
                if ($LASTEXITCODE -ne 0) { Exit $LASTEXITCODE }
                git commit -m "Version bump to $versionNumber"
                if ($LASTEXITCODE -ne 0) { Exit $LASTEXITCODE }

                if ($src -ne ".") { Pop-Location }
            }
        }
        catch {
            Write-Output $_.Exception.Message
            Exit 6
        }
    }
    # Keep test builds separate
    if ($test) {
        $versionNumber = "$versionNumber-test"
    }
    Write-Output "Next version will be: $versionNumber"

    # For tagging release
    # We only need to grab the main version once
    $forcearg = ""
    if ($forcetag) {
        $forcearg = "-f"
    }
    if (-not $test -and -not $dryrun) {
        if ($src -ne ".") { Push-Location $src }
        git tag $forcearg -a $versionNumber -m "Automated release tag"
        if ($LASTEXITCODE -ne 0) { Exit $LASTEXITCODE }
        if ($src -ne ".") { Pop-Location }
    }

    $ueEditorCmd = Join-Path $ueinstall "Engine/Binaries/Win64/UE4Editor-Cmd$exeSuffix"
    $runUAT = Join-Path $ueinstall "Engine/Build/BatchFiles/RunUAT$batchSuffix"


    foreach ($variant in $config.Variants) {

        $outDir = Join-Path $config.OutputDir "$versionNumber/$($variant.Name)"


        $argList = [System.Collections.ArrayList]@()
        $argList.Add("-ScriptsForProject=`"$projfile`"")
        $argList.Add("BuildCookRun")
        $argList.Add("-nocompileeditor")
        #$argList.Add("-installed") # don't think we need this, seems to be detected
        $argList.Add("-nop4")
        $argList.Add("-project=`"$projfile`"")
        $argList.Add("-cook")
        $argList.Add("-stage")
        $argList.Add("-archive")
        $argList.Add("-archivedirectory=`"$($outDir)`"")
        $argList.Add("-package")
        $argList.Add("-ue4exe=`"$ueEditorCmd`"")
        $argList.Add("-pak")
        $argList.Add("-prereqs")
        $argList.Add("-nodebuginfo")
        $argList.Add("-build")
        $argList.Add("-target=$($config.Target)")
        $argList.Add("-clientconfig=$($variant.Configuration)")
        $argList.Add("-targetplatform=$($variant.Platform)")
        $argList.Add("-utf8output")


        if ($dryrun) {
            Write-Output "Would have run:"
            Write-Output "> $runUAT $($argList -join " ")"



        } else {

        }
    }

}
catch {
    Write-Output $_.Exception.Message
    Exit 9
}




Write-Output "~-~-~ UE4 Packaging Helper Completed OK ~-~-~"