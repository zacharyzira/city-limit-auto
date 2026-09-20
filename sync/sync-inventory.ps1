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
# Local-only cache of "when did this VIN first show up as Sold" — the source
# API has no sold-date field, so this is the only record of it. Lets a Sold
# unit stay published (marked Sold) for a few weeks after the sale so a link
# already sent out (e.g. to a lender financing the deal) keeps working,
# without it lingering in the site's main inventory grid forever. Never
# committed (see .gitignore); safe to delete anytime — worst case, currently
# Sold units just drop off a run early instead of finishing out their window.
$SoldCachePath = Join-Path $ScriptDir "sold-cache.json"
$SoldRetentionDays = 21

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $LogPath -Value $line
}

# Keep sync.log from growing forever — it's appended to on every run
# (hourly, business hours), so without a cap it'd accumulate indefinitely.
function Trim-Log($maxLines = 500) {
    if (-not (Test-Path $LogPath)) { return }
    $lines = @(Get-Content -Path $LogPath)
    if ($lines.Count -gt $maxLines) {
        $lines | Select-Object -Last $maxLines | Set-Content -Path $LogPath -Encoding UTF8
    }
}
Trim-Log

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
    # "Sold" is also published, but only for a limited window — see the sold
    # cache below — so a direct link (e.g. sent to a lender) stays alive for
    # a while after the sale without sold units lingering on the site forever.
    # "Pending Sale" (deal in progress, not yet final) is always published —
    # no retention window, since it should just track whatever the source
    # system currently says; it naturally becomes "Sold" or reverts to
    # "Available" on its own once the deal resolves.
    $publicStatuses = @("Available", "Down", "Sold", "Pending Sale")

    # ---- Sold-date tracking ----
    # The source API has no "date sold" field, so track it ourselves: the
    # first run that sees a VIN as Sold records the current time. If a unit's
    # status later moves off Sold (deal fell through, relisted, etc.) its
    # tracked date is cleared, so a later sale starts the window fresh.
    $nowUtc = [DateTime]::UtcNow
    $soldCache = @{}
    if (Test-Path $SoldCachePath) {
        try {
            $raw = Get-Content $SoldCachePath -Raw | ConvertFrom-Json
            $raw.PSObject.Properties | ForEach-Object { $soldCache[$_.Name] = $_.Value }
        } catch {
            Write-Log "WARNING: sold-cache.json unreadable, rebuilding from scratch: $($_.Exception.Message)"
        }
    }
    $soldCacheChanged = $false

    foreach ($item in $items) {
        if ([string]::IsNullOrWhiteSpace($item.vin)) { continue }
        if ($item.status -eq "Sold") {
            if (-not $soldCache.ContainsKey($item.vin)) {
                $soldCache[$item.vin] = $nowUtc.ToString("o")
                $soldCacheChanged = $true
            }
        } elseif ($soldCache.ContainsKey($item.vin)) {
            $soldCache.Remove($item.vin)
            $soldCacheChanged = $true
        }
    }

    function IsRecentlySold($vin) {
        if (-not $soldCache.ContainsKey($vin)) { return $false }
        try {
            $soldAt = [DateTime]::Parse($soldCache[$vin], $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            return ($nowUtc - $soldAt).TotalDays -le $SoldRetentionDays
        } catch {
            return $false
        }
    }

    # Drop anything past the retention window from the cache so it doesn't
    # grow forever — it'll just get re-added if the unit is ever sold again.
    $staleVins = @($soldCache.Keys | Where-Object { -not (IsRecentlySold $_) })
    foreach ($vin in $staleVins) {
        $soldCache.Remove($vin)
        $soldCacheChanged = $true
    }

    function ToTitleCase($s) {
        if ([string]::IsNullOrWhiteSpace($s)) { return $s }
        (Get-Culture).TextInfo.ToTitleCase($s.ToLower())
    }

    # Builds the URL slug for a unit's individual listing page, e.g.
    # "2012-vanguard-53ft-dry-van-plate-ctlz038853". The raw unit number is
    # ALWAYS appended last and is the only piece guaranteeing uniqueness —
    # make/type/year can theoretically repeat or be blank (some older units
    # have an empty type), the unit number never does. Computed once here and
    # written into inventory.json as a real field so assets/site.js never has
    # to re-implement this logic — two independent slugifiers that must stay
    # byte-identical forever is a bug waiting to happen.
    function Get-Slug($Year, $Make, $Type, $Length, $Unit) {
        function Slugify($s) {
            if ([string]::IsNullOrWhiteSpace($s)) { return "" }
            ($s.ToString().ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        }
        $lengthDigits = Slugify ($Length -replace '[^0-9]', '')
        $parts = @()
        if ($Year) { $parts += "$Year" }
        $makeSlug = Slugify $Make
        if ($makeSlug) { $parts += $makeSlug }
        if ($lengthDigits) { $parts += "${lengthDigits}ft" }
        $typeSlug = Slugify $Type
        if ($typeSlug) { $parts += $typeSlug }
        $parts += (Slugify $Unit)
        return ($parts -join '-')
    }

    function Get-BadgeClass($status) {
        switch ($status) {
            "Available"    { return "badge-available" }
            "Hold"         { return "badge-hold" }
            "Pending Sale" { return "badge-pending" }
            default        { return "badge-sold" }
        }
    }

    # Builds one full HTML page for a single trailer — real, crawlable
    # content baked directly into the markup (photos, price, specs, the
    # payment calculator, the inquiry form), not injected by JS after load.
    # Mirrors openLightbox()'s generated markup in assets/site.js (same
    # classes/ids, so the existing wireCalculator()/wireForm() functions work
    # against it unchanged), just pre-rendered and permanently visible — the
    # swipe-up collapsed sheet only exists to solve "not enough room on a
    # mobile modal," which doesn't apply to a page with its own screen.
    function New-UnitPageHtml($item, $lang) {
        $isEs = $lang -eq "es"

        if ($isEs) {
            $L = @{
                skip = "Ir al contenido"; home = "Inicio"; inventoryNav = "Inventario"; repairs = "Reparaciones"
                financingNav = "Financiamiento"; about = "Nosotros"; contact = "Contacto"; getQuote = "Cotización"
                openMenu = "Abrir menú"; brandTag = "Distribuidor con Licencia"; logoAlt = "Logotipo de City Limit Auto"
                hours1 = "Lun–Vie: 8am – 5pm"; hours2 = "Sáb–Dom: Cerrado"
                licensedDealer = "Distribuidor con Licencia en California — #81620"
                rightsReserved = "Todos los derechos reservados"
                unitLabel = "UNIDAD"; share = "Compartir"; inquire = "Consultar →"; apply = "Financiar →"
                soon = "Foto próximamente"
                calcHeading = "Calculadora de Pagos"; calcDown = "Enganche"; calcTerm = "Plazo"
                calcApr = "Tasa Estimada (APR)"; calcMonthly = "Pago Mensual Estimado"
                calcNote = "Solo es un estimado — su tasa y pago real dependen de la aprobación de crédito."
                formHeading = "Consultar sobre este remolque"; firstName = "Nombre"; lastName = "Apellido"
                phoneLabel = "Teléfono"; emailLabel = "Correo electrónico"; send = "Enviar consulta"
                breadcrumbHome = "Inicio"; breadcrumbInv = "Inventario"
                statusMap = @{ Available = "Disponible"; Hold = "Apartado"; Sold = "Vendido"; "Pending Sale" = "Venta Pendiente" }
                typeMap = @{ "Dry Van" = "Caja Seca" }
                suspMap = @{ Air = "Aire"; Spring = "Muelles" }
                forSaleIn = "en venta en Perris, CA"
                viewDetails = "Vea fotos, especificaciones y opciones de financiamiento en City Limit Auto."
                cta = "¿No ve lo que necesita? Recibimos unidades nuevas cada semana."
                ctaBtn = "Pídanos que lo Busquemos"
            }
        } else {
            $L = @{
                skip = "Skip to content"; home = "Home"; inventoryNav = "Inventory"; repairs = "Repairs"
                financingNav = "Financing"; about = "About"; contact = "Contact"; getQuote = "Get a Quote"
                openMenu = "Open menu"; brandTag = "Licensed CA Trailer Dealer"; logoAlt = "City Limit Auto logo"
                hours1 = "Mon–Fri: 8am – 5pm"; hours2 = "Sat–Sun: Closed"
                licensedDealer = "Licensed California Dealer — #81620"
                rightsReserved = "All rights reserved"
                unitLabel = "UNIT"; share = "Share"; inquire = "Inquire →"; apply = "Apply →"
                soon = "Photo Coming Soon"
                calcHeading = "Payment Calculator"; calcDown = "Down Payment"; calcTerm = "Term"
                calcApr = "Estimated APR"; calcMonthly = "Estimated Monthly Payment"
                calcNote = "Estimate only — your actual rate and payment depend on credit approval."
                formHeading = "Inquire About This Trailer"; firstName = "First Name"; lastName = "Last Name"
                phoneLabel = "Phone"; emailLabel = "Email"; send = "Send Inquiry"
                breadcrumbHome = "Home"; breadcrumbInv = "Inventory"
                statusMap = @{}
                typeMap = @{}
                suspMap = @{}
                forSaleIn = "for sale in Perris, CA"
                viewDetails = "View photos, specs, and financing options at City Limit Auto."
                cta = "Don't see what you need? We turn over stock weekly."
                ctaBtn = "Ask Us to Find One"
            }
        }

        $unit = $item.unit
        $make = $item.make
        $type = $item.type
        $year = $item.year
        $length = $item.length
        $price = $item.price
        $vin = $item.vin
        $status = $item.status
        $slug = $item.slug
        $photos = $item.photos

        $statusLabel = if ($L.statusMap.ContainsKey($status)) { $L.statusMap[$status] } else { $status }
        $typeLabel = if ($L.typeMap.ContainsKey($type)) { $L.typeMap[$type] } else { $type }
        $suspLabel = if ($L.suspMap.ContainsKey($item.suspension)) { $L.suspMap[$item.suspension] } else { $item.suspension }
        if ([string]::IsNullOrWhiteSpace($suspLabel)) { $suspLabel = "—" }
        $badgeClass = Get-BadgeClass $status

        $priceFormatted = "`$" + ("{0:N0}" -f $price)

        # Graceful degradation for the handful of older units with an empty
        # type — avoids a literal double-space artifact reaching a visible
        # <title>/<h1> (it already exists buried in the ItemList schema, but
        # nobody sees that; here it's the actual page title).
        $titleParts = @("$year", $make, "$length")
        if ($typeLabel) { $titleParts += $typeLabel }
        $titleCore = (($titleParts -join ' ') -replace '\s+', ' ').Trim()

        $specsParts = @("$year", "$length")
        if ($typeLabel) { $specsParts += $typeLabel }
        $specsParts += $suspLabel
        $specsLine = $specsParts -join ' · '

        $pageTitle = if ($price -gt 0) { "$titleCore — $priceFormatted | City Limit Auto" } else { "$titleCore | City Limit Auto" }
        $metaDesc = if ($price -gt 0) { "$titleCore $($L.forSaleIn) — $priceFormatted. $($L.viewDetails)" } else { "$titleCore $($L.forSaleIn). $($L.viewDetails)" }
        $metaDesc = ($metaDesc -replace '\s+', ' ').Trim()

        $langPath = if ($isEs) { "/es" } else { "" }
        $otherLangPath = if ($isEs) { "" } else { "/es" }
        $pageUrl = "https://citylimitauto.com$langPath/inventory/$slug.html"
        $altLangUrl = "https://citylimitauto.com$otherLangPath/inventory/$slug.html"
        $enUrl = if ($isEs) { $altLangUrl } else { $pageUrl }
        $esUrl = if ($isEs) { $pageUrl } else { $altLangUrl }
        $inventoryUrl = "https://citylimitauto.com$langPath/inventory.html"
        $homeUrl = "https://citylimitauto.com$langPath/index.html"
        $financingHref = "$langPath/financing.html?unit=$([uri]::EscapeDataString($unit))&price=$price"
        $langToggleHref = "$otherLangPath/inventory/$slug.html"

        $robotsMeta = if ($status -eq "Sold") { "`n<meta name=`"robots`" content=`"noindex,follow`">" } else { "" }

        # ---- Structured data (built via ConvertTo-Json, not hand-written,
        # so escaping is never a risk) ----
        $productSchema = [ordered]@{
            "@context" = "https://schema.org"
            "@type" = "Product"
            name = $titleCore
            sku = $unit
        }
        if ($vin) { $productSchema.vehicleIdentificationNumber = $vin }
        if ($photos.Count -gt 0) { $productSchema.image = "https://citylimitauto.com$($photos[0])" }
        $productSchema.brand = [ordered]@{ "@type" = "Brand"; name = $make }
        if ($price -gt 0) {
            $productSchema.offers = [ordered]@{
                "@type" = "Offer"
                price = "$price"
                priceCurrency = "USD"
                availability = if ($status -eq "Available") { "https://schema.org/InStock" } else { "https://schema.org/OutOfStock" }
                url = $pageUrl
            }
        }
        $productSchemaJson = ConvertTo-Json -InputObject $productSchema -Depth 6 -Compress

        $breadcrumbSchema = [ordered]@{
            "@context" = "https://schema.org"
            "@type" = "BreadcrumbList"
            itemListElement = @(
                [ordered]@{ "@type" = "ListItem"; position = 1; name = $L.breadcrumbHome; item = $homeUrl }
                [ordered]@{ "@type" = "ListItem"; position = 2; name = $L.breadcrumbInv; item = $inventoryUrl }
                [ordered]@{ "@type" = "ListItem"; position = 3; name = $titleCore; item = $pageUrl }
            )
        }
        $breadcrumbSchemaJson = ConvertTo-Json -InputObject $breadcrumbSchema -Depth 6 -Compress

        # ---- Photos ----
        if ($photos.Count -gt 0) {
            $photoTags = for ($i = 0; $i -lt $photos.Count; $i++) {
                $loadingAttr = if ($i -lt 2) { "eager" } else { "lazy" }
                "<img src=`"$($photos[$i])`" alt=`"$titleCore — $($i + 1)/$($photos.Count)`" loading=`"$loadingAttr`">"
            }
            $photosHtml = $photoTags -join "`n      "
        } else {
            $photosHtml = "<span class=`"photo-placeholder`">$($L.soon)</span>"
        }

        $vinHtml = if ($vin) { "<div class=`"lightbox-info-vin`">VIN $vin</div>" } else { "" }

        $downDefault = [Math]::Round($price * 0.1)
        $formSubject = "Trailer Inquiry — Unit $unit"
        $prefillMsg = if ($isEs) {
            "Estoy interesado en la Unidad $unit — $year $make, $length, $priceFormatted."
        } else {
            "I'm interested in Unit $unit — $year $make, $length, $priceFormatted."
        }
        $successMsg = if ($isEs) {
            "¡Gracias! Nos pondremos en contacto sobre la Unidad $unit pronto."
        } else {
            "Thanks! We'll be in touch about Unit $unit shortly."
        }

        return @"
<!DOCTYPE html>
<html lang="$lang">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$pageTitle</title>
<meta name="description" content="$metaDesc">
<link rel="canonical" href="$pageUrl">
<meta property="og:type" content="website">
<meta property="og:site_name" content="City Limit Auto">
<meta property="og:locale" content="$( if ($isEs) { 'es_US' } else { 'en_US' } )">
<meta property="og:url" content="$pageUrl">
<meta property="og:title" content="$pageTitle">
<meta property="og:description" content="$metaDesc">
<meta property="og:image" content="$( if ($photos.Count -gt 0) { "https://citylimitauto.com$($photos[0])" } else { 'https://citylimitauto.com/assets/img/hero-yard.jpg' } )">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="$pageTitle">
<meta name="twitter:description" content="$metaDesc">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Oswald:wght@400;500;600;700&family=Inter:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="alternate" hreflang="en" href="$enUrl">
<link rel="alternate" hreflang="es" href="$esUrl">
<link rel="alternate" hreflang="x-default" href="$enUrl">
<link rel="icon" href="/assets/img/logo.png" type="image/png">
<link rel="stylesheet" href="/assets/styles.css">$robotsMeta
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "AutoDealer",
  "@id": "https://citylimitauto.com/#business",
  "name": "City Limit Auto",
  "image": "https://citylimitauto.com/assets/img/hero-yard.jpg",
  "logo": "https://citylimitauto.com/assets/img/logo.png",
  "url": "https://citylimitauto.com/",
  "telephone": "+1-951-330-7545",
  "email": "info@citylimitauto.com",
  "priceRange": "`$`$",
  "address": {
    "@type": "PostalAddress",
    "streetAddress": "1281 W Oleander Ave",
    "addressLocality": "Perris",
    "addressRegion": "CA",
    "postalCode": "92571",
    "addressCountry": "US"
  },
  "openingHoursSpecification": [
    {
      "@type": "OpeningHoursSpecification",
      "dayOfWeek": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"],
      "opens": "08:00",
      "closes": "17:00"
    }
  ],
  "areaServed": "Southern California"
}
</script>
<script type="application/ld+json">
$breadcrumbSchemaJson
</script>
<script type="application/ld+json">
$productSchemaJson
</script>
</head>
<body>
<a href="#main" class="skip-link">$($L.skip)</a>

<header>
  <div class="nav">
    <a href="$langPath/index.html" class="brand">
      <img src="/assets/img/logo.png" alt="$($L.logoAlt)" class="brand-mark">
      <div class="brand-text">City Limit Auto<span>$($L.brandTag)</span></div>
    </a>
    <nav>
      <ul>
        <li><a href="$langPath/index.html">$($L.home)</a></li>
        <li><a href="$langPath/inventory.html" aria-current="page">$($L.inventoryNav)</a></li>
        <li><a href="$langPath/repairs.html">$($L.repairs)</a></li>
        <li><a href="$langPath/financing.html">$($L.financingNav)</a></li>
        <li><a href="$langPath/about.html">$($L.about)</a></li>
        <li><a href="$langPath/contact.html">$($L.contact)</a></li>
      </ul>
    </nav>
    <a href="$langPath/contact.html" class="nav-cta">$($L.getQuote)</a>
    <a href="$langToggleHref" class="lang-toggle" hreflang="$( if ($isEs) { 'en' } else { 'es' } )" lang="$( if ($isEs) { 'en' } else { 'es' } )">$( if ($isEs) { 'EN' } else { 'ES' } )</a>
    <button class="mobile-toggle" aria-label="$($L.openMenu)">☰</button>
  </div>
</header>

<main id="main">
  <div class="page-header">
    <div class="wrap">
      <div class="section-eyebrow"><a href="$langPath/inventory.html" style="color:inherit;">$($L.breadcrumbInv)</a> / $unit</div>
      <h1>$titleCore</h1>
    </div>
  </div>

  <section class="section">
    <div class="wrap">
      <div class="lightbox-embed">
        <div class="lightbox-photos">
          <div class="lightbox-scroll">
      $photosHtml
          </div>
        </div>
        <div class="lightbox-sheet-wrap">
          <div class="lightbox-sheet">
            <div class="lightbox-info-peek">
              <div class="lightbox-info-text">
                <div class="lightbox-info-top">
                  <span class="lightbox-info-price">$priceFormatted</span>
                  <span class="badge $badgeClass">$statusLabel</span>
                </div>
                <div class="lightbox-info-title">$make — $($L.unitLabel) $unit</div>
                $vinHtml
                <div class="lightbox-info-specs">$specsLine</div>
              </div>
              <div class="lightbox-info-actions">
                <button type="button" class="lightbox-info-share" id="unitShareBtn">$($L.share)</button>
                <a href="#unitInquireForm" class="lightbox-info-btn">$($L.inquire)</a>
                <a href="$financingHref" class="lightbox-info-apply">$($L.apply)</a>
              </div>
            </div>
            <div class="lightbox-info-form-wrap">
              <div class="lightbox-calc">
                <h3 class="lightbox-form-heading">$($L.calcHeading)</h3>
                <div class="calc-row">
                  <label>$($L.calcDown) <span class="lightbox-calc-down-val"></span></label>
                  <input type="range" class="lightbox-calc-down" min="0" max="$price" step="250" value="$downDefault">
                </div>
                <div class="calc-row">
                  <label>$($L.calcTerm)</label>
                  <select class="lightbox-calc-term form-input">
                    <option value="12">12 mo</option>
                    <option value="24">24 mo</option>
                    <option value="36" selected>36 mo</option>
                    <option value="48">48 mo</option>
                    <option value="60">60 mo</option>
                  </select>
                </div>
                <div class="calc-row">
                  <label>$($L.calcApr) <span class="lightbox-calc-apr-val"></span></label>
                  <input type="range" class="lightbox-calc-apr" min="4" max="20" step="0.1" value="9.9">
                </div>
                <div class="calc-result">
                  <span class="calc-result-label">$($L.calcMonthly)</span>
                  <span class="calc-result-value lightbox-calc-monthly"></span>
                </div>
                <p class="form-note">$($L.calcNote)</p>
              </div>
              <h3 class="lightbox-form-heading">$($L.formHeading)</h3>
              <form id="unitInquireForm" class="lightbox-form" action="https://formspree.io/f/xeeyykdp" method="POST">
                <input type="hidden" name="_subject" value="$formSubject">
                <input type="text" name="_gotcha" style="display:none" tabindex="-1" autocomplete="off">
                <input type="text" name="i-fname" placeholder="$($L.firstName)" required>
                <input type="text" name="i-lname" placeholder="$($L.lastName)" required>
                <input type="tel" name="i-phone" placeholder="$($L.phoneLabel)">
                <input type="email" name="email" placeholder="$($L.emailLabel)" required>
                <textarea name="i-message" required>$prefillMsg</textarea>
                <button type="submit" class="lightbox-form-submit">$($L.send)</button>
              </form>
            </div>
          </div>
        </div>
      </div>
    </div>
  </section>

  <section class="cta-band">
    <div class="wrap cta-inner">
      <h2>$($L.cta)</h2>
      <a href="$langPath/contact.html" class="btn btn-dark">$($L.ctaBtn)</a>
    </div>
  </section>
</main>

<footer>
  <div class="wrap">
    <div class="footer-grid">
      <div>
        <img src="/assets/img/logo.png" alt="$($L.logoAlt)" class="footer-logo">
        <h4>City Limit Auto</h4>
        <p>1281 W Oleander Ave<br>Perris, CA 92571</p>
        <p>$($L.licensedDealer)</p>
      </div>
      <div>
        <h4>$($L.contact)</h4>
        <a href="tel:+19513307545">(951) 330-7545</a>
        <a href="mailto:info@citylimitauto.com">info@citylimitauto.com</a>
      </div>
      <div>
        <h4>$( if ($isEs) { 'Horario' } else { 'Hours' } )</h4>
        <p>$($L.hours1)</p>
        <p>$($L.hours2)</p>
      </div>
    </div>
    <div class="footer-bottom">
      <span>© 2026 City Limit Auto. $($L.rightsReserved).</span>
    </div>
  </div>
</footer>

<script src="/assets/site.js"></script>
<script>
  wireForm('unitInquireForm', "$successMsg");
  wireCalculator({
    price: $price,
    down: document.querySelector('.lightbox-calc-down'),
    downVal: document.querySelector('.lightbox-calc-down-val'),
    term: document.querySelector('.lightbox-calc-term'),
    apr: document.querySelector('.lightbox-calc-apr'),
    aprVal: document.querySelector('.lightbox-calc-apr-val'),
    monthly: document.querySelector('.lightbox-calc-monthly'),
  });
  document.getElementById('unitShareBtn').addEventListener('click', (e) => {
    shareUrl("$titleCore", "$titleCore — $priceFormatted", location.href, e.currentTarget, "$( if ($isEs) { '¡Copiado!' } else { 'Copied!' } )", "$( if ($isEs) { 'Copie este enlace:' } else { 'Copy this link:' } )");
  });
</script>
</body>
</html>
"@
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
    # for-sale inventory — exclude anything flagged rental:true. A Sold unit
    # only passes through while it's still within its retention window.
    $publicItems = @($items | Where-Object {
        $publicStatuses -contains $_.status -and -not $_.rental -and
        ($_.status -ne "Sold" -or (IsRecentlySold $_.vin))
    } | ForEach-Object {
        $unitNumber = $_.unit_number
        $make = ToTitleCase $_.make
        $status = if ($_.status -eq "Down") { "Available" } else { $_.status }
        $slug = Get-Slug -Year $_.year -Make $_.make -Type $_.model -Length $_.length -Unit $unitNumber
        [ordered]@{
            unit   = $unitNumber
            slug   = $slug
            vin    = $_.vin
            title  = "$($_.length)' $($_.model) — $make"
            # Published separately (not just inside `title`) so the site can
            # build a reliable Make filter without parsing strings.
            make   = $make
            type   = $_.model
            year   = [int]$_.year
            length = "$($_.length)'"
            price  = [int]$_.price
            suspension = ToTitleCase $_.suspension
            # "Down" is an internal-only distinction (sellable, just not yet
            # mechanic-inspected) — buyers should just see "Available".
            status = $status
            # @(...) wrapper matters: PowerShell collapses an empty-array
            # return value to $null across a function boundary, which would
            # otherwise serialize as "photos": {} instead of "photos": [].
            photos = @(Get-UnitPhotos -vin $_.vin -unitNumber $unitNumber)
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
    $soldCount = @($publicItems | Where-Object { $_.status -eq "Sold" }).Count
    Write-Log "Wrote $($publicItems.Count) unit(s) to $OutputPath ($soldCount recently-sold, $photoCount photo(s) across $unitsWithPhotos unit(s))"

    # Persist the photo-folder cache so next run can skip untouched units.
    # Only rewritten when something actually changed, same spirit as the
    # inventory JSON itself.
    if ($photoCacheChanged) {
        $photoCache | ConvertTo-Json -Depth 3 | Set-Content -Path $PhotoCachePath -Encoding UTF8
        Write-Log "Updated photo-cache.json ($($photoCache.Count) unit(s) tracked)."
    }

    # Persist the sold-date cache the same way — only rewritten when a VIN
    # was newly marked Sold, un-sold, or aged out of the retention window.
    if ($soldCacheChanged) {
        $soldCache | ConvertTo-Json -Depth 3 | Set-Content -Path $SoldCachePath -Encoding UTF8
        Write-Log "Updated sold-cache.json ($($soldCache.Count) unit(s) tracked)."
    }

    # ---- Generate individual static listing pages (SEO) ----
    # Each currently-published unit gets its own indexable page in
    # inventory/ (EN) and es/inventory/ (ES) — see New-UnitPageHtml above.
    # Wrapped per-unit in try/catch so one bad record can't abort a run that
    # already safely wrote inventory.json/photos — a skipped unit just keeps
    # whatever page (if any) it had from the last successful run.
    $UnitPagesRoot = Join-Path $RepoRoot "inventory"
    $UnitPagesRootEs = Join-Path $RepoRoot "es\inventory"
    New-Item -ItemType Directory -Force -Path $UnitPagesRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $UnitPagesRootEs | Out-Null

    $expectedFiles = @{}
    $pagesWritten = 0
    $pagesFailed = 0
    foreach ($item in $publicItems) {
        try {
            $fileName = "$($item.slug).html"
            $enHtml = New-UnitPageHtml -item $item -lang "en"
            Set-Content -Path (Join-Path $UnitPagesRoot $fileName) -Value $enHtml -Encoding UTF8
            $esHtml = New-UnitPageHtml -item $item -lang "es"
            Set-Content -Path (Join-Path $UnitPagesRootEs $fileName) -Value $esHtml -Encoding UTF8
            $expectedFiles[$fileName] = $true
            $pagesWritten++
        } catch {
            $pagesFailed++
            Write-Log "WARNING: couldn't generate listing page for unit $($item.unit): $($_.Exception.Message)"
        }
    }

    # Stale-page cleanup — a unit that ages out of the Sold retention window
    # or is otherwise removed from $publicItems loses its page the same way
    # its ?unit= deep link already stops resolving once it drops out of
    # inventory.json. Scoped to filenames that look like a generated slug —
    # never a blind "delete anything unexpected" over a directory this
    # script owns.
    $staleRemoved = 0
    foreach ($dir in @($UnitPagesRoot, $UnitPagesRootEs)) {
        Get-ChildItem -Path $dir -Filter "*.html" -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^[a-z0-9-]+\.html$' -and -not $expectedFiles.ContainsKey($_.Name)
        } | ForEach-Object {
            Remove-Item -Path $_.FullName -Force
            $staleRemoved++
        }
    }
    Write-Log "Generated $pagesWritten listing page(s) ($pagesFailed failed), removed $staleRemoved stale page(s)."

    # ---- Regenerate sitemap.xml ----
    # Fully generated here now (supersedes the old hand-maintained file) —
    # the 12 static pages keep their own fixed lastmod (never bumped by this
    # script — only per-unit entries use today's date). Sold units are
    # deliberately left OUT of the sitemap — their page keeps working for a
    # direct link (see the retention system above), but submitting a
    # soon-to-404 listing for indexing wastes crawl budget and sends
    # searchers to dead-end results. Pending Sale isn't final, so it's
    # indexed like Available.
    function New-SitemapUrlEntry($loc, $enHref, $esHref, $lastmod, $changefreq, $priority) {
        return @"
  <url>
    <loc>$loc</loc>
    <lastmod>$lastmod</lastmod>
    <xhtml:link rel="alternate" hreflang="en" href="$enHref"/>
    <xhtml:link rel="alternate" hreflang="es" href="$esHref"/>
    <xhtml:link rel="alternate" hreflang="x-default" href="$enHref"/>
    <changefreq>$changefreq</changefreq>
    <priority>$priority</priority>
  </url>
"@
    }

    $staticSitemapPages = @(
        @{ path = "index.html";     lastmod = "2026-08-16"; changefreq = "daily";   priorityEn = "1.0"; priorityEs = "0.9" }
        @{ path = "inventory.html"; lastmod = "2026-08-16"; changefreq = "hourly";  priorityEn = "0.9"; priorityEs = "0.8" }
        @{ path = "financing.html"; lastmod = "2026-08-16"; changefreq = "weekly";  priorityEn = "0.8"; priorityEs = "0.7" }
        @{ path = "repairs.html";   lastmod = "2026-08-16"; changefreq = "weekly";  priorityEn = "0.7"; priorityEs = "0.6" }
        @{ path = "about.html";     lastmod = "2026-08-16"; changefreq = "monthly"; priorityEn = "0.6"; priorityEs = "0.5" }
        @{ path = "contact.html";   lastmod = "2026-08-16"; changefreq = "monthly"; priorityEn = "0.6"; priorityEs = "0.5" }
        @{ path = "areas/";  lastmod = "2026-09-19"; changefreq = "monthly"; priorityEn = "0.8"; priorityEs = "0.7" }
        @{ path = "areas/fontana-ontario-bloomington.html"; lastmod = "2026-09-19"; changefreq = "monthly"; priorityEn = "0.7"; priorityEs = "0.6" }
    )

    $sitemapEntries = @()
    foreach ($p in $staticSitemapPages) {
        $enHref = "https://citylimitauto.com/$($p.path)"
        $esHref = "https://citylimitauto.com/es/$($p.path)"
        $sitemapEntries += New-SitemapUrlEntry $enHref $enHref $esHref $p.lastmod $p.changefreq $p.priorityEn
        $sitemapEntries += New-SitemapUrlEntry $esHref $enHref $esHref $p.lastmod $p.changefreq $p.priorityEs
    }

    $todayDate = Get-Date -Format "yyyy-MM-dd"
    foreach ($item in $publicItems) {
        if ($item.status -eq "Sold") { continue }
        $enHref = "https://citylimitauto.com/inventory/$($item.slug).html"
        $esHref = "https://citylimitauto.com/es/inventory/$($item.slug).html"
        $sitemapEntries += New-SitemapUrlEntry $enHref $enHref $esHref $todayDate "weekly" "0.7"
        $sitemapEntries += New-SitemapUrlEntry $esHref $enHref $esHref $todayDate "weekly" "0.6"
    }

    $sitemapXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
        xmlns:xhtml="http://www.w3.org/1999/xhtml">
$($sitemapEntries -join "`n")
</urlset>
"@
    Set-Content -Path (Join-Path $RepoRoot "sitemap.xml") -Value $sitemapXml -Encoding UTF8
    Write-Log "Regenerated sitemap.xml ($($sitemapEntries.Count) URL entries)."

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
            git add "assets/inventory.json" "assets/photos" "inventory" "es/inventory" "sitemap.xml" | Out-Null
            # Scoped to just the paths this script manages — a repo-wide
            # `git status` would also pick up unrelated in-progress edits
            # (e.g. someone editing this very script) and trigger a bogus
            # commit attempt with nothing actually staged.
            $changes = git status --porcelain -- "assets/inventory.json" "assets/photos" "inventory" "es/inventory" "sitemap.xml"
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

