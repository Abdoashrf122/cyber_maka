// سيبر مكة — كلام الموقع مع السيرفر (نفس الدومين: /api/<دالة>) + أدوات مشتركة

export async function call(fn, body = {}) {
  let res;
  try {
    res = await fetch(`/api/${fn}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch {
    return { ok: false, error: 'network' };
  }
  try {
    const data = await res.json();
    if (!res.ok) return { ok: false, error: 'server', status: res.status };
    return data;
  } catch {
    return { ok: false, error: 'server', status: res.status };
  }
}

const ERRORS = {
  network: 'مفيش اتصال بالإنترنت — جرّب تاني.',
  server: 'حصلت مشكلة في السيرفر — جرّب كمان شوية.',
  rate_limited: 'طلبات كتير من نفس الجهاز — استنى شوية وجرّب تاني.',
  booking_closed: 'الحجز من الموقع واقف مؤقتًا.',
  bad_name: 'اكتب اسمك (حرفين على الأقل).',
  bad_phone: 'رقم الموبايل لازم يكون مصري 11 رقم ويبدأ بـ 01.',
  bad_time: 'الميعاد ده مش صحيح — اختار ميعاد من القايمة.',
  bad_date: 'اليوم ده مش متاح للحجز.',
  bad_duration: 'المدة دي مش متاحة.',
  bad_units: 'العدد ده مش متاح.',
  too_soon: 'الميعاد قريب أوي — اختار ميعاد بعد شوية.',
  closed_hours: 'الفرع مقفول في الوقت ده.',
  phone_active_limit: 'عندك حجزين شغالين بالفعل على الرقم ده.',
  phone_daily_limit: 'وصلت للحد اليومي للطلبات من الرقم ده.',
  full: 'المكان اتحجز دلوقتي — اختار ميعاد تاني.',
  not_found: 'مش لاقيين الطلب ده.',
  call_store: 'الـ deposit اتحوّل — للإلغاء أو التغيير كلّم الفرع.',
  bad_state: 'حالة الطلب اتغيرت — حدّث الصفحة.',
  bad_payer: 'اكتب الاسم اللي ظاهر في حساب التحويل.',
  blocked: 'مش قادرين نستقبل طلبات حجز من هنا — لو فيه لبس كلّم الفرع.',
};

// رقم عشوائي للمتصفح ده (مش بيانات شخصية) — بيخلّي بلوك الإزعاج يمسك اللي بيغيّر رقم موبايله
export function deviceId() {
  try {
    let id = localStorage.getItem('maka_device_v1');
    if (!id) {
      id = (crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`).replace(/-/g, '');
      localStorage.setItem('maka_device_v1', id);
    }
    return id;
  } catch {
    return null;
  }
}
export const errText = (r) => (r && r.message) || ERRORS[r && r.error] || 'حصلت مشكلة — جرّب تاني.';

export const money = (n) => `${Number(n).toLocaleString('ar-EG', { maximumFractionDigits: 2 })} ج`;

export function durationText(min) {
  const h = Math.floor(min / 60), m = min % 60;
  const hours = h === 0 ? '' : h === 1 ? 'ساعة' : h === 2 ? 'ساعتين' : `${h} ساعات`;
  if (!m) return hours;
  return hours ? `${hours} و${m === 30 ? 'نص' : `${m} دقيقة`}` : `${m} دقيقة`;
}

const DAY_NAMES = ['الأحد', 'الاتنين', 'التلات', 'الأربع', 'الخميس', 'الجمعة', 'السبت'];
export function dayLabel(iso, todayIso) {
  const d = new Date(`${iso}T12:00:00Z`);
  const t = new Date(`${todayIso}T12:00:00Z`);
  const diff = Math.round((d - t) / 86400000);
  const name = diff === 0 ? 'النهارده' : diff === 1 ? 'بكرة' : DAY_NAMES[d.getUTCDay()];
  return { name, sub: `${d.getUTCDate()}/${d.getUTCMonth() + 1}` };
}

export function addDays(iso, n) {
  const d = new Date(`${iso}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

// 18:30 → 6:30 م
export function time12(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  const suffix = h < 12 ? 'ص' : 'م';
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${String(m).padStart(2, '0')} ${suffix}`;
}

export function waLink(num) {
  if (!num) return null;
  let d = String(num).replace(/\D/g, '');
  if (d.startsWith('0')) d = `2${d}`;
  return `https://wa.me/${d}`;
}

// ── حجوزاتي (على الجهاز ده بس — التوكن هو مفتاح متابعة الطلب)
const KEY = 'maka_bookings_v1';
export function myBookings() {
  try {
    const list = JSON.parse(localStorage.getItem(KEY) || '[]');
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
}
export function saveBooking(item) {
  try {
    const list = myBookings().filter((b) => b.token !== item.token);
    list.unshift(item);
    localStorage.setItem(KEY, JSON.stringify(list.slice(0, 10)));
  } catch { /* وضع التصفح الخاص — عادي */ }
}

export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}
