# =========================================================
# City Limit Auto — Inventory Sync
#
# Runs on the office server (10.20.31.50). Logs into the sales
# system's API, pulls Available inventory, strips it down to only
# public-safe fields, and writes assets/inventory.json. If this
# folder is a git repo with a remote configured, it also commits
# and pushes so the live site (via Netlify/etc. auto-deploy) picks
# up the change within a minute or two.
#
# Setup:
#   1. Copy sync.env.example to sync.env in this same folder and
#      fill in real credentials. sync.env is gitignored — never
#      commit it.
#   2. Test manually:  powershell -File sync-inventory.ps1
#   3. Schedule it — see README.md for the Task Scheduler command.
# =========================================================

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationCore

$ApiBase         = "http://10.20.31.50"
$ScriptDir       = $PSScriptRoot
$RepoRoot        = Split-Path $ScriptDir -Parent
$CredsPath       = Join-Path $ScriptDir "sync.env"
$OutputPath      = Join-Path $RepoRoot "assets\inventory.json"
$LogPath         = Join-Path $ScriptDir "sync.log"
$PhotosSourceRoot = "C:\Users\ZachZira\OneDrive - Flex Fleet Trailer Leasing (1)\City Limit Auto Shared\Trailer Photos"
$PhotosPublicRoot = Join-Path $RepoRoot "assets\photos"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $LogPath -Value $line
}

try {
    # ---- Load credentials ----
    if (-not (Test-Path $CredsPath)) {
        Write-Log "ERROR: sync.env not found. Copy sync.env.example to sync.env and fill it in."
        exit 1
    }
    $creds = @{}
    Get-Content $CredsPath | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_]+)\s*=\s*(.*)$') { $creds[$matches[1]] = $matches[2].Trim() }
    }
    if (-not $creds.CL_IDENTIFIER -or -not $creds.CL_PASSWORD) {
        Write-Log "ERROR: sync.env is missing CL_IDENTIFIER or CL_PASSWORD."
        exit 1
    }

    # ---- Log in ----
    $loginBody = @{ identifier = $creds.CL_IDENTIFIER; password = $creds.CL_PASSWORD } | ConvertTo-Json
    $loginRes = Invoke-RestMethod -Uri "$ApiBase/api/auth/login" -Method Post -Body $loginBody -ContentType "application/json"
    $token = $loginRes.token
    if (-not $token) { throw "Login succeeded but no token was returned." }

    # ---- Fetch inventory ----
    # The API wraps the array: { "units": [ {...}, {...} ] }, not a bare array.
    $headers = @{ Authorization = "Bearer $token" }
    $items = (Invoke-RestMethod -Uri "$ApiBase/api/inventory" -Headers $headers -Method Get).units

    # ---- Filter to public statuses + map to public-safe fields only ----
    # NEVER pass through cost, vendor/pickup info, notes, or title status —
    # those are internal-only fields on the source record.
    # "Down" means sellable but not yet mechanic-inspected — still publish it.
    $publicStatuses = @("Available", "Down")

    function ToTitleCase($s) {
        if ([string]::IsNullOrWhiteSpace($s)) { return $s }
        (Get-Culture).TextInfo.ToTitleCase($s.ToLower())
    }

    # ---- Photo pipeline ----
    # Staff drop trailer photos into the shared OneDrive folder, one
    # subfolder per VIN (the one identifier that never changes). This decodes
    # + rotates + resizes each photo (via WIC, which — unlike legacy
    # System.Drawing — can actually read iPhone HEIC files) and republishes
    # it under the public unit number's own photo folder instead (VIN is
    # only used here to find the right source folder — the published photo
    # paths use the unit number, even though VIN itself is also fine to show
    # elsewhere on the listing, same as any used-vehicle site).
    function Convert-PhotoToWebJpg($srcPath, $destPath, $maxWidth = 1600, $quality = 82) {
        $uri = New-Object System.Uri($srcPath)
        $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create($uri, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frame = $decoder.Frames[0]

        $orientation = 1
        try {
            if ($frame.Metadata -and $frame.Metadata.ContainsQuery("System.Photo.Orientation")) {
                $orientation = [int]$frame.Metadata.GetQuery("System.Photo.Orientation")
            }
        } catch {}
        $rotate = switch ($orientation) { 3 { 180 } 6 { 90 } 8 { 270 } default { 0 } }

        $source = $frame
        if ($rotate -ne 0) {
            $rb = New-Object System.Windows.Media.Imaging.TransformedBitmap
            $rb.BeginInit(); $rb.Source = $frame; $rb.Transform = New-Object System.Windows.Media.RotateTransform($rotate); $rb.EndInit()
            $source = $rb
        }

        if ($source.PixelWidth -gt $maxWidth) {
            $scale = $maxWidth / $source.PixelWidth
            $sb = New-Object System.Windows.Media.Imaging.TransformedBitmap
            $sb.BeginInit(); $sb.Source = $source; $sb.Transform = New-Object System.Windows.Media.ScaleTransform($scale, $scale); $sb.EndInit()
            $source = $sb
        }

        $encoder = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
        $encoder.QualityLevel = $quality
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($source))
        $stream = [System.IO.File]::Open($destPath, [System.IO.FileMode]::Create)
        try { $encoder.Save($stream) } finally { $stream.Close() }
    }

    function Get-UnitPhotos($vin, $unitNumber) {
        if ([string]::IsNullOrWhiteSpace($vin)) { return @() }
        $srcFolder = Join-Path $PhotosSourceRoot $vin
        if (-not (Test-Path $srcFolder)) { return @() }

        $files = @(Get-ChildItem $srcFolder -File | Where-Object { $_.Extension -match '(?i)^\.(jpe?g|png|heic|heif)$' } | Sort-Object Name)
        if ($files.Count -eq 0) { return @() }

        $destFolder = Join-Path $PhotosPublicRoot $unitNumber
        if (Test-Path $destFolder) { [System.IO.Directory]::Delete($destFolder, $true) }
        New-Item -ItemType Directory -Force -Path $destFolder | Out-Null

        $publicPaths = @()
        $i = 1
        foreach ($f in $files) {
            $destName = "$i.jpg"
            $destPath = Join-Path $destFolder $destName
            try {
                Convert-PhotoToWebJpg $f.FullName $destPath
                # Root-absolute so /es/ pages resolve photos correctly too.
                $publicPaths += "/assets/photos/$unitNumber/$destName"
                $i++
            } catch {
                Write-Log "WARNING: couldn't convert photo '$($f.Name)' for unit $unitNumber ($vin): $($_.Exception.Message)"
            }
        }
        return @($publicPaths)
    }

    # Rental-fleet units can carry status "Available" too, but they aren't
    # for-sale inventory — exclude anything flagged rental:true.
    $publicItems = @($items | Where-Object { $publicStatuses -contains $_.status -and -not $_.rental } | ForEach-Object {
        [ordered]@{
            unit   = $_.unit_number
            vin    = $_.vin
            title  = "$($_.length)' $($_.model) — $(ToTitleCase $_.make)"
            # Published separately (not just inside `title`) so the site can
            # build a reliable Make filter without parsing strings.
            make   = ToTitleCase $_.make
            type   = $_.model
            year   = [int]$_.year
            length = "$($_.length)'"
            price  = [int]$_.price
            suspension = ToTitleCase $_.suspension
            # "Down" is an internal-only distinction (sellable, just not yet
            # mechanic-inspected) — buyers should just see "Available".
            status = if ($_.status -eq "Down") { "Available" } else { $_.status }
            # @(...) wrapper matters: PowerShell collapses an empty-array
            # return value to $null across a function boundary, which would
            # otherwise serialize as "photos": {} instead of "photos": [].
            photos = @(Get-UnitPhotos -vin $_.vin -unitNumber $_.unit_number)
        }
    })

    # ---- Write JSON ----
    # Windows PowerShell 5.1's ConvertTo-Json unwraps a single-item array when
    # piped, producing a bare {...} object instead of [{...}]. Passing via
    # -InputObject (not the pipeline) avoids that; the Count -eq 0 case is
    # handled explicitly since ConvertTo-Json on an empty array returns "".
    $json = if ($publicItems.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject $publicItems -Depth 5 }
    Set-Content -Path $OutputPath -Value $json -Encoding UTF8
    $photoCount = ($publicItems | ForEach-Object { $_.photos.Count } | Measure-Object -Sum).Sum
    # @(...) wrapper matters here too: a single match would otherwise come
    # back unwrapped, and .Count on a lone hashtable means "number of keys",
    # not "number of matches".
    $unitsWithPhotos = @($publicItems | Where-Object { $_.photos.Count -gt 0 }).Count
    Write-Log "Wrote $($publicItems.Count) available unit(s) to $OutputPath ($photoCount photo(s) across $unitsWithPhotos unit(s))"

    # ---- Publish via git, if this is a repo with a remote ----
    # Native git errors (e.g. "not a git repository") must not become
    # terminating errors here, or a not-yet-deployed site would fail the
    # whole sync even though inventory.json was written successfully above.
    Push-Location $RepoRoot
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $isRepo = (git rev-parse --is-inside-work-tree 2>$null)
        if ($LASTEXITCODE -eq 0 -and $isRepo -eq "true") {
            git add "assets/inventory.json" "assets/photos" | Out-Null
            $changes = git status --porcelain
            if ($changes) {
                git commit -m "Auto-sync inventory ($($publicItems.Count) available, $photoCount photo(s))" | Out-Null
                git push | Out-Null
                Write-Log "Committed and pushed inventory update."
            } else {
                Write-Log "No inventory changes since last sync."
            }
        } else {
            Write-Log "Not a git repo — file written locally only, nothing pushed."
        }
    } finally {
        $ErrorActionPreference = $prevEap
        Pop-Location
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}

