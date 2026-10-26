-- بيانات البداية: الفرعين + أنواع الحجز (الأسعار والأعداد مبدئية — بتتعدّل من تطبيق الأدمن ← الفروع)
-- بيتشغّل مرة واحدة بس (لو الفرع موجود مابيتلمسش).
BEGIN;

INSERT INTO private.branches (slug, name, address, hours_text, open_24h, sort)
VALUES ('fleming', 'فرع فلمنج', 'فلمنج — الإسكندرية', 'مفتوح 24 ساعة', true, 1),
       ('st20', 'فرع شارع 20', 'شارع 20 — الإسكندرية', 'مفتوح 24 ساعة', true, 2)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO private.offerings (branch_id, kind, name, details, units, max_per_booking, price_per_hour, deposit, sort)
SELECT b.id, x.kind, x.name, x.details, x.units, x.max_per_booking, x.price, x.deposit, x.sort
  FROM private.branches b
 CROSS JOIN (VALUES
   ('pc', 'أجهزة كمبيوتر (PC)', 'أجهزة جيمنج — احجز جهاز أو أكتر لك ولصحابك', 10, 6, 20.00, 50.00, 1),
   ('ps_room', 'غرفة بلايستيشن 5', 'غرفة خاصة بشاشة كبيرة ودراعين', 2, 1, 60.00, 50.00, 2),
   ('ps_room', 'غرفة بلايستيشن 4', 'غرفة خاصة بشاشة ودراعين', 2, 1, 40.00, 50.00, 3)
 ) AS x(kind, name, details, units, max_per_booking, price, deposit, sort)
 WHERE b.slug IN ('fleming', 'st20')
   AND NOT EXISTS (SELECT 1 FROM private.offerings o WHERE o.branch_id = b.id);

COMMIT;
