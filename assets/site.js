/* =========================================================
   City Limit Auto — Shared Site JS
   Inventory rendering/filtering + photo lightbox.
   Inventory data is loaded at runtime from assets/inventory.json,
   which the office sync script regenerates automatically — see
   sync/README.md.
   ========================================================= */

let inventory = [];

// Spanish pages live under /es/. Everything language-aware keys off this.
const IS_ES = location.pathname.startsWith('/es/');

// Labels for the inline inquiry form built into the photo lightbox's bottom
// sheet — kept separate from the card's translation object (T, built fresh
// per renderInventory() call) since the lightbox is wired up globally.
const FORM_T = IS_ES
  ? {
      heading: 'Consultar sobre este remolque', firstName: 'Nombre', lastName: 'Apellido',
      phone: 'Teléfono', email: 'Correo electrónico', send: 'Enviar consulta',
      success: (unit) => `¡Gracias! Nos pondremos en contacto sobre la Unidad ${unit} pronto.`,
      prefill: (item) => `Estoy interesado en la Unidad ${item.unit} — ${item.year} ${item.make}, ${item.length}, $${item.price.toLocaleString()}.`,
      calcHeading: 'Calculadora de Pagos', calcDown: 'Enganche', calcTerm: 'Plazo',
      calcApr: 'Tasa Estimada (APR)', calcMonthly: 'Pago Mensual Estimado',
      calcNote: 'Solo es un estimado — su tasa y pago real dependen de la aprobación de crédito.',
    }
  : {
      heading: 'Inquire About This Trailer', firstName: 'First Name', lastName: 'Last Name',
      phone: 'Phone', email: 'Email', send: 'Send Inquiry',
      success: (unit) => `Thanks! We'll be in touch about Unit ${unit} shortly.`,
      prefill: (item) => `I'm interested in Unit ${item.unit} — ${item.year} ${item.make}, ${item.length}, $${item.price.toLocaleString()}.`,
      calcHeading: 'Payment Calculator', calcDown: 'Down Payment', calcTerm: 'Term',
      calcApr: 'Estimated APR', calcMonthly: 'Estimated Monthly Payment',
      calcNote: 'Estimate only — your actual rate and payment depend on credit approval.',
    };

// Shared amortization math for the payment calculator, used both here (the
// lightbox) and on the standalone Financing page. els.price is a fixed
// number when the trailer price is already known (lightbox), or an <input>
// when it's user-editable (Financing page's calculator).
function wireCalculator(els){
  function fmt(n){ return '$' + Math.round(n).toLocaleString(); }
  function getPrice(){
    return typeof els.price === 'number' ? els.price : Math.max(0, Number(els.price.value) || 0);
  }
  function recalc(){
    const p = getPrice();
    els.down.max = p;
    const down = Math.min(Number(els.down.value) || 0, p);
    els.down.value = down;
    els.downVal.textContent = fmt(down);
    els.aprVal.textContent = Number(els.apr.value).toFixed(1) + '%';

    const principal = Math.max(0, p - down);
    const months = Number(els.term.value);
    const r = (Number(els.apr.value) / 100) / 12;
    let monthly;
    if(principal <= 0) monthly = 0;
    else if(r === 0) monthly = principal / months;
    else monthly = principal * (r * Math.pow(1 + r, months)) / (Math.pow(1 + r, months) - 1);
    els.monthly.textContent = fmt(monthly) + '/mo';
  }
  [els.down, els.term, els.apr, typeof els.price !== 'number' ? els.price : null].filter(Boolean).forEach(el => {
    el.addEventListener('input', recalc);
    el.addEventListener('change', recalc);
  });
  recalc();
}

// ---------- Spanish suggestion banner ----------
// If the visitor's browser is set to Spanish and they're on an English page,
// offer the Spanish version. We suggest rather than auto-redirect, so
// bilingual users who prefer English aren't hijacked. Dismissal sticks.
(function(){
  if(IS_ES) return;
  try {
    if(localStorage.getItem('cl_lang_dismissed') === '1') return;
  } catch(e) { /* private mode — just show it */ }

  const langs = navigator.languages || [navigator.language || ''];
  const prefersEs = langs.some(l => (l || '').toLowerCase().startsWith('es'));
  if(!prefersEs) return;

  const page = location.pathname.split('/').pop() || 'index.html';
  const bar = document.createElement('div');
  bar.className = 'lang-banner';
  bar.innerHTML = `
    <span>¿Prefiere ver este sitio en español?</span>
    <a class="lang-banner-go" href="/es/${page}">Ver en español</a>
    <button class="lang-banner-close" aria-label="Cerrar">&times;</button>
  `;
  document.body.insertBefore(bar, document.body.firstChild);
  bar.querySelector('.lang-banner-close').addEventListener('click', () => {
    bar.remove();
    try { localStorage.setItem('cl_lang_dismissed', '1'); } catch(e) {}
  });
})();

// ---------- Mobile nav toggle ----------
(function(){
  const toggle = document.querySelector('.mobile-toggle');
  const header = document.querySelector('header');
  if(!toggle || !header) return;

  function setOpen(open){
    header.classList.toggle('nav-open', open);
    toggle.textContent = open ? '×' : '☰';
    toggle.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
  }

  toggle.addEventListener('click', () => setOpen(!header.classList.contains('nav-open')));
  header.querySelectorAll('nav a').forEach(a => a.addEventListener('click', () => setOpen(false)));
})();

// ---------- Swipe-to-drag photo carousel (touch devices) ----------
// The photo tracks the finger 1:1 while dragging (no easing lag, no snap
// until the finger lifts), then either finishes the transition or springs
// back — distance OR speed can trigger a commit, so a fast flick advances
// even on a short drag, the way Redfin's listing-photo swipe behaves.
// Shared by the lightbox and the in-card photo browser: `stage` is the
// (position:relative, overflow:hidden) container, `mainImg` is the visible
// <img> inside it. opts: { count(), getIndex(), photoUrl(index), onSettle(delta) }
function wireDragCarousel(stage, mainImg, opts){
  let startX = 0, startY = 0, startTime = 0, dragging = false, direction = 0, ghost = null, stageWidth = 0;

  function cleanupGhost(){
    if(ghost && ghost.parentNode) ghost.parentNode.removeChild(ghost);
    ghost = null;
  }

  stage.addEventListener('touchstart', (e) => {
    if(opts.count() < 2) return;
    const t = e.touches[0];
    startX = t.clientX; startY = t.clientY; startTime = Date.now();
    dragging = true; direction = 0;
    stageWidth = stage.clientWidth;
    cleanupGhost();
  }, { passive: true });

  stage.addEventListener('touchmove', (e) => {
    if(!dragging) return;
    const t = e.touches[0];
    const dx = t.clientX - startX, dy = t.clientY - startY;
    if(!direction){
      if(Math.abs(dx) < 6 && Math.abs(dy) < 6) return;
      direction = Math.abs(dx) > Math.abs(dy) ? 'h' : 'v';
      if(direction === 'v'){ dragging = false; return; }
    }
    e.preventDefault();

    mainImg.style.transition = 'none';
    mainImg.style.transform = `translateX(${dx}px)`;

    const goingNext = dx < 0;
    if(!ghost){
      const nextIdx = (opts.getIndex() + (goingNext ? 1 : -1) + opts.count()) % opts.count();
      ghost = document.createElement('img');
      ghost.className = mainImg.className + ' swipe-img-ghost';
      ghost.src = opts.photoUrl(nextIdx);
      ghost.style.transition = 'none';
      stage.appendChild(ghost);
    }
    ghost.style.transform = `translateX(${dx + (goingNext ? stageWidth : -stageWidth)}px)`;
  }, { passive: false });

  stage.addEventListener('touchend', (e) => {
    if(!dragging){ direction = 0; return; }
    dragging = false;
    if(direction !== 'h'){ direction = 0; cleanupGhost(); return; }

    const t = e.changedTouches[0];
    const dx = t.clientX - startX;
    const elapsed = Math.max(1, Date.now() - startTime);
    const velocity = Math.abs(dx) / elapsed; // px/ms
    const commit = ghost && (Math.abs(dx) > stageWidth * 0.3 || velocity > 0.5);
    const goingNext = dx < 0;

    if(commit){
      mainImg.style.transition = 'transform 200ms ease-out';
      ghost.style.transition = 'transform 200ms ease-out';
      mainImg.style.transform = `translateX(${goingNext ? -stageWidth : stageWidth}px)`;
      ghost.style.transform = 'translateX(0px)';
      setTimeout(() => {
        opts.onSettle(goingNext ? 1 : -1);
        // Don't drop the ghost (still showing the correct new photo) until
        // mainImg's freshly-assigned src has actually finished loading —
        // otherwise there's a frame where mainImg is back in place but still
        // painting its old bitmap, flashing the previous photo.
        let settled = false;
        const finish = () => {
          if(settled) return;
          settled = true;
          mainImg.style.transition = 'none';
          mainImg.style.transform = '';
          cleanupGhost();
        };
        mainImg.addEventListener('load', finish, { once: true });
        mainImg.addEventListener('error', finish, { once: true });
        setTimeout(finish, 400); // safety net if neither event fires
      }, 200);
    } else {
      mainImg.style.transition = 'transform 200ms ease-out';
      mainImg.style.transform = 'translateX(0px)';
      if(ghost){
        ghost.style.transition = 'transform 200ms ease-out';
        ghost.style.transform = `translateX(${goingNext ? stageWidth : -stageWidth}px)`;
      }
      setTimeout(cleanupGhost, 200);
    }
    direction = 0;
  });
}

// ---------- Swipe-up bottom sheet (photo lightbox's info/inquiry panel) ----------
// Collapsed, it shows the compact price/specs summary; dragging (or tapping)
// it up reveals an inquiry form below — same drag-follow-then-commit feel as
// the photo carousel, just vertical with only two resting positions.
function wireSheetDrag(sheet){
  const peekEl = sheet.querySelector('.lightbox-info-peek');
  const handleEl = sheet.querySelector('.lightbox-sheet-handle');
  let collapsedY = 0, isOpen = false, dragging = false, moved = false;
  let startY = 0, startTime = 0, baseY = 0;

  function measure(){
    collapsedY = Math.max(0, sheet.offsetHeight - handleEl.offsetHeight - peekEl.offsetHeight);
  }

  function applyOpen(open, animate){
    isOpen = open;
    sheet.style.transition = animate ? 'transform 260ms ease-out' : 'none';
    sheet.style.transform = `translateY(${open ? 0 : collapsedY}px)`;
    // Once the form is showing, the Inquire button that revealed it has
    // done its job — leaving it sitting there reads as unclear/dead weight.
    sheet.classList.toggle('is-open', open);
  }

  function onStart(e){
    const t = e.touches[0];
    startY = t.clientY; startTime = Date.now();
    measure();
    baseY = isOpen ? 0 : collapsedY;
    dragging = true; moved = false;
  }

  function onMove(e){
    if(!dragging) return;
    const t = e.touches[0];
    const dy = t.clientY - startY;
    if(!moved && Math.abs(dy) < 6) return;
    moved = true;
    e.preventDefault();
    const y = Math.max(0, Math.min(collapsedY, baseY + dy));
    sheet.style.transition = 'none';
    sheet.style.transform = `translateY(${y}px)`;
  }

  function onEnd(e){
    if(!dragging) return;
    dragging = false;
    if(!moved) return; // a plain tap — the click listener below handles it
    const t = e.changedTouches[0];
    const dy = t.clientY - startY;
    const elapsed = Math.max(1, Date.now() - startTime);
    const velocity = dy / elapsed; // px/ms, negative = moving up
    const currentY = Math.max(0, Math.min(collapsedY, baseY + dy));
    const open = Math.abs(velocity) > 0.5 ? velocity < 0 : currentY < collapsedY / 2;
    applyOpen(open, true);
    // Reset now (not just at the next onStart) so a later click that isn't
    // preceded by a fresh touchstart — a mouse click, say — isn't ignored
    // because it sees this drag's now-stale "moved" flag.
    moved = false;
  }

  [handleEl, peekEl].forEach(target => {
    target.addEventListener('touchstart', onStart, { passive: true });
    target.addEventListener('click', () => { if(!moved) applyOpen(!isOpen, true); });
  });
  sheet.addEventListener('touchmove', onMove, { passive: false });
  sheet.addEventListener('touchend', onEnd);

  return {
    // Called fresh each time a trailer's lightbox opens. Defaults to
    // collapsed; pass true (e.g. from the Inquire button) to open straight
    // to the form instead of making people tap/swipe it open themselves.
    reset(open = false){ measure(); applyOpen(open, false); },
  };
}

// ---------- Photo lightbox (click a trailer photo to view all of them) ----------
// A vertical scrolling feed of every photo, Redfin-style, with a persistent
// bottom sheet (price/specs summary, swipes up to an inquiry form) — not a
// one-photo-at-a-time carousel, so there's no horizontal drag logic here,
// just native scroll for photos.
function ensureLightbox(){
  if(document.getElementById('lightbox')) return;
  const el = document.createElement('div');
  el.id = 'lightbox';
  el.className = 'lightbox';
  el.hidden = true;
  el.innerHTML = `
    <div class="lightbox-topbar">
      <button class="lightbox-back" aria-label="Back">&larr;</button>
    </div>
    <div class="lightbox-scroll"></div>
    <div class="lightbox-sheet-wrap">
      <div class="lightbox-sheet">
        <div class="lightbox-sheet-handle"></div>
        <div class="lightbox-info-peek"></div>
        <div class="lightbox-info-form-wrap"></div>
      </div>
    </div>
  `;
  document.body.appendChild(el);

  el.querySelector('.lightbox-back').addEventListener('click', closeLightbox);
  el.addEventListener('click', (e) => {
    if(e.target === el || e.target.classList.contains('lightbox-scroll')) closeLightbox();
  });
  document.addEventListener('keydown', (e) => {
    if(document.getElementById('lightbox')?.hidden) return;
    if(e.key === 'Escape') closeLightbox();
  });
  el._sheetControls = wireSheetDrag(el.querySelector('.lightbox-sheet'));
}

// opts: { item, index, T, trSusp, trType, shareLink, startOpen } — T/trSusp/
// trType/shareLink are the same translation/share helpers renderInventory()
// already built for the card, passed through so this reads correctly in
// Spanish too. startOpen jumps straight to the inquiry form (the card's
// Inquire button does this) instead of the usual collapsed peek.
function openLightbox(opts){
  const { item, index, T, trSusp, trType, shareLink, startOpen } = opts;
  ensureLightbox();
  const el = document.getElementById('lightbox');
  const photos = Array.isArray(item.photos) ? item.photos : [];

  const scroll = el.querySelector('.lightbox-scroll');
  scroll.innerHTML = photos.map((src, i) =>
    `<img src="${src}" alt="${item.title} — ${i + 1}/${photos.length}" loading="${i < 2 ? 'eager' : 'lazy'}">`
  ).join('');

  const statusLabel = T.status[item.status] || item.status;
  el.querySelector('.lightbox-info-peek').innerHTML = `
    <div class="lightbox-info-text">
      <div class="lightbox-info-top">
        <span class="lightbox-info-price">$${item.price.toLocaleString()}</span>
        <span class="badge ${badgeClass(item.status)}">${statusLabel}</span>
      </div>
      <div class="lightbox-info-title">${item.make} — ${T.unit} ${item.unit}</div>
      ${item.vin ? `<div class="lightbox-info-vin">VIN ${item.vin}</div>` : ''}
      <div class="lightbox-info-specs">${item.year} · ${item.length} · ${trType(item.type)} · ${trSusp(item.suspension) || '—'}</div>
    </div>
    <div class="lightbox-info-actions">
      <button type="button" class="lightbox-info-share">${T.share}</button>
      <button type="button" class="lightbox-info-btn">${T.inquire}</button>
      <a href="${T.financing}?unit=${encodeURIComponent(item.unit)}&price=${item.price}" class="lightbox-info-apply">${T.apply}</a>
    </div>
  `;
  // Share sits next to Inquire now (not the topbar) — stop its click from
  // also bubbling up to the peek's own open/close toggle.
  el.querySelector('.lightbox-info-share').addEventListener('click', (e) => {
    e.stopPropagation();
    shareLink(item, e.currentTarget);
  });

  // Swiping/tapping the sheet open reveals this instead of navigating to the
  // Contact page — the message is prefilled with the trailer so people don't
  // have to type out which unit they mean. The payment calculator uses the
  // trailer's actual price directly (no separate price field needed, unlike
  // the standalone Financing page where the price isn't already known).
  el.querySelector('.lightbox-info-form-wrap').innerHTML = `
    <div class="lightbox-calc">
      <h3 class="lightbox-form-heading">${FORM_T.calcHeading}</h3>
      <div class="calc-row">
        <label>${FORM_T.calcDown} <span class="lightbox-calc-down-val"></span></label>
        <input type="range" class="lightbox-calc-down" min="0" max="${item.price}" step="250" value="${Math.round(item.price * 0.1)}">
      </div>
      <div class="calc-row">
        <label>${FORM_T.calcTerm}</label>
        <select class="lightbox-calc-term form-input">
          <option value="12">12 mo</option>
          <option value="24">24 mo</option>
          <option value="36" selected>36 mo</option>
          <option value="48">48 mo</option>
          <option value="60">60 mo</option>
        </select>
      </div>
      <div class="calc-row">
        <label>${FORM_T.calcApr} <span class="lightbox-calc-apr-val"></span></label>
        <input type="range" class="lightbox-calc-apr" min="4" max="20" step="0.1" value="9.9">
      </div>
      <div class="calc-result">
        <span class="calc-result-label">${FORM_T.calcMonthly}</span>
        <span class="calc-result-value lightbox-calc-monthly"></span>
      </div>
      <p class="form-note">${FORM_T.calcNote}</p>
    </div>
    <h3 class="lightbox-form-heading">${FORM_T.heading}</h3>
    <form id="lightboxInquireForm" class="lightbox-form" action="https://formspree.io/f/xeeyykdp" method="POST">
      <input type="hidden" name="_subject" value="Trailer Inquiry — Unit ${item.unit}">
      <input type="text" name="_gotcha" style="display:none" tabindex="-1" autocomplete="off">
      <input type="text" name="i-fname" placeholder="${FORM_T.firstName}" required>
      <input type="text" name="i-lname" placeholder="${FORM_T.lastName}" required>
      <input type="tel" name="i-phone" placeholder="${FORM_T.phone}">
      <input type="email" name="email" placeholder="${FORM_T.email}" required>
      <textarea name="i-message" required>${FORM_T.prefill(item)}</textarea>
      <button type="submit" class="lightbox-form-submit">${FORM_T.send}</button>
    </form>
  `;
  wireForm('lightboxInquireForm', FORM_T.success(item.unit));
  wireCalculator({
    price: item.price,
    down: el.querySelector('.lightbox-calc-down'),
    downVal: el.querySelector('.lightbox-calc-down-val'),
    term: el.querySelector('.lightbox-calc-term'),
    apr: el.querySelector('.lightbox-calc-apr'),
    aprVal: el.querySelector('.lightbox-calc-apr-val'),
    monthly: el.querySelector('.lightbox-calc-monthly'),
  });

  el.hidden = false;
  document.body.style.overflow = 'hidden';
  // No need to wait a frame — reading offsetHeight inside reset() (and the
  // geometry scrollIntoView needs) forces layout synchronously on its own.
  const target = scroll.children[index] || scroll.children[0];
  if(target) target.scrollIntoView({ block: 'start' });
  el._sheetControls.reset(startOpen);
}

function closeLightbox(){
  const el = document.getElementById('lightbox');
  if(!el) return;
  el.hidden = true;
  document.body.style.overflow = '';
}

async function loadInventory(){
  try {
    // Root-absolute so this works from /es/ pages too, not just the site root.
    const res = await fetch('/assets/inventory.json', { cache: 'no-store' });
    if(!res.ok) throw new Error('HTTP ' + res.status);
    inventory = await res.json();
  } catch (err) {
    console.error('[site] failed to load inventory.json', err);
    inventory = [];
  }
}

// Submits a form to Formspree via fetch and swaps in a success message on the page.
function wireForm(formId, successMessage){
  const form = document.getElementById(formId);
  if(!form) return;

  form.addEventListener('submit', async function(e){
    e.preventDefault();
    const btn = form.querySelector('button[type="submit"]');
    const originalText = btn.textContent;
    btn.disabled = true;
    btn.textContent = IS_ES ? 'Enviando…' : 'Sending…';

    try {
      const res = await fetch(form.action, {
        method: 'POST',
        body: new FormData(form),
        headers: { 'Accept': 'application/json' }
      });
      if(res.ok){
        form.innerHTML = `<div class="full"><p class="form-success">${successMessage}</p></div>`;
      } else {
        throw new Error('Form submission failed');
      }
    } catch (err) {
      btn.disabled = false;
      btn.textContent = originalText;
      alert(IS_ES
        ? "Hubo un problema al enviar su mensaje. Por favor llámenos al (951) 330-7545 o escriba a sales@citylimitauto.com."
        : "Something went wrong sending your message. Please call us at (951) 330-7545 or email sales@citylimitauto.com.");
    }
  });
}

function badgeClass(status){
  if(status === 'Available') return 'badge-available';
  if(status === 'Hold') return 'badge-hold';
  if(status === 'Pending Sale') return 'badge-pending';
  return 'badge-sold';
}

// Product/Offer structured data for the current catalog — lets individual
// trailers become eligible for price/availability in Google's search
// results, not just the generic business listing. Represents the whole
// published catalog (not whatever's currently filtered on screen, since
// filtering is a UI-only concern search engines shouldn't see).
function injectInventorySchema(items){
  const existing = document.getElementById('inventory-schema');
  if(existing) existing.remove();
  if(!items.length) return;

  const path = IS_ES ? '/es/inventory.html' : '/inventory.html';
  const schema = {
    '@context': 'https://schema.org',
    '@type': 'ItemList',
    itemListElement: items.map((item, i) => ({
      '@type': 'ListItem',
      position: i + 1,
      item: {
        '@type': 'Product',
        name: `${item.year} ${item.make} ${item.length} ${item.type}`,
        sku: item.unit,
        ...(item.vin ? { vehicleIdentificationNumber: item.vin } : {}),
        ...(item.photos?.length ? { image: `${location.origin}${item.photos[0]}` } : {}),
        brand: { '@type': 'Brand', name: item.make },
        offers: {
          '@type': 'Offer',
          price: String(item.price),
          priceCurrency: 'USD',
          availability: item.status === 'Available' ? 'https://schema.org/InStock' : 'https://schema.org/OutOfStock',
          url: `${location.origin}${path}?unit=${encodeURIComponent(item.unit)}`,
        },
      },
    })),
  };

  const script = document.createElement('script');
  script.type = 'application/ld+json';
  script.id = 'inventory-schema';
  script.textContent = JSON.stringify(schema);
  document.head.appendChild(script);
}

async function renderInventory(gridId, opts = {}){
  const grid = document.getElementById(gridId);
  if(!grid) return;
  const emptyState = document.getElementById(opts.emptyStateId || 'emptyState');
  const filterBar = document.getElementById(opts.filterBarId || 'filterBar');
  const limit = opts.limit || Infinity;

  grid.innerHTML = `<div class="empty-state">${IS_ES ? 'Cargando inventario…' : 'Loading inventory…'}</div>`;
  await loadInventory();
  // Recently-sold units stay in inventory.json for a few weeks (see
  // sync-inventory.ps1) so they're still shown — badged Sold — on the full
  // listing, and a direct ?unit= link someone already has (e.g. sent to a
  // lender for financing) keeps working either way. The homepage's small
  // teaser strip is the one place they're left out, so a sold trailer never
  // crowds out actual available stock in those few featured slots.
  const visibleInventory = filterBar ? inventory : inventory.filter(i => i.status !== 'Sold');
  // Only the real inventory listing (has a filterBar), not the homepage
  // teaser grid — avoids publishing the same structured data from two pages.
  if(filterBar) injectInventorySchema(visibleInventory);

  const F = IS_ES
    ? {search:'Buscar por unidad, marca o VIN…', year:'Año', yearMin:'Año desde', yearMax:'Año hasta',
       make:'Cualquier marca', susp:'Cualquier suspensión', type:'Cualquier tipo',
       priceLabel:'Precio', price:'Cualquier precio',
       upto:'Hasta', clear:'Limpiar filtros', back:'← Ver todo el inventario',
       notFound:'Ese remolque ya no está en la lista — puede que se haya vendido.',
       showing:(n,t)=>`Mostrando ${n} de ${t} remolques`}
    : {search:'Search unit #, make, or VIN…', year:'Year', yearMin:'Year from', yearMax:'Year to',
       make:'Any make', susp:'Any suspension', type:'Any type',
       priceLabel:'Price', price:'Any price',
       upto:'Up to', clear:'Clear filters', back:'← View full inventory',
       notFound:'That trailer isn’t listed anymore — it may have sold.',
       showing:(n,t)=>`Showing ${n} of ${t} trailers`};

  // A card's Share button links to ?unit=<unit>, so a single trailer can be
  // viewed and sent to a customer. Only meaningful on a page with a filter
  // bar (the real inventory listing) — not the homepage teaser grid.
  const focusUnit = filterBar ? new URLSearchParams(location.search).get('unit') : null;

  // Touch devices hide the tap arrows on card photos (swipe replaces them —
  // see .tag-photo-nav in styles.css) and instead get a one-time nudge
  // animation the first time a multi-photo card scrolls into view, so it's
  // still obvious the photo can be swiped.
  const isTouchDevice = matchMedia('(hover: none) and (pointer: coarse)').matches;

  // Suspension/type values come from the sales system in English ("Air",
  // "Spring", "Dry Van"). Translate them for display/filter labels on
  // Spanish pages; the underlying value used for matching/filtering stays
  // untranslated.
  const suspLabel = IS_ES ? {Air:'Aire', Spring:'Muelles'} : {};
  const trSusp = v => suspLabel[v] || v;
  const typeLabel = IS_ES ? {'Dry Van':'Caja Seca'} : {};
  const trType = v => typeLabel[v] || v;

  // Controls are generated from the data that's actually published, so the
  // dropdowns never offer a value that returns zero results, and a filter
  // with only one possible value (e.g. Type when everything is a dry van)
  // is skipped instead of sitting there doing nothing.
  const controls = {};
  if(filterBar && focusUnit){
    const back = document.createElement('a');
    back.href = location.pathname;
    back.className = 'filter-back';
    back.textContent = F.back;
    filterBar.appendChild(back);
  } else if(filterBar){
    const uniq = key => [...new Set(visibleInventory.map(i => i[key]).filter(v => v !== undefined && v !== null && String(v).trim() !== ''))];

    const search = document.createElement('input');
    search.type = 'text';
    search.placeholder = F.search;
    search.setAttribute('aria-label', F.search);
    filterBar.appendChild(search);
    controls.search = search;

    function addSelect(labelAll, values, formatter){
      if(values.length < 2) return null;
      const sel = document.createElement('select');
      sel.setAttribute('aria-label', labelAll);
      sel.innerHTML = `<option value="">${labelAll}</option>` +
        values.map(v => `<option value="${v}">${formatter ? formatter(v) : v}</option>`).join('');
      filterBar.appendChild(sel);
      return sel;
    }

    // Dual-handle year range — dragging either end sets min/max, like the
    // range sliders on CarGurus/AutoTrader, instead of two separate dropdowns.
    const years = uniq('year').map(Number).filter(n => !isNaN(n));
    if(years.length > 1){
      const yearMin = Math.min(...years), yearMax = Math.max(...years);
      const wrap = document.createElement('div');
      wrap.className = 'range-slider';
      wrap.innerHTML = `
        <div class="range-slider-label">
          <span>${F.year}</span>
          <span class="range-slider-value"><b class="yr-min-val">${yearMin}</b> – <b class="yr-max-val">${yearMax}</b></span>
        </div>
        <div class="range-track">
          <div class="range-fill yr-fill"></div>
          <input type="range" class="range-input yr-min-input" min="${yearMin}" max="${yearMax}" step="1" value="${yearMin}" aria-label="${F.yearMin}">
          <input type="range" class="range-input yr-max-input" min="${yearMin}" max="${yearMax}" step="1" value="${yearMax}" aria-label="${F.yearMax}">
        </div>
      `;
      filterBar.appendChild(wrap);

      const minInput = wrap.querySelector('.yr-min-input');
      const maxInput = wrap.querySelector('.yr-max-input');
      const fill = wrap.querySelector('.yr-fill');
      const minVal = wrap.querySelector('.yr-min-val');
      const maxVal = wrap.querySelector('.yr-max-val');

      function updateYearUI(){
        const lo = Number(minInput.value), hi = Number(maxInput.value);
        minVal.textContent = lo;
        maxVal.textContent = hi;
        fill.style.left = (((lo - yearMin) / (yearMax - yearMin)) * 100) + '%';
        fill.style.right = (100 - ((hi - yearMin) / (yearMax - yearMin)) * 100) + '%';
      }
      updateYearUI();

      minInput.addEventListener('input', () => {
        if(Number(minInput.value) > Number(maxInput.value)) minInput.value = maxInput.value;
        updateYearUI(); render();
      });
      maxInput.addEventListener('input', () => {
        if(Number(maxInput.value) < Number(minInput.value)) maxInput.value = minInput.value;
        updateYearUI(); render();
      });

      controls.yearMin = minInput;
      controls.yearMax = maxInput;
      controls._yearReset = () => { minInput.value = yearMin; maxInput.value = yearMax; updateYearUI(); };
    }

    controls.make = addSelect(F.make, uniq('make').sort());
    controls.susp = addSelect(F.susp, uniq('suspension').sort(), trSusp);
    controls.type = addSelect(F.type, uniq('type').sort(), trType);

    // Single-handle max-price slider — shoppers look for "under $X," not
    // "$X and up," so this only ever sets a ceiling, not a floor.
    const prices = visibleInventory.map(i => i.price).filter(p => typeof p === 'number');
    if(prices.length > 1){
      const step = 2500;
      const priceMin = Math.floor(Math.min(...prices) / step) * step;
      const priceMax = Math.ceil(Math.max(...prices) / step) * step;
      if(priceMin !== priceMax){
        const wrap = document.createElement('div');
        wrap.className = 'range-slider';
        wrap.innerHTML = `
          <div class="range-slider-label">
            <span>${F.priceLabel}</span>
            <span class="range-slider-value pr-val">${F.price}</span>
          </div>
          <div class="range-track">
            <div class="range-fill pr-fill"></div>
            <input type="range" class="range-input pr-input" min="${priceMin}" max="${priceMax}" step="${step}" value="${priceMax}" aria-label="${F.priceLabel}">
          </div>
        `;
        filterBar.appendChild(wrap);

        const input = wrap.querySelector('.pr-input');
        const fill = wrap.querySelector('.pr-fill');
        const val = wrap.querySelector('.pr-val');

        function updatePriceUI(){
          const v = Number(input.value);
          val.textContent = v >= priceMax ? F.price : `${F.upto} $${v.toLocaleString()}`;
          fill.style.left = '0%';
          fill.style.right = (100 - ((v - priceMin) / (priceMax - priceMin)) * 100) + '%';
        }
        updatePriceUI();

        input.addEventListener('input', () => { updatePriceUI(); render(); });

        controls.price = input;
        controls._priceReset = () => { input.value = priceMax; updatePriceUI(); };
      }
    }

    const clear = document.createElement('button');
    clear.type = 'button';
    clear.className = 'filter-clear';
    clear.textContent = F.clear;
    clear.addEventListener('click', () => {
      if(controls.search) controls.search.value = '';
      if(controls.make) controls.make.value = '';
      if(controls.susp) controls.susp.value = '';
      if(controls.type) controls.type.value = '';
      if(controls._yearReset) controls._yearReset();
      if(controls._priceReset) controls._priceReset();
      render();
    });
    filterBar.appendChild(clear);

    const count = document.createElement('div');
    count.className = 'filter-count';
    filterBar.appendChild(count);
    controls.count = count;

    // Year and price already have their own 'input' listeners wired above
    // (with min/max clamping for the year handles); only the plain selects
    // need a generic 'change' listener here.
    if(controls.search) controls.search.addEventListener('input', () => render());
    ['make','susp','type'].forEach(k => {
      if(controls[k]) controls[k].addEventListener('change', () => render());
    });
  }

  // Card labels are translated; the data itself (make, "Dry Van", "Air",
  // measurements) stays as-is since it's proper nouns and numbers.
  const T = IS_ES
    ? {unit:'UNIDAD', soon:'Foto próximamente', year:'Año',
       length:'Longitud', type:'Tipo', susp:'Suspensión', inquire:'Consultar →',
       contact:'contact.html', financing:'financing.html', apply:'Financiar →',
       share:'Compartir', copied:'¡Copiado!',
       copyPrompt:'Copie este enlace:', prevPhoto:'Foto anterior', nextPhoto:'Foto siguiente',
       status:{Available:'Disponible', Hold:'Apartado', Sold:'Vendido', 'Pending Sale':'Venta Pendiente'}}
    : {unit:'UNIT', soon:'Photo Coming Soon', year:'Year',
       length:'Length', type:'Type', susp:'Suspension', inquire:'Inquire →',
       contact:'contact.html', financing:'financing.html', apply:'Apply →',
       share:'Share', copied:'Copied!',
       copyPrompt:'Copy this link:', prevPhoto:'Previous photo', nextPhoto:'Next photo',
       status:{}};

  async function shareLink(item, btn){
    const path = IS_ES ? '/es/inventory.html' : '/inventory.html';
    const url = `${location.origin}${path}?unit=${encodeURIComponent(item.unit)}`;

    // On phones/tablets (and some desktop browsers) this opens the native
    // share sheet — text, email, WhatsApp, etc. — instead of just copying.
    if(navigator.share){
      try {
        await navigator.share({ title: item.title, text: `${item.title} — $${item.price.toLocaleString()}`, url });
        return;
      } catch (e) {
        if(e.name === 'AbortError') return; // user closed the share sheet
        // otherwise fall through to the clipboard fallback below
      }
    }

    // innerHTML (not textContent) so this also works for icon-only share
    // buttons like the lightbox's — swapping textContent would wipe the SVG.
    const original = btn.innerHTML;
    try {
      await navigator.clipboard.writeText(url);
      btn.textContent = T.copied;
    } catch (e) {
      try { window.prompt(T.copyPrompt, url); } catch (e2) { /* nothing more we can do */ }
    }
    setTimeout(() => { btn.innerHTML = original; }, 1600);
  }

  function buildCard(item){
    const card = document.createElement('article');
    card.className = 'tag-card';
    const photos = Array.isArray(item.photos) ? item.photos : [];
    const hasPhoto = photos.length > 0;
    const statusLabel = T.status[item.status] || item.status;

    card.innerHTML = `
      <div class="tag-photo${hasPhoto ? ' has-photo clickable' : ''}">
        <span class="badge ${badgeClass(item.status)}">${statusLabel}</span>
        ${hasPhoto
          ? `<img src="${photos[0]}" alt="${item.title}" loading="lazy">
             ${photos.length > 1 ? `
               <button type="button" class="tag-photo-nav tag-photo-prev" aria-label="${T.prevPhoto}">&lsaquo;</button>
               <button type="button" class="tag-photo-nav tag-photo-next" aria-label="${T.nextPhoto}">&rsaquo;</button>
               <span class="photo-count">1 / ${photos.length}</span>
             ` : ''}`
          : `<span class="photo-placeholder">${T.soon}</span>`}
      </div>
      <div class="tag-body">
        <div class="tag-unit">${T.unit} ${item.unit}</div>
        ${item.vin ? `<div class="tag-vin">VIN ${item.vin}</div>` : ''}
        <h3 class="tag-title">${item.make}</h3>
        <div class="tag-specs">
          <div>${T.year}<b>${item.year}</b></div>
          <div>${T.length}<b>${item.length}</b></div>
          <div>${T.type}<b>${trType(item.type)}</b></div>
          <div>${T.susp}<b>${trSusp(item.suspension) || '—'}</b></div>
        </div>
        <div class="tag-footer">
          <span class="tag-price">$${item.price.toLocaleString()}</span>
          <div class="tag-actions">
            <button type="button" class="tag-share">${T.share}</button>
            <button type="button" class="tag-link">${T.inquire}</button>
          </div>
        </div>
      </div>
    `;
    // Declared out here (not just inside the hasPhoto block) so the Inquire
    // button below can reference "whichever photo was showing" even for a
    // unit with no photos yet (it just stays 0, an empty lightbox feed).
    let photoIdx = 0;

    if (hasPhoto) {
      const photoEl = card.querySelector('.tag-photo');
      const imgEl = photoEl.querySelector('img');
      const countEl = photoEl.querySelector('.photo-count');

      // Lets a visitor flip through a trailer's photos right on the grid
      // card — no need to open the lightbox just to browse.
      function showPhoto(i){
        photoIdx = (i + photos.length) % photos.length;
        imgEl.src = photos[photoIdx];
        if(countEl) countEl.textContent = `${photoIdx + 1} / ${photos.length}`;
      }

      const prevBtn = photoEl.querySelector('.tag-photo-prev');
      const nextBtn = photoEl.querySelector('.tag-photo-next');
      if(prevBtn) prevBtn.addEventListener('click', (e) => { e.stopPropagation(); showPhoto(photoIdx - 1); });
      if(nextBtn) nextBtn.addEventListener('click', (e) => { e.stopPropagation(); showPhoto(photoIdx + 1); });
      if(photos.length > 1){
        wireDragCarousel(photoEl, imgEl, {
          count: () => photos.length,
          getIndex: () => photoIdx,
          photoUrl: (i) => photos[i],
          onSettle: (delta) => showPhoto(photoIdx + delta),
        });

        if(isTouchDevice){
          const hintObserver = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
              if(!entry.isIntersecting) return;
              imgEl.classList.add('swipe-hint');
              imgEl.addEventListener('animationend', () => imgEl.classList.remove('swipe-hint'), { once: true });
              hintObserver.disconnect();
            });
          }, { threshold: 0.5 });
          hintObserver.observe(photoEl);
        }
      }

      // The whole card opens the big photo view — except the controls that
      // have their own job (Share, Inquire, the in-card prev/next arrows).
      card.classList.add('clickable');
      card.addEventListener('click', (e) => {
        if(e.target.closest('.tag-share, .tag-link, .tag-photo-nav')) return;
        openLightbox({ item, index: photoIdx, T, trSusp, trType, shareLink });
      });
    }
    card.querySelector('.tag-share').addEventListener('click', (e) => shareLink(item, e.currentTarget));
    // Inquire opens the same lightbox, straight to the prefilled inquiry
    // form — no more sending people to a separate Contact page where they'd
    // have to type out which trailer they mean.
    card.querySelector('.tag-link').addEventListener('click', (e) => {
      e.stopPropagation();
      openLightbox({ item, index: photoIdx, T, trSusp, trType, shareLink, startOpen: true });
    });
    return card;
  }

  function render(){
    if(focusUnit){
      const item = inventory.find(i => (i.unit || '').toLowerCase() === focusUnit.toLowerCase());
      grid.innerHTML = '';
      if(emptyState) emptyState.style.display = 'none';
      if(!item){
        grid.innerHTML = `<div class="empty-state">${F.notFound}</div>`;
        return;
      }
      grid.appendChild(buildCard(item));
      return;
    }

    const q = (controls.search?.value || '').trim().toLowerCase();
    const minYear = controls.yearMin?.value ? Number(controls.yearMin.value) : null;
    const maxYear = controls.yearMax?.value ? Number(controls.yearMax.value) : null;
    const make = controls.make?.value || '';
    const susp = controls.susp?.value || '';
    const type = controls.type?.value || '';
    const maxPrice = controls.price?.value ? Number(controls.price.value) : null;

    let filtered = visibleInventory.filter(item => {
      const haystack = [item.unit, item.title, item.length, item.make, item.vin]
        .filter(Boolean).join(' ').toLowerCase();
      if(q && !haystack.includes(q)) return false;
      if(minYear !== null && Number(item.year) < minYear) return false;
      if(maxYear !== null && Number(item.year) > maxYear) return false;
      if(make && item.make !== make) return false;
      if(susp && item.suspension !== susp) return false;
      if(type && item.type !== type) return false;
      if(maxPrice !== null && Number(item.price) > maxPrice) return false;
      return true;
    });

    // Sold/pending-sale units are still shown (badged), but sink below
    // everything actually for sale so shoppers see available inventory first.
    const isSpokenFor = s => s === 'Sold' || s === 'Pending Sale';
    filtered.sort((a, b) => (isSpokenFor(a.status) ? 1 : 0) - (isSpokenFor(b.status) ? 1 : 0));

    const matchCount = filtered.length;
    filtered = filtered.slice(0, limit);

    if(controls.count) controls.count.textContent = F.showing(matchCount, visibleInventory.length);

    grid.innerHTML = '';
    if(emptyState) emptyState.style.display = filtered.length ? 'none' : 'block';

    filtered.forEach(item => grid.appendChild(buildCard(item)));
  }

  render();
}

