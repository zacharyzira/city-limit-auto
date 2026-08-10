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
# Local-only cache of "what did this unit's photo folder look like last time
# we processed it" — lets a run skip re-decoding/re-encoding photos that
# haven't changed. Never committed (see .gitignore); safe to delete anytime,
# it just costs one slow full-reprocess run to rebuild.
$PhotoCachePath = Join-Path $ScriptDir "photo-cache.json"

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
    #
    # A folder's photos only get (re-)decoded when something about that
    # folder actually changed since the last run — new file, removed file,
    # or a file replaced. Untouched folders are skipped entirely, so an
    # hourly run costs almost nothing once a unit's photos have settled.
    $photoCache = @{}
    if (Test-Path $PhotoCachePath) {
        try {
            $raw = Get-Content $PhotoCachePath -Raw | ConvertFrom-Json
            $raw.PSObject.Properties | ForEach-Object { $photoCache[$_.Name] = $_.Value }
        } catch {
            Write-Log "WARNING: photo-cache.json unreadable, rebuilding from scratch: $($_.Exception.Message)"
        }
    }
    $photoCacheChanged = $false
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

    # Staff name photo folders either as the full VIN (e.g. "1JJV532D4EL814819")
    # or, more commonly in practice, the last 5 characters of the VIN followed
    # by whatever notes help a human recognize the unit (make, size, etc — e.g.
    # "04127 vangrd 12'"). Match either convention; ignore anything after the
    # last-5 prefix since staff notation there isn't consistent.
    function Find-PhotoFolder($vin) {
        if ([string]::IsNullOrWhiteSpace($vin) -or -not (Test-Path $PhotosSourceRoot)) { return $null }
        $last5 = $vin.Substring($vin.Length - 5)
        $candidates = @(Get-ChildItem $PhotosSourceRoot -Directory | Where-Object {
            $_.Name -eq $vin -or $_.Name -like "$last5*"
        })
        if ($candidates.Count -eq 0) { return $null }
        if ($candidates.Count -gt 1) {
            Write-Log "WARNING: multiple photo folders match VIN suffix '$last5' (VIN $vin) — using '$($candidates[0].Name)'. All matches: $($candidates.Name -join ', ')"
        }
        return $candidates[0].FullName
    }

    function Get-UnitPhotos($vin, $unitNumber) {
        $srcFolder = Find-PhotoFolder $vin
        if (-not $srcFolder) { return @() }

        $files = @(Get-ChildItem $srcFolder -File | Where-Object { $_.Extension -match '(?i)^\.(jpe?g|png|heic|heif)$' } | Sort-Object Name)
        if ($files.Count -eq 0) { return @() }

        # Signature = name + size + modified-time for every source file. If
        # this matches what we saw last time AND the published output is
        # still there, the folder is untouched — skip straight to reusing
        # the existing paths instead of re-decoding anything.
        $signature = ($files | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
        $destFolder = Join-Path $PhotosPublicRoot $unitNumber
        $expectedCount = $files.Count

        if ($photoCache.ContainsKey($vin) -and $photoCache[$vin] -eq $signature -and (Test-Path $destFolder)) {
            # Numeric sort, not alphabetical — filenames are "1.jpg".."N.jpg",
            # and a plain string sort would order them 1, 10, 2, 3… which
            # doesn't match the fresh-encode path and would spuriously flag
            # a 10+-photo unit as "changed" on every subsequent run.
            $existing = @(Get-ChildItem $destFolder -File -Filter "*.jpg" | Sort-Object { [int]$_.BaseName })
            if ($existing.Count -eq $expectedCount) {
                return @($existing | ForEach-Object { "/assets/photos/$unitNumber/$($_.Name)" })
            }
        }

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

        $photoCache[$vin] = $signature
        $script:photoCacheChanged = $true
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

    # Persist the photo-folder cache so next run can skip untouched units.
    # Only rewritten when something actually changed, same spirit as the
    # inventory JSON itself.
    if ($photoCacheChanged) {
        $photoCache | ConvertTo-Json -Depth 3 | Set-Content -Path $PhotoCachePath -Encoding UTF8
        Write-Log "Updated photo-cache.json ($($photoCache.Count) unit(s) tracked)."
    }

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
            # Scoped to just the paths this script manages — a repo-wide
            # `git status` would also pick up unrelated in-progress edits
            # (e.g. someone editing this very script) and trigger a bogus
            # commit attempt with nothing actually staged.
            $changes = git status --porcelain -- "assets/inventory.json" "assets/photos"
            if ($changes) {
                git commit -m "Auto-sync inventory ($($publicItems.Count) available, $photoCount photo(s))" | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    git push | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "Committed and pushed inventory update."
                    } else {
                        Write-Log "WARNING: commit succeeded but push failed (exit $LASTEXITCODE) — will retry next run."
                    }
                } else {
                    Write-Log "WARNING: git commit failed (exit $LASTEXITCODE) even though changes were detected — nothing pushed this run."
                }
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

