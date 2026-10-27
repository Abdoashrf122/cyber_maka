import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';

/// الفريق: أي أدمن يقدر يضيف أدمن جديد، ويعمل كلمة سر جديدة لواحد تاني، أو يمسح حسابه.
/// آخر أدمن مينفعش يتمسح. الحساب الجديد بيدخل بكلمة سر مؤقتة وبيغيّرها أول مرة.
class TeamScreen extends StatefulWidget {
  const TeamScreen({super.key});

  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  List<Map<String, dynamic>>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await rpc('admin_team');
      if (!mounted) return;
      setState(() => _items = (r as List).map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } on ApiError catch (e) {
      if (mounted) toast(context, e.toString(), error: true);
    }
  }

  Future<void> _add() async {
    final created = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _NewAdminDialog(),
    );
    if (created == null || !mounted) return;
    await _load();
    if (mounted) await _showCredentials(created);
  }

  Future<void> _showCredentials(Map<String, String> c) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 40),
          title: const Text('الحساب اتعمل ✓'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('سلّم ${c['name']} البيانات دي — أول دخول هيطلب منه يغيّر كلمة السر.'),
            const SizedBox(height: 12),
            _CredentialRow(label: 'اسم المستخدم', value: c['username']!),
            _CredentialRow(label: 'كلمة السر المؤقتة', value: c['password']!),
          ]),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('تمام'))],
        ),
      );

  Future<void> _reset(Map<String, dynamic> a) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _ResetPasswordDialog(admin: a));
    if (ok != true || !mounted) return;
    await _load();
    if (mounted) toast(context, 'كلمة السر اتغيرت — هيغيّرها أول دخول');
  }

  Future<void> _remove(Map<String, dynamic> a) async {
    final name = '${a['name']}';
    if (!await confirmDialog(
      context,
      'مسح حساب $name؟',
      'هيتشال حسابه خالص من السيرفر، وأي موبايل مسجّل بيه هيبطل يرن ويقرا التحويلات.',
      yes: 'امسح',
      danger: true,
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await run(context, () => rpcOk('admin_remove', {'p_user': a['user_id']}), ok: 'اتمسح');
    if (ok && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('الفريق')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('أدمن جديد'),
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 860),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(14),
                          child: Text(
                            'أي أدمن هنا يقدر يضيف أدمن جديد، ويعمل كلمة سر جديدة لواحد تاني، أو يمسح حسابه. '
                            'آخر أدمن مينفعش يتمسح. الحساب الجديد بيدخل بكلمة السر المؤقتة وبيضطر يغيّرها أول مرة.',
                            style: TextStyle(color: Colors.white60),
                          ),
                        ),
                      ),
                      for (final a in items) _tile(a),
                    ]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _tile(Map<String, dynamic> a) {
    final me = a['is_me'] == true;
    final username = '${a['username'] ?? ''}';
    final phone = a['phone'] as String?;
    final created = DateTime.tryParse('${a['created_at']}')?.toLocal();
    final creator = a['created_by_name'] as String?;
    final parts = <String>[
      if (username.isNotEmpty) '@$username',
      if (phone != null && phone.isNotEmpty) phone,
      if (created != null) 'من ${created.day}/${created.month}/${created.year}',
      if (a['must_change_password'] == true) 'لسه ماغيّرش كلمة السر',
      if (creator != null && creator.isNotEmpty) 'أضافه $creator',
    ];
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: me ? const Color(0xFF7C3AED) : const Color(0xFF312E81),
          child: Icon(me ? Icons.person : Icons.person_outline, color: Colors.white),
        ),
        title: Text('${a['name'] ?? ''}${me ? '  (إنت)' : ''}'),
        subtitle: Text(parts.join(' · '), style: const TextStyle(height: 1.5)),
        trailing: me
            ? const Tooltip(
                message: 'ده حسابك — كلمة السر بتتغير من «الحساب»',
                child: Icon(Icons.lock_outline),
              )
            : PopupMenuButton<String>(
                tooltip: 'خيارات',
                onSelected: (v) => v == 'reset' ? _reset(a) : _remove(a),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'reset',
                    child: ListTile(leading: Icon(Icons.password), title: Text('كلمة سر جديدة')),
                  ),
                  PopupMenuItem(
                    value: 'remove',
                    child: ListTile(
                      leading: Icon(Icons.delete_outline, color: Color(0xFFF87171)),
                      title: Text('مسح الحساب'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _CredentialRow extends StatelessWidget {
  final String label;
  final String value;
  const _CredentialRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
              SelectableText(
                value,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ]),
          ),
          IconButton(
            tooltip: 'نسخ',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (context.mounted) toast(context, 'اتنسخ');
            },
          ),
        ]),
      );
}

class _NewAdminDialog extends StatefulWidget {
  const _NewAdminDialog();

  @override
  State<_NewAdminDialog> createState() => _NewAdminDialogState();
}

class _NewAdminDialogState extends State<_NewAdminDialog> {
  final _username = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    for (final c in [_username, _name, _phone, _pass, _pass2]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _passField(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: c,
          obscureText: true,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(labelText: label),
        ),
      );

  Future<void> _save() async {
    final user = _username.text.trim().toLowerCase();
    final name = _name.text.trim();
    final pass = _pass.text;
    if (!RegExp(r'^[a-z0-9][a-z0-9_.-]{2,29}$').hasMatch(user)) {
      setState(() => _err = 'اسم المستخدم: حروف إنجليزي/أرقام من 3 لـ 30، يبدأ بحرف أو رقم.');
      return;
    }
    if (name.length < 2) {
      setState(() => _err = 'اكتب اسم الأدمن (حرفين على الأقل).');
      return;
    }
    if (pass.isEmpty) {
      setState(() => _err = 'اكتب كلمة السر.');
      return;
    }
    if (utf8.encode(pass).length > 72) {
      setState(() => _err = 'كلمة السر بحد أقصى 72 بايت.');
      return;
    }
    if (pass != _pass2.text) {
      setState(() => _err = 'كلمتين السر مش زي بعض.');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await rpcOk('admin_create', {
        'p_username': user,
        'p_name': name,
        'p_phone': _phone.text.trim(),
        'p_password': pass,
      });
      if (!mounted) return;
      Navigator.pop(context, {'username': user, 'name': name, 'password': pass});
    } on ApiError catch (e) {
      setState(() {
        _busy = false;
        _err = switch (e.code) {
          'username_taken' => 'اسم المستخدم ده معمول بيه حساب بالفعل.',
          'bad_username' => 'اسم المستخدم: حروف إنجليزي/أرقام من 3 لـ 30، يبدأ بحرف أو رقم.',
          'bad_name' => 'اكتب اسم الأدمن (حرفين على الأقل).',
          'bad_password' => 'كلمة السر مطلوبة وبحد أقصى 72 بايت.',
          _ => e.toString(),
        };
      });
    } catch (_) {
      setState(() {
        _busy = false;
        _err = errorText('network');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('أدمن جديد'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _username,
              textDirection: TextDirection.ltr,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'اسم المستخدم (بيدخل بيه)',
                helperText: 'حروف إنجليزي/أرقام من 3 لـ 30 — من غير مسافات',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              maxLength: 40,
              decoration: const InputDecoration(labelText: 'الاسم (بيظهر للفريق)'),
            ),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'الموبايل (اختياري)'),
            ),
            const SizedBox(height: 8),
            _passField(_pass, 'كلمة سر مؤقتة'),
            _passField(_pass2, 'اكتبها تاني'),
            if (_err != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_err!, style: const TextStyle(color: Color(0xFFFCA5A5))),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('رجوع')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'لحظة…' : 'إنشاء')),
      ],
    );
  }
}

class _ResetPasswordDialog extends StatefulWidget {
  final Map<String, dynamic> admin;
  const _ResetPasswordDialog({required this.admin});

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _pass.dispose();
    _pass2.dispose();
    super.dispose();
  }

  Widget _passField(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: c,
          obscureText: true,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(labelText: label),
        ),
      );

  Future<void> _save() async {
    if (_pass.text.isEmpty) {
      setState(() => _err = 'اكتب كلمة السر.');
      return;
    }
    if (utf8.encode(_pass.text).length > 72) {
      setState(() => _err = 'كلمة السر بحد أقصى 72 بايت.');
      return;
    }
    if (_pass.text != _pass2.text) {
      setState(() => _err = 'كلمتين السر مش زي بعض.');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await rpcOk('admin_reset_password', {'p_user': widget.admin['user_id'], 'p_password': _pass.text});
      if (mounted) Navigator.pop(context, true);
    } on ApiError catch (e) {
      setState(() {
        _busy = false;
        _err = switch (e.code) {
          'cannot_self' => 'دي كلمة سرك إنت — استخدم «تغيير كلمة السر» من شاشة الحساب.',
          'not_found' => 'الحساب مش موجود (ممكن اتمسح).',
          'bad_password' => 'كلمة السر مطلوبة وبحد أقصى 72 بايت.',
          _ => e.toString(),
        };
      });
    } catch (_) {
      setState(() {
        _busy = false;
        _err = errorText('network');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('كلمة سر جديدة لـ ${widget.admin['name']}'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text(
            'هيخرج من كل الأجهزة، وأول دخول بالكلمة المؤقتة هيطلب منه يغيّرها.',
            style: TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 8),
          _passField(_pass, 'كلمة السر المؤقتة'),
          _passField(_pass2, 'اكتبها تاني'),
          if (_err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_err!, style: const TextStyle(color: Color(0xFFFCA5A5))),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'لحظة…' : 'غيّر')),
      ],
    );
  }
}
