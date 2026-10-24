package com.vaultmind.vaultmind

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Il ponte fra Android e l'app: scelta del file di backup e apertura da una
 * chat ("Apri con VaultMind").
 *
 * Scritto a mano invece di usare un pacchetto per scegliere i file: quelli
 * disponibili non compilano con la versione del Gradle Plugin che Flutter usa
 * qui, e comunque l'"Apri con" avrebbe richiesto codice nativo lo stesso.
 * Meno dipendenze da cui dipendere, e una cosa sola da mantenere.
 */
// FlutterFragmentActivity e non FlutterActivity: BiometricPrompt e' un
// componente AndroidX e pretende una FragmentActivity per mostrarsi.
class MainActivity : FlutterFragmentActivity() {

    private val canale = "vaultmind/file"
    private var richiestaInCorso: MethodChannel.Result? = null
    private var metodi: MethodChannel? = null

    /** Contenuto arrivato da "Apri con", in attesa che Dart lo chieda. */
    private var inAttesa: String? = null

    /** Vault cifrato in attesa che l'utente scelga dove salvarlo. */
    private var backupDaScrivere: String? = null

    companion object {
        private const val CODICE_SCEGLI = 4711
        private const val CODICE_SALVA = 4712
        private const val CODICE_QR_FOTOCAMERA = 4713
        private const val CODICE_QR_IMMAGINE = 4714
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Niente screenshot e niente anteprima nell'elenco delle app aperte:
        // qui dentro si vedono credenziali, e quell'anteprima resta sullo
        // schermo anche dopo aver lasciato l'app.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )

        metodi = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, canale)
        metodi!!.setMethodCallHandler { chiamata, esito ->
            when (chiamata.method) {
                // Apre il selettore di sistema (Storage Access Framework):
                // nessun permesso da chiedere all'utente, a differenza della
                // lettura diretta delle cartelle.
                "scegli" -> {
                    richiestaInCorso = esito
                    val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(
                            Intent.EXTRA_MIME_TYPES,
                            arrayOf("application/json", "text/plain", "*/*")
                        )
                    }
                    startActivityForResult(i, CODICE_SCEGLI)
                }
                // Il file con cui l'app è stata aperta da una chat, se c'è.
                "inAttesa" -> {
                    esito.success(inAttesa)
                    inAttesa = null
                }

                // Salva il backup dove decide l'utente (Storage Access
                // Framework). Si e' scelto questo invece di condividerlo con
                // ACTION_SEND perche' quello avrebbe richiesto un FileProvider
                // esportato: qui non si espone niente, e da dove il file
                // atterra l'utente lo manda dove vuole con le app che ha gia'.
                // Il contenuto e' gia' cifrato: chi lo intercetta vede rumore.
                "salvaBackup" -> {
                    val a = chiamata.arguments as? Map<*, *>
                    val testo = a?.get("contenuto") as? String
                    val nome = a?.get("nome") as? String
                    if (testo == null || nome == null) {
                        esito.success(false)
                    } else {
                        richiestaInCorso = esito
                        backupDaScrivere = testo
                        val i = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/json"
                            putExtra(Intent.EXTRA_TITLE, nome)
                        }
                        startActivityForResult(i, CODICE_SALVA)
                    }
                }

                // Apre un indirizzo nel browser. Solo http/https: qualunque
                // altro schema trasformerebbe un campo del vault in un modo
                // per far eseguire cose al telefono. Stessa regola di
                // /api/open_url sul PC.
                "apriUrl" -> {
                    val u = (chiamata.arguments as? String)?.trim().orEmpty()
                    if (!u.startsWith("http://", true) && !u.startsWith("https://", true)) {
                        esito.success(false)
                    } else {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(u)))
                            esito.success(true)
                        } catch (e: Exception) {
                            esito.success(false)
                        }
                    }
                }

                // Aggiornamento dentro l'app: apre l'installer di Android
                // sull'APK appena scaricato nella cache.
                //
                // Non installiamo niente noi: la schermata di sistema chiede
                // conferma e controlla la firma. Un APK firmato con una chiave
                // diversa dalla nostra viene rifiutato da Android, e quella e'
                // la difesa vera -- il nostro controllo dello SHA-256 serve a
                // non arrivare fino a qui con un file scaricato a meta'.
                //
                // L'URI passa da un FileProvider perche' da Android 7 passare
                // un file:// a un'altra app solleva FileUriExposedException.
                // Il provider e' exported="false" e concede la lettura solo a
                // chi riceve questo Intent, per il tempo dell'Intent.
                "installaApk" -> {
                    val percorso = (chiamata.arguments as? String).orEmpty()
                    try {
                        val uri = FileProvider.getUriForFile(
                            this, "$packageName.aggiornamenti", File(percorso))
                        startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_ACTIVITY_NEW_TASK
                                )
                        )
                        esito.success(null)
                    } catch (e: Exception) {
                        // Il caso vero: "installa app sconosciute" negato per
                        // VaultMind. Il messaggio arriva a Dart, che offre la
                        // pagina delle release.
                        esito.error("installa", e.message, null)
                    }
                }

                // ---- lettura di un QR ----
                // Due strade, e servono tutte e due. La fotocamera e' quella
                // ovvia, ma non copre il caso piu' frequente di tutti: la 2FA
                // attivata sul browser DI QUESTO telefono, dove il QR sta
                // sullo schermo che dovrebbe fotografare. Li' l'unica strada
                // e' lo screenshot.
                "qrDaFotocamera" -> {
                    richiestaInCorso = esito
                    val a = chiamata.arguments as? Map<*, *>
                    val i = Intent(this, ScansionaQr::class.java).apply {
                        (a?.get("colore") as? Int)?.let {
                            putExtra(ScansionaQr.EXTRA_COLORE, it)
                        }
                        (a?.get("titolo") as? String)?.let {
                            putExtra(ScansionaQr.EXTRA_TITOLO, it)
                        }
                    }
                    startActivityForResult(i, CODICE_QR_FOTOCAMERA)
                }
                "qrDaImmagine" -> {
                    richiestaInCorso = esito
                    val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "image/*"
                    }
                    startActivityForResult(i, CODICE_QR_IMMAGINE)
                }

                // ---- impronta ----
                "bioDisponibile" -> esito.success(Biometria.disponibile(this))
                "bioAttiva" -> esito.success(Biometria.attiva(this))
                "bioDisattiva" -> {
                    Biometria.disattiva(this)
                    esito.success(true)
                }
                "bioAttivaConChiave" -> {
                    val chiave = chiamata.arguments as? String
                    if (chiave == null) {
                        esito.success(false)
                    } else {
                        Biometria.attivaConChiave(this, chiave) { ok, errore ->
                            if (errore != null) esito.error("bio", errore, null) else esito.success(ok)
                        }
                    }
                }
                "bioSblocca" -> {
                    Biometria.sbloccaEOttieniChiave(this) { chiave, errore ->
                        if (errore != null) esito.error("bio", errore, null) else esito.success(chiave)
                    }
                }

                else -> esito.notImplemented()
            }
        }

        // L'app potrebbe essere stata avviata proprio toccando un allegato.
        leggiDaIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        leggiDaIntent(intent)
        // Se Dart è già in ascolto glielo diciamo subito; altrimenti resta in
        // attesa e lo chiederà lui: l'app può essere già aperta o partire ora.
        inAttesa?.let { metodi?.invokeMethod("fileRicevuto", it) }
    }

    private fun leggiDaIntent(intent: Intent?) {
        val uri: Uri? = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
            else -> null
        }
        if (uri != null) inAttesa = leggiUri(uri)
    }

    /**
     * Legge tutto il contenuto come UTF-8: il backup è JSON, e i titoli
     * possono contenere accenti ed emoji.
     */
    private fun leggiUri(uri: Uri): String? = try {
        contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
    } catch (e: Exception) {
        null
    }

    @Deprecated("onActivityResult resta la via per ACTION_OPEN_DOCUMENT da un'Activity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != CODICE_SCEGLI && requestCode != CODICE_SALVA &&
            requestCode != CODICE_QR_FOTOCAMERA && requestCode != CODICE_QR_IMMAGINE
        ) return
        val esito = richiestaInCorso ?: return
        richiestaInCorso = null

        if (requestCode == CODICE_QR_FOTOCAMERA) {
            val testo = data?.getStringExtra(ScansionaQr.EXTRA_TESTO)
            if (testo != null) {
                esito.success(testo)
            } else {
                // Annullare non e' un errore; negare il permesso si', ed e'
                // l'unico caso in cui Dart ha qualcosa da spiegare.
                when (val errore = data?.getStringExtra(ScansionaQr.EXTRA_ERRORE)) {
                    null -> esito.success(null)
                    else -> esito.error(errore, null, null)
                }
            }
            return
        }

        if (requestCode == CODICE_QR_IMMAGINE) {
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                esito.success(null)   // annullato
                return
            }
            try {
                val testo = contentResolver.openInputStream(data.data!!)
                    ?.use { LettoreQr.daFlusso(it) }
                // "Nessun QR nell'immagine" e "immagine illeggibile" chiedono
                // due cose diverse a chi la usa: riprova a inquadrare, oppure
                // scegli un altro file. Restano distinti fino a Dart.
                if (testo != null) esito.success(testo)
                else esito.error("nessun_qr", null, null)
            } catch (e: Exception) {
                esito.error("immagine", null, null)
            }
            return
        }

        if (requestCode == CODICE_SALVA) {
            val testo = backupDaScrivere
            // Il vault cifrato non resta in memoria un istante piu' del
            // necessario, nemmeno quando l'utente annulla.
            backupDaScrivere = null
            if (resultCode != Activity.RESULT_OK || data?.data == null || testo == null) {
                esito.success(false) // annullato: non e' un errore
            } else {
                esito.success(scriviUri(data.data!!, testo))
            }
            return
        }

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            esito.success(null) // l'utente ha annullato: non è un errore
            return
        }
        esito.success(leggiUri(data.data!!))
    }

    private fun scriviUri(uri: Uri, testo: String): Boolean = try {
        // "wt" tronca quello che c'era: senza, sovrascrivendo un backup piu'
        // grande resterebbe in coda la parte vecchia e il file non si aprirebbe.
        contentResolver.openOutputStream(uri, "wt")?.use {
            it.write(testo.toByteArray(Charsets.UTF_8))
        } != null
    } catch (e: Exception) {
        false
    }
}
