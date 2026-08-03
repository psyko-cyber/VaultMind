package com.vaultmind.vaultmind

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.fragment.app.FragmentActivity
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Sblocco con l'impronta.
 *
 * COSA VIENE CONSERVATO, e cosa no: la master password non viene mai salvata,
 * qui come sul PC. Si conserva la **chiave del vault** — i 32 byte che escono
 * da Argon2id — e la si conserva CIFRATA con una chiave del Keystore di
 * Android che il sistema accetta di usare solo dopo un'autenticazione
 * biometrica riuscita.
 *
 * Non è un controllo di facciata: senza impronta il sistema si rifiuta di
 * inizializzare il cifrario, quindi quei byte restano illeggibili anche a chi
 * si portasse via il file. Non è un "if" che si può aggirare.
 *
 * `setInvalidatedByBiometricEnrollment(true)`: se qualcuno aggiunge la propria
 * impronta al telefono, Android **distrugge** la chiave e VaultMind torna a
 * chiedere la master password. È la difesa contro chi, avendo il telefono
 * sbloccato in mano, si registra il dito per entrare nel vault.
 */
object Biometria {

    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "vaultmind_chiave_biometrica"
    private const val PREFS = "vaultmind_bio"
    private const val CHIAVE_CIFRATA = "chiave"
    private const val IV = "iv"

    /** L'impronta è utilizzabile su questo telefono? */
    fun disponibile(ctx: Context): Boolean =
        BiometricManager.from(ctx).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS

    /** L'utente ha già attivato lo sblocco con impronta? */
    fun attiva(ctx: Context): Boolean =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).contains(CHIAVE_CIFRATA)

    fun disattiva(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        try {
            KeyStore.getInstance(KEYSTORE).apply { load(null) }.deleteEntry(ALIAS)
        } catch (e: Exception) {
            // La chiave poteva già non esserci: l'importante è il risultato.
        }
    }

    private fun chiaveKeystore(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }

        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true)
            .apply {
                if (Build.VERSION.SDK_INT >= 24) setInvalidatedByBiometricEnrollment(true)
            }
            .build()
        gen.init(spec)
        return gen.generateKey()
    }

    /**
     * Attiva lo sblocco: chiede l'impronta e, se va bene, conserva la chiave
     * del vault cifrata. [chiaveBase64] sono i 32 byte derivati dalla master
     * password, che il chiamante ha già in memoria perché ha appena sbloccato.
     */
    fun attivaConChiave(
        activity: FragmentActivity,
        chiaveBase64: String,
        esito: (Boolean, String?) -> Unit
    ) {
        val cifrario = try {
            Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, chiaveKeystore()) }
        } catch (e: Exception) {
            esito(false, "Non è stato possibile preparare la chiave: ${e.message}")
            return
        }

        mostraRichiesta(
            activity,
            "Attiva lo sblocco con impronta",
            "Da ora potrai aprire il vault con il dito invece della master password.",
            cifrario
        ) { autenticato, cifrarioPronto ->
            if (!autenticato || cifrarioPronto == null) {
                esito(false, null) // annullato: non è un errore da mostrare
                return@mostraRichiesta
            }
            try {
                val chiaro = Base64.decode(chiaveBase64, Base64.NO_WRAP)
                val cifrato = cifrarioPronto.doFinal(chiaro)
                activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putString(CHIAVE_CIFRATA, Base64.encodeToString(cifrato, Base64.NO_WRAP))
                    .putString(IV, Base64.encodeToString(cifrarioPronto.iv, Base64.NO_WRAP))
                    .apply()
                esito(true, null)
            } catch (e: Exception) {
                esito(false, "Non è stato possibile salvare la chiave.")
            }
        }
    }

    /** Chiede l'impronta e restituisce la chiave del vault, se tutto torna. */
    fun sbloccaEOttieniChiave(
        activity: FragmentActivity,
        esito: (String?, String?) -> Unit
    ) {
        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val cifrato = prefs.getString(CHIAVE_CIFRATA, null)
        val iv = prefs.getString(IV, null)
        if (cifrato == null || iv == null) {
            esito(null, "Sblocco con impronta non attivo.")
            return
        }

        val cifrario = try {
            Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(
                    Cipher.DECRYPT_MODE,
                    chiaveKeystore(),
                    GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP))
                )
            }
        } catch (e: Exception) {
            // Tipico quando è stata registrata una nuova impronta: Android ha
            // distrutto la chiave apposta. Si riparte dalla master password.
            disattiva(activity)
            esito(null, "Le impronte del telefono sono cambiate: sblocca con la master password e riattiva l'impronta.")
            return
        }

        mostraRichiesta(
            activity,
            "Sblocca VaultMind",
            "Appoggia il dito per aprire il vault.",
            cifrario
        ) { autenticato, cifrarioPronto ->
            if (!autenticato || cifrarioPronto == null) {
                esito(null, null) // annullato
                return@mostraRichiesta
            }
            try {
                val chiaro = cifrarioPronto.doFinal(Base64.decode(cifrato, Base64.NO_WRAP))
                esito(Base64.encodeToString(chiaro, Base64.NO_WRAP), null)
            } catch (e: Exception) {
                esito(null, "Non è stato possibile leggere la chiave.")
            }
        }
    }

    private fun mostraRichiesta(
        activity: FragmentActivity,
        titolo: String,
        sottotitolo: String,
        cifrario: Cipher,
        quando: (Boolean, Cipher?) -> Unit
    ) {
        val prompt = BiometricPrompt(
            activity,
            androidx.core.content.ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    quando(true, result.cryptoObject?.cipher)
                }

                override fun onAuthenticationError(codice: Int, messaggio: CharSequence) {
                    quando(false, null)
                }
            }
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(titolo)
            .setSubtitle(sottotitolo)
            .setNegativeButtonText("Usa la master password")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .build()
        prompt.authenticate(info, BiometricPrompt.CryptoObject(cifrario))
    }
}
