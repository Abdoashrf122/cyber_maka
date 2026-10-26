// سيبر مكة — متابعة الطلب (track.html#t=<token>) — التوكن في الـ hash فمابيوصلش لأي سجلات سيرفر
import { call, errText, money, durationText, time12, waLink, el } from './api.js';

const box = document.getElementById('box');
const token = new URLSearchParams(location.hash.slice(1)).get('t');
let data = null;
let timer = null;
let tick = null;
let busy = false;

if (!token) {
  box.replaceChildren(el('p', {}, 'اللينك ناقص. افتح اللينك اللي ظهر لك بعد الحجز، أو احجز من جديد.'),
    el('a', { class: 'btn', href: './#book' }, 'احجز'));
} else {
  load();
}

async function load() {
  const r = await call('web_booking_status', { p_token: token });
  if (!r.ok) {
    if (!data) box.replaceChildren(el('p', { class: 'bad-t' }, errText(r)), el('a', { class: 'btn', href: './#book' }, 'احجز من جديد'));
    schedule(15000);
    return;
  }
  const changed = !data || data.status !== r.booking.status;
  data = r.booking;
  data.loadedAt = Date.now();
  if (changed || !busy) render();
  const live = ['pending', 'awaiting_payment', 'payment_claimed'].includes(data.status);
  schedule(live ? 6000 : 60000);
}

function schedule(ms) {
  clearTimeout(timer);
  timer = setTimeout(load, document.hidden ? Math.max(ms, 20000) : ms);
}
document.addEventListener('visibilitychange', () => { if (!document.hidden) load(); });

function secondsLeft(field) {
  if (data[field] == null) return null;
  return Math.max(0, data[field] - Math.floor((Date.now() - data.loadedAt) / 1000));
}
const mmss = (s) => `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;

function startTick(field, node) {
  clearInterval(tick);
  const upd = () => {
    const s = secondsLeft(field);
    node.textContent = s == null ? '' : mmss(s);
    if (s === 0) { clearInterval(tick); load(); }
  };
  upd();
  tick = setInterval(upd, 1000);
}

function copyBtn(text) {
  return el('button', {
    type: 'button', class: 'btn small ghost',
    onclick: async (e) => {
      try { await navigator.clipboard.writeText(text); e.currentTarget.textContent = 'اتنسخ ✓'; } catch { /* المتصفح رافض */ }
    },
  }, 'نسخ');
}

function details() {
  const b = data;
  const rows = [
    ['الفرع', b.branch.name],
    ['الحجز', b.offering.kind === 'pc' ? `${b.offering.name} × ${b.units}` : b.offering.name],
    ['اليوم', b.date],
    ['الميعاد', `${time12(b.time)} — ${time12(b.end_time)} (${durationText(b.duration_min)})`],
    b.price_total != null && ['الحساب المتوقع', money(b.price_total)],
  ].filter(Boolean);
  const wa = waLink(b.branch.whatsapp);
  return el('div', {},
    el('div', { class: 'details' }, rows.map(([k, v]) => el('div', {}, el('span', {}, k), el('b', {}, v)))),
    el('div', { class: 'row', style: 'justify-content:center;margin-top:14px' },
      b.branch.maps_url && el('a', { class: 'btn small ghost', href: b.branch.maps_url, target: '_blank', rel: 'noopener' }, '🗺️ اللوكيشن'),
      wa && el('a', { class: 'btn small ghost', href: wa, target: '_blank', rel: 'noopener' }, 'واتساب الفرع'),
      b.branch.phone && el('a', { class: 'btn small ghost', href: `tel:${b.branch.phone}` }, '📞 اتصل بالفرع')));
}

function cancelBtn() {
  return el('button', {
    type: 'button', class: 'btn small danger', style: 'margin-top:16px',
    onclick: async () => {
      if (!window.confirm('متأكد إنك عايز تلغي الطلب؟')) return;
      const r = await call('web_cancel_booking', { p_token: token });
      if (!r.ok) window.alert(errText(r));
      load();
    },
  }, 'إلغاء الطلب');
}

function payBox() {
  const p = data.payment || {};
  const lines = [
    p.instapay_address && ['InstaPay (عنوان الدفع)', p.instapay_address],
    p.instapay_phone && ['InstaPay (رقم الموبايل)', p.instapay_phone],
    p.telda_handle && ['Telda', p.telda_handle],
    p.wallet_phone && ['محفظة', p.wallet_phone],
  ].filter(Boolean);
  return el('div', { class: 'pay-box' },
    lines.length
      ? lines.map(([k, v]) => el('div', { class: 'pay-line' }, el('div', {}, el('span', {}, k), el('br'), el('b', {}, v)), copyBtn(v)))
      : el('p', { class: 'muted' }, 'الفرع هيبعتلك طريقة التحويل — أو كلّمه على الواتساب.'),
    p.note && el('p', { class: 'muted', style: 'margin:0' }, p.note));
}

function claimForm() {
  const input = el('input', { id: 'payer', maxlength: '60', autocomplete: 'name', placeholder: 'زي ما هو ظاهر في InstaPay / Telda', value: data.payer_name || '' });
  const err = el('div', { class: 'alert err hidden', role: 'alert' });
  const btn = el('button', { type: 'submit', class: 'btn green block' }, 'حوّلت الـ deposit ✓');
  return el('form', {
    style: 'text-align:start;margin-top:10px',
    onsubmit: async (e) => {
      e.preventDefault();
      err.classList.add('hidden');
      if (input.value.trim().length < 2) { err.textContent = errText({ error: 'bad_payer' }); err.classList.remove('hidden'); return; }
      btn.disabled = true;
      busy = true;
      const r = await call('web_claim_paid', { p_token: token, p_payer_name: input.value.trim() });
      busy = false;
      btn.disabled = false;
      if (!r.ok) { err.textContent = errText(r); err.classList.remove('hidden'); return; }
      data = null;
      load();
    },
  },
  el('div', { class: 'field' }, el('label', { for: 'payer' }, 'اسم صاحب الحساب اللي حوّلت منه'), input,
    el('span', { class: 'hint' }, 'بيساعدنا نلاقي التحويل بسرعة.')),
  err, btn);
}

function render() {
  clearInterval(tick);
  const b = data;
  const head = (icon, title, cls) => [el('div', { class: 'status-icon', 'aria-hidden': 'true' }, icon), el('h1', { class: cls || '' }, title)];
  const code = el('div', {}, el('span', { class: 'muted' }, 'كود الحجز'), el('br'), el('span', { class: 'code' }, b.code));
  let body;
  switch (b.status) {
    case 'pending': {
      const cd = el('div', { class: 'countdown' });
      body = [...head('⏳', 'طلبك وصل للفرع', 'warn-t'),
        el('p', { class: 'muted' }, `أهلاً ${b.customer_name || ''} — الفرع بيراجع الطلب دلوقتي. أول ما يوافق هيظهر لك هنا مبلغ الـ deposit وطريقة التحويل.`),
        el('div', { class: 'muted', style: 'font-size:14px' }, 'الرد في خلال'), cd,
        code, details(), cancelBtn()];
      box.replaceChildren(...body);
      startTick('approve_seconds_left', cd);
      return;
    }
    case 'awaiting_payment': {
      const cd = el('div', { class: 'countdown' });
      body = [...head('✅', 'الفرع وافق! حوّل الـ deposit', 'ok-t'),
        el('div', { class: 'amount' }, money(b.deposit)),
        el('p', { class: 'muted', style: 'margin:0' }, 'حوّل المبلغ ده بالظبط (من غير زيادة أو نقصان) — عشان التحويل يتعرف عليه تلقائي.'),
        el('div', { class: 'muted', style: 'font-size:14px;margin-top:10px' }, 'المهلة الباقية'), cd,
        payBox(), claimForm(),
        el('p', { class: 'muted', style: 'font-size:13px' }, b.deposit_policy),
        code, details(), cancelBtn()];
      box.replaceChildren(...body);
      startTick('pay_seconds_left', cd);
      return;
    }
    case 'payment_claimed':
      body = [...head('🔎', 'بنراجع التحويل', 'warn-t'),
        el('p', { class: 'muted' }, `شكرًا! أول ما تحويل ${money(b.deposit)} يوصل الحجز هيتأكد هنا. لو اتأخر، ابعت صورة التحويل للفرع على الواتساب.`),
        payBox(), code, details()];
      break;
    case 'confirmed':
      body = [...head('🎉', 'حجزك متأكد', 'ok-t'),
        el('p', { class: 'muted' }, 'اعرض كود الحجز ده في الفرع. الـ deposit بيتخصم من حسابك.'),
        code, details()];
      break;
    case 'completed':
      body = [...head('🏁', 'الحجز خلص — نورتنا!'), code, details(), el('a', { class: 'btn', href: './#book', style: 'margin-top:16px' }, 'احجز تاني')];
      break;
    default: {
      const title = { rejected: 'الطلب اترفض', expired: 'الطلب انتهى', cancelled: 'الطلب اتلغى', no_show: 'الحجز اتسجّل غياب' }[b.status] || 'الطلب مش شغال';
      body = [...head('✖️', title, 'bad-t'),
        b.reason && el('p', { class: 'muted' }, b.reason),
        el('a', { class: 'btn', href: './#book', style: 'margin:10px 0' }, 'اختار ميعاد تاني'),
        code, details()];
    }
  }
  box.replaceChildren(...body.filter(Boolean));
}
