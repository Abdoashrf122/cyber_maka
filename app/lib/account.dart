import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core.dart';

/// الحساب: الدخول باسم مستخدم (من غير إيميل حقيقي) — اسم المستخدم "admin" = admin@users.makka.io داخليًا.
/// تغيير كلمة السر / اسم المستخدم / الاسم ورقم الموبايل من جوه التطبيق، من غير أي كود تأكيد.

const _domain = '@users.makka.io';

String loginEmail(String input) {
  final s = input.trim().toLowerCase();
  return s.contains('@') ? s : '$s$_domain';
}

String authErrorText(Object e) {
  if (e is AuthException) {
    final m = '${e.code ?? ''} ${e.message}'.toLowerCase();
    if (m.contains('weak') || m.contains('at least') || m.contains('characters')) return 'كلمة السر ضعيفة — 8 حروف على الأقل.';
    if (m.contains('same') && m.contains('password')) return 'كلمة السر الجديدة لازم تكون مختلفة عن القديمة.';
    if (m.contains('invalid login') || m.contains('credentials')) return 'كلمة السر الحالية غلط.';
    if (m.contains('rate') || m.contains('too many')) return 'محاولات كتير — استنى شوية.';
    return 'حصلت مشكلة: ${e.message}';
  }
  if (e is ApiError) return e.toString();
  return errorText('network');
}

Widget _pass(TextEditingController c, String label) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        obscureText: true,
        textDirection: TextDirection.ltr,
        decoration: InputDecoration(labelText: label),
      ),
    );

String? _checkNew(String p1, String p2) {
  if (p1.length < 8) return 'كلمة السر 8 حروف على الأقل.';
  if (p1.toLowerCase() == 'admin' || p1 == '12345678') return 'اختار كلمة سر أصعب.';
  if (p1 != p2) return 'كلمتين السر مش زي بعض.';
  return null;
}

/// «نسيت كلمة السر» — مفيش إيميل، فالمسؤول بيرجّعها من السيرفر
void showForgotPassword(BuildContext context) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('نسيت كلمة السر؟'),
        content: const Text(
          'أي أدمن تاني معاك يقدر يعمل لك كلمة سر جديدة من «الإعدادات ← الفريق». '
          'لو مفيش حد، المسؤول يرجّعها لك من السيرفر بأمر create_admin.sh. '
          'أول ما تدخل بالكلمة المؤقتة، التطبيق هيطلب منك تختار كلمة سر جديدة.',
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('تمام'))],
      ),
    );

/// أول دخول بكلمة سر مؤقتة (admin مثلاً) → لازم يغيّرها قبل أي حاجة
class ForceChangePasswordScreen extends StatefulWidget {
  final VoidCallback onDone;
  const ForceChangePasswordScreen({super.key, required this.onDone});
  @override
  State<ForceChangePasswordScreen> createState() => _ForceChangePasswordScreenState();
}

class _ForceChangePasswordScreenState extends State<ForceChangePasswordScreen> {
  final _p1 = TextEditingController(), _p2 = TextEditingController();
  bool _busy = false;
  String? _err;

  Future<void> _save() async {
    final bad = _checkNew(_p1.text, _p2.text);
    if (bad != null) return setState(() => _err = bad);
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await sb.auth.updateUser(UserAttributes(password: _p1.text));
      await rpcOk('admin_password_changed');
      widget.onDone();
    } catch (e) {
      setState(() => _err = authErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Icon(Icons.lock_reset, size: 56, color: Color(0xFFA78BFA)),
                const SizedBox(height: 10),
                const Text('اختار كلمة سر جديدة', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                  'إنت داخل بكلمة سر مؤقتة. عشان محدش غيرك يقدر يدخل ويشوف أرقام الزباين ويأكد حجوزات، اختار كلمة سر خاصة بيك (8 حروف على الأقل).',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 14),
                _pass(_p1, 'كلمة السر الجديدة'),
                _pass(_p2, 'اكتبها تاني'),
                if (_err != null) Text(_err!, style: const TextStyle(color: Color(0xFFFCA5A5))),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
                  child: Text(_busy ? 'لحظة…' : 'حفظ'),
                ),
                TextButton(onPressed: () => sb.auth.signOut(), child: const Text('خروج')),
              ]),
            ),
          ),
        ),
      );
}

/// تغيير كلمة السر وإنت داخل (لازم كلمة السر الحالية)
Future<void> changePassword(BuildContext context) async {
  final cur = TextEditingController(), p1 = TextEditingController(), p2 = TextEditingController();
  String? err;
  bool busy = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('تغيير كلمة السر'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _pass(cur, 'كلمة السر الحالية'),
            _pass(p1, 'كلمة السر الجديدة (8+)'),
            _pass(p2, 'اكتبها تاني'),
            if (err != null) Text(err!, style: const TextStyle(color: Color(0xFFFCA5A5))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('رجوع')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    final bad = _checkNew(p1.text, p2.text);
                    if (bad != null) return setS(() => err = bad);
                    setS(() {
                      busy = true;
                      err = null;
                    });
                    try {
                      final email = sb.auth.currentUser?.email ?? '';
                      await sb.auth.signInWithPassword(email: email, password: cur.text); // تأكيد الحالية
                      await sb.auth.updateUser(UserAttributes(password: p1.text));
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (context.mounted) toast(context, 'كلمة السر اتغيرت ✓');
                    } catch (e) {
                      setS(() => err = authErrorText(e));
                    } finally {
                      if (ctx.mounted) setS(() => busy = false);
                    }
                  },
            child: const Text('غيّر'),
          ),
        ],
      ),
    ),
  );
}

/// تغيير اسم المستخدم (اللي بيدخل بيه)
Future<bool> changeUsername(BuildContext context, String current) async {
  final c = TextEditingController(text: current);
  String? err;
  bool busy = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('تغيير اسم المستخدم'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: c,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'اسم المستخدم الجديد', helperText: 'حروف إنجليزي وأرقام (3 لـ 30)، من غير مسافات'),
            ),
            if (err != null) Text(err!, style: const TextStyle(color: Color(0xFFFCA5A5))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setS(() {
                      busy = true;
                      err = null;
                    });
                    try {
                      await rpcOk('admin_set_username', {'p_username': c.text.trim()});
                      await sb.auth.refreshSession();
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } on ApiError catch (e) {
                      setS(() => err = switch (e.code) {
                            'bad_username' => 'اسم المستخدم لازم يبقى حروف إنجليزي/أرقام من 3 لـ 30، يبدأ بحرف أو رقم.',
                            'username_taken' => 'الاسم ده مستخدم.',
                            _ => e.toString(),
                          });
                    } catch (e) {
                      setS(() => err = authErrorText(e));
                    } finally {
                      if (ctx.mounted) setS(() => busy = false);
                    }
                  },
            child: const Text('حفظ'),
          ),
        ],
      ),
    ),
  );
  if (ok == true && context.mounted) toast(context, 'اسم المستخدم اتغير ✓ — ادخل بيه المرة الجاية');
  return ok == true;
}

/// الاسم ورقم الموبايل (من غير تأكيد)
Future<bool> editProfile(BuildContext context, String name, String? phone) async {
  final n = TextEditingController(text: name), p = TextEditingController(text: phone ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('بياناتي'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: n, maxLength: 40, decoration: const InputDecoration(labelText: 'الاسم')),
          TextField(
            controller: p,
            keyboardType: TextInputType.phone,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(labelText: 'رقم الموبايل (اختياري)'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
        FilledButton(
          onPressed: () async {
            final saved = await run(ctx, () => rpcOk('admin_update_profile', {'p_name': n.text.trim(), 'p_phone': p.text.trim()}), ok: 'اتحفظ');
            if (saved && ctx.mounted) Navigator.pop(ctx, true);
          },
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
  return ok == true;
}
