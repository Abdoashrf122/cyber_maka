-- كلمة «عربون» → «deposit» في النصوص المحفوظة في قاعدة البيانات (سياسة الـ deposit اللي بتظهر للعميل).
-- بيتشغّل أكتر من مرة عادي: بعد أول مرة مفيش «عربون» يتغير.
BEGIN;

UPDATE private.settings
   SET deposit_policy = replace(replace(replace(deposit_policy, 'للعربون', 'للـ deposit'), 'العربون', 'الـ deposit'), 'عربون', 'deposit'),
       updated_at = now()
 WHERE id = 1 AND deposit_policy LIKE '%عربون%';

-- الطلبات اللي لسه شغالة (أسبابها بتظهر في صفحة متابعة الطلب)
UPDATE private.bookings
   SET reason = replace(replace(replace(reason, 'للعربون', 'للـ deposit'), 'العربون', 'الـ deposit'), 'عربون', 'deposit')
 WHERE reason LIKE '%عربون%' AND end_at > now() - interval '7 days';

COMMIT;
