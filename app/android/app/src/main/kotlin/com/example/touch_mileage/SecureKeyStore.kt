package com.example.touch_mileage

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 触控里程 · 凭据安全存储（P1-2，2026-10-14）
 *
 * 用途：把云端会话令牌从明文 config.json 里挪出来，用 Android Keystore 保护。
 *
 * ⚠️ 能力边界（务必如实理解，别当成"绝对安全"）：
 *   · Keystore 里的密钥**不出安全硬件**（有 TEE/StrongBox 的机型），
 *     应用只能"用"它，读不走它 ⇒ 即使拷贝走应用数据目录也解不出明文。
 *   · 卸载应用时密钥随之销毁，密文永远解不开（这是特性不是缺陷：
 *     卸载即登出，符合预期）。
 *   · **不防**设备已被完全控制（root/已解锁 bootloader + 恶意框架）的极端情况。
 *   · 真正的兜底是「登录设备」页 —— 用户能看见并踢掉陌生设备。
 *
 * 算法选择：AES/GCM/NoPadding
 *   · GCM 自带完整性校验：密文被篡改会解密失败，而不是解出垃圾。
 *   · 每次加密用随机 IV，随密文一起存（IV 不是秘密）。
 *   · 明文不用额外做 base64——本类整体按 base64 交接给 Dart，
 *     内部把 [iv || ciphertext || tag] 拼成一个 base64 串。
 */
object SecureKeyStore {

    private const val KEY_ALIAS = "touch_mileage_cloud_token"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val GCM_TAG_BITS = 128
    private const val GCM_IV_BYTES = 12

    /** 取（或首次创建）密钥。首次创建后再也取不到原始字节，只能用。 */
    private fun secretKey(): SecretKey {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }
        val gen = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE
        )
        gen.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                // GCM 模式不允许复用 IV（复用会直接毁掉安全性），
                // 交给系统每次生成随机 IV。
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return gen.generateKey()
    }

    /** 加密。成功返回 base64(iv || ciphertext)；失败返回 null（调用方不落盘）。 */
    fun protect(plain: String): String? = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val body = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val out = ByteArray(iv.size + body.size)
        System.arraycopy(iv, 0, out, 0, iv.size)
        System.arraycopy(body, 0, out, iv.size, body.size)
        Base64.encodeToString(out, Base64.NO_WRAP)
    } catch (e: Exception) {
        DebugLog.i("SecureKeyStore") { "protect failed: ${e.javaClass.simpleName}" }
        null
    }

    /**
     * 解密。任何失败（密钥被清、密文损坏、换设备）返回 null ——
     * 调用方当作"没有登录态"，引导重新登录，不报错不崩。
     */
    fun unprotect(cipherB64: String): String? = try {
        val raw = Base64.decode(cipherB64, Base64.NO_WRAP)
        if (raw.size <= GCM_IV_BYTES) {
            null
        } else {
            val iv = raw.copyOfRange(0, GCM_IV_BYTES)
            val body = raw.copyOfRange(GCM_IV_BYTES, raw.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, iv)
            )
            String(cipher.doFinal(body), Charsets.UTF_8)
        }
    } catch (e: Exception) {
        // 密钥不存在 / 认证标签不匹配 / base64 坏 —— 全部当作"没有令牌"
        DebugLog.i("SecureKeyStore") { "unprotect failed: ${e.javaClass.simpleName}" }
        null
    }
}
