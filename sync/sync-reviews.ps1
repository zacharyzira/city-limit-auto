# =========================================================
# City Limit Auto — Google Reviews Sync
#
# Pulls your business's rating + up to 5 reviews from the Google
# Places API and writes assets/reviews.json. If this folder is a git
# repo with a remote configured, it also commits and pushes so the
# live site picks up the change.
#
# Google's API only ever returns up to 5 reviews per place — that's a
# hard platform limit, not something this script can work around.
#
# Setup:
#   1. Copy reviews.env.example to reviews.env in this same folder and
#      fill in GOOGLE_PLACES_API_KEY and GOOGLE_PLACE_ID. reviews.env
#      is gitignored — never commit it.
#   2. Test manually:  powershell -File sync-reviews.ps1
#   3. Schedule it the same way as sync-inventory.ps1 — see README.md.
# =========================================================

$ErrorActionPreference = "Stop"

$ScriptDir  = $PSScriptRoot
$RepoRoot   = Split-Path $ScriptDir -Parent
$CredsPath  = Join-Path $ScriptDir "reviews.env"
$OutputPath = Join-Path $RepoRoot "assets\reviews.json"
$LogPath    = Join-Path $ScriptDir "reviews.log"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $LogPath -Value $line
}

try {
    # ---- Load credentials ----
    if (-not (Test-Path $CredsPath)) {
        Write-Log "ERROR: reviews.env not found. Copy reviews.env.example to reviews.env and fill it in."
        exit 1
    }
    $creds = @{}
    Get-Content $CredsPath | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_]+)\s*=\s*(.*)$') { $creds[$matches[1]] = $matches[2].Trim() }
    }
    if (-not $creds.GOOGLE_PLACES_API_KEY -or -not $creds.GOOGLE_PLACE_ID) {
        Write-Log "ERROR: reviews.env is missing GOOGLE_PLACES_API_KEY or GOOGLE_PLACE_ID."
        exit 1
    }

    # ---- Fetch place details (New Places API) ----
    $headers = @{
        "X-Goog-Api-Key"   = $creds.GOOGLE_PLACES_API_KEY
        "X-Goog-FieldMask" = "id,displayName,rating,userRatingCount,googleMapsUri,reviews"
    }
    $uri = "https://places.googleapis.com/v1/places/$($creds.GOOGLE_PLACE_ID)"
    $place = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

    # ---- Map to public-safe fields (this is all public review data anyway) ----
    $publicReviews = @($place.reviews | ForEach-Object {
        [ordered]@{
            author = $_.authorAttribution.displayName
            photo  = $_.authorAttribution.photoUri
            rating = $_.rating
            text   = $_.text.text
            time   = $_.relativePublishTimeDescription
        }
    })

    $output = [ordered]@{
        rating       = $place.rating
        reviewCount  = $place.userRatingCount
        mapsUri      = $place.googleMapsUri
        reviews      = $publicReviews
        syncedAt     = (Get-Date -Format o)
    }

    # ---- Write JSON ----
    $json = ConvertTo-Json -InputObject $output -Depth 6
    Set-Content -Path $OutputPath -Value $json -Encoding UTF8
    Write-Log "Wrote $($publicReviews.Count) review(s), rating $($place.rating) ($($place.userRatingCount) total) to $OutputPath"

    # ---- Publish via git, if this is a repo with a remote ----
    Push-Location $RepoRoot
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $isRepo = (git rev-parse --is-inside-work-tree 2>$null)
        if ($LASTEXITCODE -eq 0 -and $isRepo -eq "true") {
            git add "assets/reviews.json" | Out-Null
            $changes = git status --porcelain
            if ($changes) {
                git commit -m "Auto-sync Google reviews ($($publicReviews.Count) reviews, $($place.rating) stars)" | Out-Null
                git push | Out-Null
                Write-Log "Committed and pushed reviews update."
            } else {
                Write-Log "No review changes since last sync."
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

