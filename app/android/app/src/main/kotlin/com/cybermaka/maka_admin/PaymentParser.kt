package com.cybermaka.maka_admin

/**
 * قراية رسايل/إشعارات التحويل: المبلغ + اسم اللي حوّل + هل هو تحويل «وارد».
 * التحويلات الطالعة (خصم/دفع) بتتجاهل عشان ماتأكدش حجز بالغلط.
 * السيرفر بيتأكد تاني: المبلغ لازم يطابق deposit حجز مستني بالظبط.
 */
object PaymentParser {
    private const val ARABIC = "٠١٢٣٤٥٦٧٨٩"
    private const val PERSIAN = "۰۱۲۳۴۵۶۷۸۹"

    fun normalize(s: String): String = buildString(s.length) {
        for (c in s) {
            val i = ARABIC.indexOf(c)
            val j = PERSIAN.indexOf(c)
            append(
                when {
                    i >= 0 -> '0' + i
                    j >= 0 -> '0' + j
                    c == '٫' -> '.'
                    c == '٬' -> ','
                    c == ' ' -> ' '
                    else -> c
                }
            )
        }
    }

    private const val NUM = """(\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)"""
    private const val CUR = """(?:EGP|E\.G\.P|L\.E\.?|LE|جنيه(?:ا|ات)?|جنية|ج\.م\.?|جم|ج)"""
    private val curThenNum = Regex("""(?<![A-Za-z])$CUR\s*$NUM""", RegexOption.IGNORE_CASE)
    private val numThenCur = Regex("""$NUM\s*$CUR(?![A-Za-z])""", RegexOption.IGNORE_CASE)
    private val keywordNum = Regex("""(?:amount|بمبلغ|مبلغ|قيمة|قيمته)\s*(?:of|:|=)?\s*$NUM""", RegexOption.IGNORE_CASE)

    fun amount(text: String): Double? {
        val t = normalize(text)
        for (r in listOf(curThenNum, numThenCur, keywordNum)) {
            for (m in r.findAll(t)) {
                val v = m.groupValues[1].replace(",", "").toDoubleOrNull() ?: continue
                if (v > 0 && v < 1_000_000) return v
            }
        }
        return null
    }

    private val incoming = Regex(
        """receiv|credited|deposit|added to your|incoming|sent you|transferred to you|""" +
            """استلام|استلمت|إيداع|ايداع|إضافة|اضافة|تم اضافة|وارد|واردة|إليك|اليك|لحسابك|إلى حسابك|الى حسابك""",
        RegexOption.IGNORE_CASE,
    )
    private val outgoing = Regex(
        """debited|you sent|you paid|payment to|purchase|withdraw|""" +
            """خصم|سحب|شراء|دفعت|سداد|تم تحويل مبلغ.*من حسابك""",
        RegexOption.IGNORE_CASE,
    )

    /** لازم كلمة «وارد/استلام» تكون موجودة، ومفيش ما يدل إنه طالع */
    fun isIncoming(text: String): Boolean {
        val t = normalize(text)
        return incoming.containsMatchIn(t) && !outgoing.containsMatchIn(t)
    }

    private val fromPatterns = listOf(
        Regex("""\bfrom\s+([^\n,.:;]{2,40}?)(?=\s+(?:on|to|via|at|ref|reference|account|acc)\b|[,.:;\n]|$)""", RegexOption.IGNORE_CASE),
        Regex("""(?:^|\s)من\s+([^\n،,.:;]{2,40}?)(?=\s+(?:إلى|الى|في|على|بتاريخ|رقم|لحساب)(?:\s|$)|[،,.:;\n]|$)"""),
    )

    fun payer(text: String): String? {
        val t = normalize(text)
        for (r in fromPatterns) {
            val name = r.find(t)?.groupValues?.get(1)?.trim() ?: continue
            if (name.isEmpty() || name.all { it.isDigit() || it == '*' || it == ' ' }) continue
            if (name.contains("حساب") || name.contains("account", true)) continue
            return name.take(60)
        }
        return null
    }
}
