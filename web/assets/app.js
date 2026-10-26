// سيبر مكة — الصفحة الرئيسية: الفروع + الحجز
import { call, errText, money, durationText, dayLabel, addDays, time12, waLink, myBookings, saveBooking, el, deviceId } from './api.js';

const $ = (id) => document.getElementById(id);
let cat = null;
const st = { branch: null, off: null, units: 1, duration: 60, day: null, slot: null };
let slotsReq = 0;

const KIND_ICON = { pc: '💻', ps_room: '🎮' };
const priceUnit = (o) => (o.kind === 'pc' ? 'للجهاز في الساعة' : 'للغرفة في الساعة');

init();

async function init() {
  renderMine();
  cat = await call('web_catalog');
  if (!cat.ok) {
    $('branch-list').replaceChildren(el('p', { class: 'alert err' }, errText(cat)));
    return;
  }
  st.duration = cat.min_duration_min;
  if (!cat.show_prices) $('branches-sub').textContent = 'الصور واللوكيشن';
  renderBranches();
  renderBranchPicker();
  $('policy-text').textContent = `فاهم إن الحجز بيتأكد بعد تحويل الـ deposit، و${cat.deposit_policy}`;
  if (!cat.booking_enabled) {
    $('closed').textContent = cat.closed_message;
    $('closed').classList.remove('hidden');
    $('form').classList.add('hidden');
  }
  // لينك مباشر لفرع: /?branch=fleming#book
  const slug = new URLSearchParams(location.search).get('branch');
  const pre = cat.branches.find((b) => b.slug === slug);
  if (pre) pickBranch(pre);
}

function renderMine() {
  const list = myBookings();
  if (!list.length) return;
  $('mine').replaceChildren(...list.slice(0, 5).map((b) =>
    el('a', { href: `track.html#t=${encodeURIComponent(b.token)}` },
      el('span', {}, `${b.title || 'حجز'} — ${b.when || ''}`),
      el('b', {}, `#${b.code}`))));
  $('mine-box').classList.remove('hidden');
}

function renderBranches() {
  if (!cat.branches.length) {
    $('branch-list').replaceChildren(el('p', { class: 'empty-note' }, 'مفيش فروع متاحة دلوقتي.'));
    return;
  }
  $('branch-list').replaceChildren(...cat.branches.map((b) => {
    const gallery = branchGallery(b);
    const wa = waLink(b.whatsapp);
    return el('article', { class: 'branch' },
      gallery,
      el('div', { class: 'branch-body' },
        el('h3', {}, b.name),
        el('div', { class: 'meta' },
          b.address && el('span', {}, `📍 ${b.address}`),
          el('span', {}, `🕒 ${b.hours_text || (b.open_24h ? 'مفتوح 24 ساعة' : `${time12(b.open_time)} — ${time12(b.close_time)}`)}`)),
        el('ul', { class: 'prices' }, b.offerings.map((o) =>
          el('li', {}, el('span', {}, `${KIND_ICON[o.kind] || ''} ${o.name}`),
            cat.show_prices && el('b', {}, `${money(o.price_per_hour)} ${o.kind === 'pc' ? '/ جهاز / ساعة' : '/ ساعة'}`)))),
        el('div', { class: 'row' },
          el('a', { class: 'btn small', href: '#book', onclick: () => pickBranch(b) }, 'احجز في الفرع ده'),
          b.maps_url && el('a', { class: 'btn small ghost', href: b.maps_url, target: '_blank', rel: 'noopener' }, '🗺️ اللوكيشن'),
          wa && el('a', { class: 'btn small ghost', href: wa, target: '_blank', rel: 'noopener' }, 'واتساب'),
          b.phone && el('a', { class: 'btn small ghost', href: `tel:${b.phone}` }, '📞 اتصل'))));
  }));
}

function branchGallery(branch) {
  if (!branch.photos.length) return el('div', { class: 'gallery empty', 'aria-hidden': 'true' }, '🎮');

  const gallery = el('div', { class: 'gallery', 'aria-label': `صور ${branch.name}` });
  const slides = branch.photos.map((photo, index) => {
    const src = `/photos/${photo.path}?v=${encodeURIComponent(photo.version || 0)}`;
    return el('div', {
      class: `gallery-slide${index === 0 ? ' is-active' : ''}`,
      'aria-hidden': String(index !== 0),
    },
      el('img', { class: 'gallery-backdrop', src, alt: '', 'aria-hidden': 'true', loading: 'lazy' }),
      el('img', {
        class: 'gallery-photo',
        src,
        alt: photo.caption || `صورة ${index + 1} من ${branch.name}`,
        loading: index === 0 ? 'eager' : 'lazy',
      }),
      el('span', { class: 'gallery-caption' }, photo.caption || branch.name));
  });
  const stage = el('div', { class: 'gallery-stage', tabindex: '0', role: 'group', 'aria-label': `صور ${branch.name}` },
    slides,
    el('span', { class: 'gallery-sheen', 'aria-hidden': 'true' }));
  gallery.classList.toggle('single', slides.length === 1);
  const counter = el('span', { class: 'gallery-count', 'aria-live': 'polite' }, `01 / ${String(slides.length).padStart(2, '0')}`);
  const dots = branch.photos.map((photo, index) =>
    el('button', {
      class: `gallery-dot${index === 0 ? ' is-active' : ''}`,
      type: 'button',
      'aria-label': `عرض الصورة ${index + 1}`,
      'aria-current': index === 0 ? 'true' : null,
    }));
  const previous = el('button', {
    class: 'gallery-arrow',
    type: 'button',
    'aria-label': 'الصورة السابقة',
  }, '‹');
  const next = el('button', {
    class: 'gallery-arrow',
    type: 'button',
    'aria-label': 'الصورة التالية',
  }, '›');
  let currentIndex = 0;
  let paused = false;
  const setSlide = (nextIndex) => {
    currentIndex = (nextIndex + slides.length) % slides.length;
    slides.forEach((slide, index) => {
      const active = index === currentIndex;
      slide.classList.toggle('is-active', active);
      slide.setAttribute('aria-hidden', String(!active));
    });
    dots.forEach((dot, index) => {
      const active = index === currentIndex;
      dot.classList.toggle('is-active', active);
      if (active) dot.setAttribute('aria-current', 'true');
      else dot.removeAttribute('aria-current');
    });
    counter.textContent = `${String(currentIndex + 1).padStart(2, '0')} / ${String(slides.length).padStart(2, '0')}`;
  };
  previous.addEventListener('click', () => setSlide(currentIndex - 1));
  next.addEventListener('click', () => setSlide(currentIndex + 1));
  dots.forEach((dot, index) => dot.addEventListener('click', () => setSlide(index)));
  stage.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowLeft') { event.preventDefault(); setSlide(currentIndex - 1); }
    if (event.key === 'ArrowRight') { event.preventDefault(); setSlide(currentIndex + 1); }
  });
  gallery.addEventListener('pointerenter', () => { paused = true; });
  gallery.addEventListener('pointerleave', () => { paused = false; });
  gallery.addEventListener('focusin', () => { paused = true; });
  gallery.addEventListener('focusout', (event) => {
    if (!gallery.contains(event.relatedTarget)) paused = false;
  });
  if (slides.length > 1 && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    window.setInterval(() => {
      if (!paused && !document.hidden) setSlide(currentIndex + 1);
    }, 5000);
  }

  gallery.append(
    stage,
    el('div', { class: 'gallery-tools' },
      el('div', { class: 'gallery-nav' }, previous, next),
      counter,
      el('div', { class: 'gallery-dots', 'aria-label': 'اختار صورة' }, dots)),
  );
  return gallery;
}

function choice(pressed, onclick, title, sub) {
  return el('button', { type: 'button', class: 'choice', 'aria-pressed': String(pressed), onclick },
    el('b', {}, title), sub && el('small', {}, sub));
}

function renderBranchPicker() {
  $('pick-branch').replaceChildren(...cat.branches.map((b) =>
    choice(st.branch?.id === b.id, () => pickBranch(b), b.name, b.address)));
}

function pickBranch(b) {
  st.branch = b;
  st.off = null;
  st.slot = null;
  renderBranchPicker();
  $('pick-off').replaceChildren(...b.offerings.map((o) =>
    choice(false, () => pickOff(o), `${KIND_ICON[o.kind] || ''} ${o.name}`, cat.show_prices ? `${money(o.price_per_hour)} ${priceUnit(o)}` : o.details)));
  if (!b.offerings.length) $('pick-off').replaceChildren(el('p', { class: 'empty-note' }, 'مفيش حجز متاح في الفرع ده دلوقتي.'));
  show('step-off', true);
  show('step-qty', false);
  show('step-day', false);
  show('step-info', false);
}

function pickOff(o) {
  st.off = o;
  st.units = 1;
  st.slot = null;
  [...$('pick-off').children].forEach((c, i) => c.setAttribute('aria-pressed', String(st.branch.offerings[i] === o)));
  $('units-box').classList.toggle('hidden', o.max_per_booking <= 1);
  renderQty();
  show('step-qty', true);
  renderDays();
  show('step-day', true);
  show('step-info', false);
  $('step-qty').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function renderQty() {
  $('units').textContent = st.off?.kind === 'pc' ? `${st.units} ${st.units === 1 ? 'جهاز' : st.units === 2 ? 'جهازين' : 'أجهزة'}` : st.units;
  $('duration').textContent = durationText(st.duration);
  $('u-minus').disabled = st.units <= 1;
  $('u-plus').disabled = !st.off || st.units >= st.off.max_per_booking;
  $('d-minus').disabled = st.duration <= cat.min_duration_min;
  $('d-plus').disabled = st.duration >= cat.max_duration_min;
  renderSummary();
}

$('u-minus').addEventListener('click', () => { st.units = Math.max(1, st.units - 1); renderQty(); loadSlots(); });
$('u-plus').addEventListener('click', () => { st.units = Math.min(st.off.max_per_booking, st.units + 1); renderQty(); loadSlots(); });
$('d-minus').addEventListener('click', () => { st.duration = Math.max(cat.min_duration_min, st.duration - cat.slot_minutes); renderQty(); loadSlots(); });
$('d-plus').addEventListener('click', () => { st.duration = Math.min(cat.max_duration_min, st.duration + cat.slot_minutes); renderQty(); loadSlots(); });

function renderDays() {
  const days = [];
  for (let i = 0; i <= cat.max_days_ahead; i++) days.push(addDays(cat.today, i));
  if (!st.day || !days.includes(st.day)) st.day = days[0];
  $('pick-day').replaceChildren(...days.map((d) => {
    const l = dayLabel(d, cat.today);
    return choice(d === st.day, () => { st.day = d; renderDays(); loadSlots(); }, l.name, l.sub);
  }));
  loadSlots();
}

async function loadSlots() {
  if (!st.off || !st.day) return;
  st.slot = null;
  show('step-info', false);
  const req = ++slotsReq;
  $('slots-note').textContent = 'جاري تحميل المواعيد المتاحة…';
  $('pick-slot').replaceChildren();
  const r = await call('web_slots', { p_offering: st.off.id, p_date: st.day, p_duration_min: st.duration, p_units: st.units });
  if (req !== slotsReq) return; // اختيار أحدث
  if (!r.ok) { $('slots-note').textContent = errText(r); return; }
  if (!r.slots.length) {
    $('slots-note').textContent = 'مفيش مواعيد فاضية في اليوم ده بالمدة/العدد دول — جرّب يوم أو مدة تانية.';
    return;
  }
  $('slots-note').textContent = '';
  $('pick-slot').replaceChildren(...r.slots.map((t) =>
    el('button', { type: 'button', class: 'slot', 'aria-pressed': 'false', onclick: (e) => pickSlot(t, e.currentTarget) }, time12(t))));
}

function pickSlot(t, btn) {
  st.slot = t;
  [...$('pick-slot').children].forEach((c) => c.setAttribute('aria-pressed', String(c === btn)));
  renderSummary();
  show('step-info', true);
  $('step-info').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function renderSummary() {
  if (!st.off) return;
  const total = (st.off.price_per_hour * st.units * st.duration) / 60;
  const l = st.day ? dayLabel(st.day, cat.today) : null;
  $('summary').replaceChildren(
    el('div', {}, el('span', {}, 'الفرع'), el('b', {}, st.branch.name)),
    el('div', {}, el('span', {}, 'الحجز'), el('b', {}, st.off.kind === 'pc' ? `${st.off.name} × ${st.units}` : st.off.name)),
    st.slot && el('div', {}, el('span', {}, 'الميعاد'), el('b', {}, `${l.name} ${l.sub} — ${time12(st.slot)}`)),
    el('div', {}, el('span', {}, 'المدة'), el('b', {}, durationText(st.duration))),
    cat.show_prices && el('div', { class: 'total' }, el('span', {}, 'الحساب المتوقع'), el('span', {}, money(total))),
    Number(st.off.deposit) > 0 && el('div', {}, el('span', {}, 'الـ deposit (بعد موافقة الفرع)'), el('b', {}, `${money(st.off.deposit)} تقريبًا`)));
}

function show(id, on) { $(id).classList.toggle('hidden', !on); }

$('form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const err = $('err');
  err.classList.add('hidden');
  const fail = (m) => { err.textContent = m; err.classList.remove('hidden'); };
  if (!st.off || !st.slot) return fail('اختار الميعاد الأول.');
  const name = $('name').value.trim();
  const phone = $('phone').value.trim();
  if (name.length < 2) return fail(errText({ error: 'bad_name' }));
  if (phone.replace(/\D/g, '').length < 10) return fail(errText({ error: 'bad_phone' }));
  if (!$('agree').checked) return fail('لازم توافق على سياسة الـ deposit.');
  const btn = $('submit');
  btn.disabled = true;
  btn.textContent = 'جاري الإرسال…';
  const r = await call('web_create_booking', {
    p_offering: st.off.id, p_date: st.day, p_time: st.slot, p_duration_min: st.duration, p_units: st.units,
    p_name: name, p_phone: phone, p_note: $('note').value.trim() || null, p_device: deviceId(),
  });
  btn.disabled = false;
  btn.textContent = 'ابعت طلب الحجز';
  if (!r.ok) {
    fail(errText(r));
    if (r.error === 'full' || r.error === 'too_soon') loadSlots();
    return;
  }
  const l = dayLabel(st.day, cat.today);
  saveBooking({ token: r.token, code: r.code, title: `${st.branch.name} · ${st.off.name}`, when: `${l.name} ${l.sub} ${time12(st.slot)}` });
  location.href = `track.html#t=${encodeURIComponent(r.token)}`;
});
