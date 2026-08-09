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

// ---------- Photo lightbox (click a trailer photo to view all of them) ----------
let lightboxPhotos = [];
let lightboxIndex = 0;

function ensureLightbox(){
  if(document.getElementById('lightbox')) return;
  const el = document.createElement('div');
  el.id = 'lightbox';
  el.className = 'lightbox';
  el.hidden = true;
  el.innerHTML = `
    <button class="lightbox-close" aria-label="Close">&times;</button>
    <button class="lightbox-prev" aria-label="Previous photo">&lsaquo;</button>
    <img class="lightbox-img" src="" alt="">
    <button class="lightbox-next" aria-label="Next photo">&rsaquo;</button>
    <div class="lightbox-count"></div>
  `;
  document.body.appendChild(el);

  el.querySelector('.lightbox-close').addEventListener('click', closeLightbox);
  el.querySelector('.lightbox-prev').addEventListener('click', () => showLightboxPhoto(-1));
  el.querySelector('.lightbox-next').addEventListener('click', () => showLightboxPhoto(1));
  el.addEventListener('click', (e) => { if(e.target === el) closeLightbox(); });
  document.addEventListener('keydown', (e) => {
    if(document.getElementById('lightbox')?.hidden) return;
    if(e.key === 'Escape') closeLightbox();
    if(e.key === 'ArrowLeft') showLightboxPhoto(-1);
    if(e.key === 'ArrowRight') showLightboxPhoto(1);
  });
}

function renderLightboxPhoto(){
  const el = document.getElementById('lightbox');
  if(!el) return;
  el.querySelector('.lightbox-img').src = lightboxPhotos[lightboxIndex];
  el.querySelector('.lightbox-count').textContent = `${lightboxIndex + 1} / ${lightboxPhotos.length}`;
  const multi = lightboxPhotos.length > 1;
  el.querySelector('.lightbox-prev').style.display = multi ? '' : 'none';
  el.querySelector('.lightbox-next').style.display = multi ? '' : 'none';
}

function openLightbox(photos, index, title){
  ensureLightbox();
  lightboxPhotos = photos;
  lightboxIndex = index || 0;
  const el = document.getElementById('lightbox');
  el.querySelector('.lightbox-img').alt = title || '';
  el.hidden = false;
  document.body.style.overflow = 'hidden';
  renderLightboxPhoto();
}

function closeLightbox(){
  const el = document.getElementById('lightbox');
  if(!el) return;
  el.hidden = true;
  document.body.style.overflow = '';
}

function showLightboxPhoto(delta){
  lightboxIndex = (lightboxIndex + delta + lightboxPhotos.length) % lightboxPhotos.length;
  renderLightboxPhoto();
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
  return 'badge-sold';
}

async function renderInventory(gridId, opts = {}){
  const grid = document.getElementById(gridId);
  if(!grid) return;
  const emptyState = document.getElementById(opts.emptyStateId || 'emptyState');
  const filterBar = document.getElementById(opts.filterBarId || 'filterBar');
  const limit = opts.limit || Infinity;

  grid.innerHTML = `<div class="empty-state">${IS_ES ? 'Cargando inventario…' : 'Loading inventory…'}</div>`;
  await loadInventory();

  const F = IS_ES
    ? {search:'Buscar por unidad, marca o VIN…', year:'Cualquier año', make:'Cualquier marca',
       susp:'Cualquier suspensión', type:'Cualquier tipo', price:'Cualquier precio',
       newer:'o más nuevo', upto:'Hasta', clear:'Limpiar filtros',
       showing:(n,t)=>`Mostrando ${n} de ${t} remolques`}
    : {search:'Search unit #, make, or VIN…', year:'Any year', make:'Any make',
       susp:'Any suspension', type:'Any type', price:'Any price',
       newer:'& newer', upto:'Up to', clear:'Clear filters',
       showing:(n,t)=>`Showing ${n} of ${t} trailers`};

  // Controls are generated from the data that's actually published, so the
  // dropdowns never offer a value that returns zero results, and a filter
  // with only one possible value (e.g. Type when everything is a dry van)
  // is skipped instead of sitting there doing nothing.
  const controls = {};
  if(filterBar){
    const uniq = key => [...new Set(inventory.map(i => i[key]).filter(v => v !== undefined && v !== null && String(v).trim() !== ''))];

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

    const years = uniq('year').sort((a,b) => b - a);
    controls.year = addSelect(F.year, years, y => `${y} ${F.newer}`);

    controls.make = addSelect(F.make, uniq('make').sort());
    controls.susp = addSelect(F.susp, uniq('suspension').sort());
    controls.type = addSelect(F.type, uniq('type').sort());

    const prices = inventory.map(i => i.price).filter(p => typeof p === 'number');
    if(prices.length){
      const step = 2500;
      const top = Math.ceil(Math.max(...prices) / step) * step;
      const brackets = [];
      for(let p = step; p <= top; p += step){
        if(p >= Math.min(...prices)) brackets.push(p);
      }
      controls.price = addSelect(F.price, brackets, p => `${F.upto} $${p.toLocaleString()}`);
    }

    const clear = document.createElement('button');
    clear.type = 'button';
    clear.className = 'filter-clear';
    clear.textContent = F.clear;
    clear.addEventListener('click', () => {
      Object.values(controls).forEach(c => { if(c) c.value = ''; });
      render();
    });
    filterBar.appendChild(clear);

    const count = document.createElement('div');
    count.className = 'filter-count';
    filterBar.appendChild(count);
    controls.count = count;

    if(controls.search) controls.search.addEventListener('input', () => render());
    ['year','make','susp','type','price'].forEach(k => {
      if(controls[k]) controls[k].addEventListener('change', () => render());
    });
  }

  function render(){
    const q = (controls.search?.value || '').trim().toLowerCase();
    const minYear = controls.year?.value ? Number(controls.year.value) : null;
    const make = controls.make?.value || '';
    const susp = controls.susp?.value || '';
    const type = controls.type?.value || '';
    const maxPrice = controls.price?.value ? Number(controls.price.value) : null;

    let filtered = inventory.filter(item => {
      const haystack = [item.unit, item.title, item.length, item.make, item.vin]
        .filter(Boolean).join(' ').toLowerCase();
      if(q && !haystack.includes(q)) return false;
      if(minYear !== null && Number(item.year) < minYear) return false;
      if(make && item.make !== make) return false;
      if(susp && item.suspension !== susp) return false;
      if(type && item.type !== type) return false;
      if(maxPrice !== null && Number(item.price) > maxPrice) return false;
      return true;
    });

    const matchCount = filtered.length;
    filtered = filtered.slice(0, limit);

    if(controls.count) controls.count.textContent = F.showing(matchCount, inventory.length);

    grid.innerHTML = '';
    if(emptyState) emptyState.style.display = filtered.length ? 'none' : 'block';

    filtered.forEach(item => {
      const card = document.createElement('article');
      card.className = 'tag-card';
      const photos = Array.isArray(item.photos) ? item.photos : [];
      const hasPhoto = photos.length > 0;
      // Card labels are translated; the data itself (make, "Dry Van", "Air",
      // measurements) stays as-is since it's proper nouns and numbers.
      const T = IS_ES
        ? {unit:'UNIDAD', photos:'FOTOS', soon:'Foto próximamente', year:'Año',
           length:'Largo', type:'Tipo', susp:'Suspensión', inquire:'Consultar →',
           contact:'contact.html', status:{Available:'Disponible', Hold:'Apartado', Sold:'Vendido'}}
        : {unit:'UNIT', photos:'PHOTOS', soon:'Photo Coming Soon', year:'Year',
           length:'Length', type:'Type', susp:'Suspension', inquire:'Inquire →',
           contact:'contact.html', status:{}};
      const statusLabel = T.status[item.status] || item.status;

      card.innerHTML = `
        <div class="tag-photo${hasPhoto ? ' has-photo clickable' : ''}">
          <span class="badge ${badgeClass(item.status)}">${statusLabel}</span>
          ${hasPhoto
            ? `<img src="${photos[0]}" alt="${item.title}" loading="lazy">
               ${photos.length > 1 ? `<span class="photo-count">${photos.length} ${T.photos}</span>` : ''}`
            : `<span class="photo-placeholder">${T.soon}</span>`}
        </div>
        <div class="tag-body">
          <div class="tag-unit">${T.unit} ${item.unit}</div>
          ${item.vin ? `<div class="tag-vin">VIN ${item.vin}</div>` : ''}
          <h3 class="tag-title">${item.title}</h3>
          <div class="tag-specs">
            <div>${T.year}<b>${item.year}</b></div>
            <div>${T.length}<b>${item.length}</b></div>
            <div>${T.type}<b>${item.type}</b></div>
            <div>${T.susp}<b>${item.suspension || '—'}</b></div>
          </div>
          <div class="tag-footer">
            <span class="tag-price">$${item.price.toLocaleString()}</span>
            <a href="${T.contact}" class="tag-link">${T.inquire}</a>
          </div>
        </div>
      `;
      if (hasPhoto) {
        card.querySelector('.tag-photo').addEventListener('click', () => openLightbox(photos, 0, item.title));
      }
      grid.appendChild(card);
    });
  }

  render();
}

