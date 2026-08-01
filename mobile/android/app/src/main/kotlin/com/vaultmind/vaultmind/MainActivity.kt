package com.vaultmind.vaultmind

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Il ponte fra Android e l'app: scelta del file di backup e apertura da una
 * chat ("Apri con VaultMind").
 *
 * Scritto a mano invece di usare un pacchetto per scegliere i file: quelli
 * disponibili non compilano con la versione del Gradle Plugin che Flutter usa
 * qui, e comunque l'"Apri con" avrebbe richiesto codice nativo lo stesso.
 * Meno dipendenze da cui dipendere, e una cosa sola da mantenere.
 */
class MainActivity : FlutterActivity() {

    private val canale = "vaultmind/file"
    private var richiestaInCorso: MethodChannel.Result? = null
    private var metodi: MethodChannel? = null

    /** Contenuto arrivato da "Apri con", in attesa che Dart lo chieda. */
    private var inAttesa: String? = null

    companion object {
        private const val CODICE_SCEGLI = 4711
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
        if (requestCode != CODICE_SCEGLI) return
        val esito = richiestaInCorso ?: return
        richiestaInCorso = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            esito.success(null) // l'utente ha annullato: non è un errore
            return
        }
        esito.success(leggiUri(data.data!!))
    }
}
