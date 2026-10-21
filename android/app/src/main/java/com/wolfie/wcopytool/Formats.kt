package com.wolfie.wcopytool

// Minimal number parsing for the LF tabs.
object Fmt {
    fun parseId(s: String): Long {   // EM4100 40-bit id: 0x-hex, plain hex, or decimal
        val t = s.trim()
        return when {
            t.startsWith("0x", true) -> t.drop(2).toLongOrNull(16) ?: 0
            t.isNotEmpty() && t.all { it.isDigit() } -> t.toLongOrNull() ?: 0
            else -> t.toLongOrNull(16) ?: 0
        } and 0xFFFFFFFFFFL
    }
    fun parseDec(s: String): Long {
        val t = s.trim()
        return (if (t.startsWith("0x", true)) t.drop(2).toLongOrNull(16) else t.toLongOrNull()) ?: 0
    }
    fun parseDec0(s: String): Long { val v = parseDec(s); return if (v <= 0) 125000 else v }
    fun idHex(id: Long) = "%010X".format(id)
}
