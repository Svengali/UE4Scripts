[CmdletBinding()] # Fail on unknown args
param (
    [string]$mode,
    [string]$root,
    [string]$src,
    [switch]$prune = $false,
    [switch]$force = $false,
    [switch]$nocloseeditor = $false,
    [switch]$dryrun = $false,
    [switch]$help = $false
)

function Print-Usage {
    Write-Output "Steve's UE4 Map BuiltData Sync Tool"
    Write-Output "  Avoid storing Map_BuiltData.uasset files in source control, sync them directly instead"
    Write-Output "Usage:"
    Write-Output "  ue4-datasync.ps1 [-mode:]<push|pull> [[-path:]syncpath] [Options]"
    Write-Output " "
    Write-Output "  -mode        : Whether to push or pull the built data from your filesystem"
    Write-Output "  -root        : Root folder to sync files to/from. Project name will be appended to this path."
    Write-Output "               : Can be blank if specified in UE4SYNCROOT"
    Write-Output "  -src         : Source folder (current folder if omitted)"
    Write-Output "               : (should be root of project)"
    Write-Output "  -prune       : Clean up versions of the data older than the latest"
    Write-Output "  -force       : Copy ALL BuiltData files regardless of size/timestamp checks"
    Write-Output "  -nocloseeditor : Don't close UE4 editor (this will prevent download of updated files)"
    Write-Output "  -dryrun      : Don't perform any actual actions, just report on what you would do"
    Write-Output "  -help        : Print this help"
    Write-Output " "
    Write-Output "Environment Variables:"
    Write-Output "  UE4SYNCROOT  : Root path to sync data. Subfolders for each project name."
    Write-Output "  UE4INSTALL   : Use a specific UE4 install."
    Write-Output "               : Default is to find one based on project version, under UE4ROOT"
    Write-Output "  UE4ROOT      : Parent folder of all binary UE4 installs (detects version). "
    Write-Output "               : Default C:\Program Files\Epic Games"
    Write-Output " "

}

. $PSScriptRoot\inc\ueeditor.ps1
. $PSScriptRoot\inc\filetools.ps1

function Get-Current-Umaps {
    # Find all umaps which are tracked in git and get their LFS SHAs
    $umapsOutput = git lfs ls-files -l -I *.umap
    # Output is of the form
    # b75b42e082ffb0deeb3fc7b40b2a221ded62872a2289bf6b63e275372849447b * Content/Maps/Subfolder/MyLevel.umap
    foreach ($line in $umapsOutput) {
        if ($line -match "^([a-f0-9]+)\s+\*\s+(.+)$") {
            $oid = $matches[1]
            $filename = $matches[2].Trim()

            # returns multiple entries here
            # use property bag for convenience
            New-Object PSObject -Property @{Filename=$filename;Oid=$oid}
        }
    }
}

function Get-Builtdata-Paths {
    param (
        [object]$umap,
        [string]$syncdir
    )

    $subdir = [System.IO.Path]::GetDirectoryName($umap.Filename)
    $basename = [System.IO.Path]::GetFileNameWithoutExtension($umap.Filename)

    $localbuiltdata = Join-Path $subdir "${basename}_BuiltData.uasset"
    $remotesubdir = Join-Path $syncdir $subdir
    $remotebuiltdata = Join-Path $remotesubdir "${basename}_BuiltData_$($umap.Oid).uasset"

    return $localbuiltdata, $remotebuiltdata

}

$ErrorActionPreference = "Stop"


if ($help) {
    Print-Usage
    Exit 0
}

if ($mode -ne "push" -and $mode -ne "pull") {
    Print-Usage
    Write-Output "ERROR: Mode must be 'push' or 'pull'"
    Exit 3

}

if (-not $root) {
    $root = $Env:UE4SYNCROOT
}

if (-not $root) {
    Print-Usage
    Write-Output "ERROR: Missing '-root' argument and no UE4SYNCROOT env var"
    Exit 3
}

if (-not (Test-Path $root -PathType Container)) {
    Print-Usage
    Write-Output "ERROR: root path $root does not exist"
    Exit 3
}

# confirm that umap files are tracked in LFS so SHAs are already there
$lfsTrackOutput = git lfs track
if (!$?) {
    Write-Output "ERROR: failed to call 'git lfs track'"
    Exit 5
}
$umapsOK = $false
foreach ($line in $lfsTrackOutput) {
    if ($line -match "^\s+\*\.umap\s+.*$") {
        $umapsOK = $true
        break
    }
}
if (-not $umapsOK) {
    Write-Output "ERROR: .umap files are not tracked in LFS, cannot continue"
    Exit 5
}

# Check no changes, ONLY to .umap files
$statusOutput = git status --porcelain *.umap
foreach ($line in $statusOutput) {
    if ($line -like "*.umap*") {
        Write-Output "Uncommitted changes to .umap file(s) detected"
        if ($dryrun) {
            Write-Output "dryrun: Continuing but this will fail without -dryrun"
            break
        } else {
            Write-Output "Cannot continue"
            Exit $LASTEXITCODE
        }
    
    }
}

$result = 0

try {
    if ($src -ne ".") { Push-Location $src }

    Write-Output "-- Sync process starting --"

    # Locate UE4 project file
    $uprojfile = Get-ChildItem *.uproject | Select-Object -expand Name
    if (-not $uprojfile) {
        throw "No Unreal project file found in $(Get-Location)! Aborting."
    }
    if ($uprojfile -is [array]) {
        throw "Multiple Unreal project files found in $(Get-Location)! Aborting."
    }

    # In PS 6.0+ we could use Split-Path -LeafBase but let's stick with built-in PS 5.1
    $uprojname = [System.IO.Path]::GetFileNameWithoutExtension($uprojfile)
    if ($dryrun) {
        Write-Output "Would sync $uprojname"
    } else {
        Write-Output "Syncing $uprojname"
    }

    # Close UE4 as early as possible
    if (-not $nocloseeditor) {
        # Check if UE4 is running, if so try to shut it gracefully
        Close-UE-Editor $uprojname $dryrun
    }

    # Create project sync dir if necessary
    $syncdir = Join-Path $root $uprojname
    New-Item -ItemType Directory $syncdir -Force > $null
    Write-Output "Sync project folder: $syncdir"

    $umaps = Get-Current-Umaps
    foreach ($umap in $umaps) {

        $filename = $umap.Filename
        $oid = $umap.Oid

        Write-Verbose "Checking $filename ($oid)"

        $localbuiltdata, $remotebuiltdata = Get-Builtdata-Paths $umap $syncdir

        $same = Compare-Files-Quick $localbuiltdata $remotebuiltdata

        if ($same -and -not $force) {
            Write-Verbose "Skipping $filename, matches"
            continue
        }

        if ($mode -eq "push") {
            Write-Verbose "$localbuiltdata  ->  $remotebuiltdata"

            # In push mode, we only upload our builtdata if there is no existing
            # entry for that OID by default (safest). Or, if forced to do so
            if (-not (Test-Path $localbuiltdata -PathType Leaf)) {
                Write-Warning "Skipping $filename, local file missing"
                continue
            }

            if ($dryrun) {
                Write-Output "Would have pushed: $filename ($oid)"
            } else {
                Write-Output "Push: $filename ($oid)"

                New-Item -ItemType Directory [System.IO.Path]::GetDirectoryName($remotebuiltdata) -Force > $null
                Copy-Item $localbuiltdata $remotebuiltdata    
            }

        } else {
            Write-Verbose("$remotebuiltdata  ->  $localbuiltdata")
            # In pull mode, we always pull if not same, or forced (checked already above)

            if (-not (Test-Path $remotebuiltdata -PathType Leaf)) {
                Write-Warning "Skipping $filename, remote file missing"
                continue
            }

            if ($dryrun) {
                Write-Output "Would have pulled: $filename ($oid)"
            } else {
                Write-Output "Pull: $filename ($oid)"
                New-Item -ItemType Directory $subdir -Force > $null
                Copy-Item $remotebuiltdata $localbuiltdata    
            }

        }
    }

    if ($prune) {
        # Only keep latest for each map file
        # We derive that from the current oids, which we always keep, and date

        
        Write-Output "Pruning..."
        foreach ($umap in $umaps) {
            # We want to delete any files for this map which have a different OID
            # and which are older (to prevent deletion if you're behind)

            # Get our current one
            $localfile, $remotefile = Get-Builtdata-Paths $umap $syncdir

            $remotedir = [System.IO.Path]::GetDirectoryName($remotefile)
            $basename = [System.IO.Path]::GetFileNameWithoutExtension($umap.Filename)
            $matchingremotefiles = Get-ChildItem $remotedir -filter "${basename}_BuiltData_*.uasset" -ErrorAction Continue

            if (-not (Test-Path $remotefile -PathType Leaf)) {
                Write-Verbose "Skipping pruning old versions for $($umap.Filename) since our version isn't on remote"
                continue
            }
            $ourfileprops = Get-ItemProperty -Path $remotefile

            foreach ($file in $matchingremotefiles) {
                Write-Verbose "Considering $($file.Name) for deletion"
                if ($file.Name -notlike "*$($umap.Oid).uasset") {
                    # This is not our OID, check date
                    if ($file.LastWriteTime -le $ourfileprops.LastWriteTime) {
                        if ($dryrun) {
                            Write-Output "Would have pruned $($file.FullName)"
                        } else {
                            Write-Output "Pruning $($file.FullName)"
                            Remove-Item -Path $file.FullName -Force
                        }
                    } else {
                        Write-Verbose "Not pruning $($file.Name), date/time is later than ours"
                    }
                } else {
                    Write-Verbose "Not pruning $($file.Name), this is our latest"
                }
            }

        }

    }
    

    

    Write-Output "-- Sync process finished OK --"


} catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    $result = 9
} finally {
    if ($src -ne ".") { Pop-Location }
}


Exit $result