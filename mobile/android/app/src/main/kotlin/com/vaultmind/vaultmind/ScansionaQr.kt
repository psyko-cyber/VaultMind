package com.vaultmind.vaultmind

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * La schermata che inquadra un QR e restituisce cosa c'e' scritto dentro.
 *
 * E' un'Activity a se' e non una vista dentro Flutter: mostrare l'anteprima
 * della fotocamera dentro l'albero dei widget vorrebbe dire una PlatformView,
 * cioe' due gerarchie di rendering sovrapposte per una schermata che dura tre
 * secondi. Un'Activity lanciata con `startActivityForResult` e' lo stesso
 * schema gia' usato per il selettore dei file, e si comporta come tutte le
 * altre schermate di sistema.
 *
 * Non conosce il vault e non ne apre nessuno: restituisce una stringa, e cosa
 * ci sia dentro lo decide Dart. Se un giorno servisse leggere un QR per altro
 * (un abbinamento, una configurazione) questa schermata va gia' bene com'e'.
 */
class ScansionaQr : ComponentActivity() {

    companion object {
        const val EXTRA_COLORE = "colore"
        const val EXTRA_TITOLO = "titolo"
        const val EXTRA_TESTO = "testo"
        const val EXTRA_ERRORE = "errore"

        /** L'utente ha negato il permesso della fotocamera. */
        const val ERRORE_PERMESSO = "permesso"

        /** La fotocamera non si e' aperta: non c'e', o la usa un'altra app. */
        const val ERRORE_FOTOCAMERA = "fotocamera"
    }

    private lateinit var anteprima: PreviewView
    private lateinit var esecutore: ExecutorService

    /** Un QR solo: senza, i fotogrammi successivi chiuderebbero due volte. */
    private val giaLetto = AtomicBoolean(false)

    private var accento = Color.parseColor("#7C6CFF")

    private val chiediPermesso =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { concesso ->
            if (concesso) avviaFotocamera() else esci(errore = ERRORE_PERMESSO)
        }

    override fun onCreate(salvato: Bundle?) {
        super.onCreate(salvato)

        // Il QR che si sta inquadrando E' il secret della 2FA: uno screenshot
        // di questa schermata lo conterrebbe per intero. Stessa regola di
        // MainActivity, per la stessa ragione.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )

        // Il colore arriva da Dart: l'app ha tre temi, e una schermata che usa
        // un viola fisso mentre il resto e' oro si vede subito che e' stata
        // aggiunta dopo.
        if (intent.hasExtra(EXTRA_COLORE)) {
            accento = intent.getIntExtra(EXTRA_COLORE, accento)
        }
        val titolo = intent.getStringExtra(EXTRA_TITOLO)
            ?: "Inquadra il QR"

        esecutore = Executors.newSingleThreadExecutor()
        setContentView(costruisciVista(titolo))

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            == PackageManager.PERMISSION_GRANTED
        ) {
            avviaFotocamera()
        } else {
            chiediPermesso.launch(Manifest.permission.CAMERA)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        esecutore.shutdown()
    }

    /**
     * Interfaccia costruita a mano invece che con un layout XML: sono tre
     * viste, e un file di layout in piu' e' un posto in piu' dove i colori
     * del tema possono restare indietro.
     */
    private fun costruisciVista(titolo: String): View {
        anteprima = PreviewView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            // FILL_CENTER: il mirino disegnato sopra deve coincidere con quel
            // che la fotocamera vede davvero, altrimenti si inquadra dentro il
            // riquadro e il QR resta fuori.
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }

        val mirino = Mirino(this, accento).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        val scritta = TextView(this).apply {
            text = titolo
            setTextColor(Color.WHITE)
            setShadowLayer(6f, 0f, 1f, Color.BLACK)   // leggibile su qualsiasi sfondo
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            val m = (24 * resources.displayMetrics.density).toInt()
            setPadding(m, m, m, m * 2)
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM
            )
        }

        return FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(anteprima)
            addView(mirino)
            addView(scritta)
        }
    }

    private fun avviaFotocamera() {
        val futuro = ProcessCameraProvider.getInstance(this)
        futuro.addListener({
            try {
                val fornitore = futuro.get()
                val vista = Preview.Builder().build().also {
                    it.setSurfaceProvider(anteprima.surfaceProvider)
                }
                val analisi = ImageAnalysis.Builder()
                    // Il fotogramma vecchio non serve a niente: se l'analisi e'
                    // in ritardo si salta avanti invece di accodare.
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analisi.setAnalyzer(esecutore, ::esamina)

                fornitore.unbindAll()
                fornitore.bindToLifecycle(
                    this, CameraSelector.DEFAULT_BACK_CAMERA, vista, analisi
                )
            } catch (e: Exception) {
                // Fotocamera assente, occupata da un'altra app, o negata dalle
                // policy aziendali: da qui si esce dicendolo, non piantandosi
                // su un'anteprima nera.
                esci(errore = ERRORE_FOTOCAMERA)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    @ExperimentalGetImage
    private fun esamina(fotogramma: androidx.camera.core.ImageProxy) {
        try {
            if (giaLetto.get()) return
            val immagine = fotogramma.image ?: return
            val testo = LettoreQr.daFotogramma(immagine) ?: return
            if (giaLetto.compareAndSet(false, true)) {
                runOnUiThread { esci(testo = testo) }
            }
        } finally {
            // Senza `close()` la fotocamera esaurisce i buffer e l'anteprima si
            // congela dopo pochi fotogrammi.
            fotogramma.close()
        }
    }

    private fun esci(testo: String? = null, errore: String? = null) {
        val dati = Intent().apply {
            if (testo != null) putExtra(EXTRA_TESTO, testo)
            if (errore != null) putExtra(EXTRA_ERRORE, errore)
        }
        setResult(if (testo != null) Activity.RESULT_OK else Activity.RESULT_CANCELED, dati)
        finish()
    }

    /**
     * Il riquadro al centro: penombra attorno e quattro angoli nel colore del
     * tema.
     *
     * Non serve a ritagliare niente -- si analizza il fotogramma intero -- ma
     * dice dove guardare. Senza, chi inquadra tiene il telefono troppo lontano
     * e il QR resta di dieci pixel.
     */
    private class Mirino(contesto: Context, private val accento: Int) : View(contesto) {
        private val penombra = Paint().apply { color = Color.argb(140, 0, 0, 0) }
        private val angoli = Paint().apply {
            color = accento
            style = Paint.Style.STROKE
            strokeWidth = 4f * contesto.resources.displayMetrics.density
            strokeCap = Paint.Cap.ROUND
            isAntiAlias = true
        }

        override fun onDraw(tela: Canvas) {
            super.onDraw(tela)
            val lato = minOf(width, height) * 0.68f
            val x = (width - lato) / 2f
            val y = (height - lato) / 2f
            val r = RectF(x, y, x + lato, y + lato)
            val raggio = 22f * resources.displayMetrics.density

            // La penombra si disegna come "tutto tranne il riquadro": quattro
            // rettangoli sarebbero quattro occasioni di lasciare una fessura.
            tela.save()
            val foro = Path().apply { addRoundRect(r, raggio, raggio, Path.Direction.CW) }
            tela.clipOutPath(foro)
            tela.drawRect(0f, 0f, width.toFloat(), height.toFloat(), penombra)
            tela.restore()

            val braccio = lato * 0.17f
            for (p in listOf(
                // ogni angolo: due segmenti che partono dallo stesso vertice
                Path().apply {
                    moveTo(r.left, r.top + braccio); lineTo(r.left, r.top); lineTo(r.left + braccio, r.top)
                },
                Path().apply {
                    moveTo(r.right - braccio, r.top); lineTo(r.right, r.top); lineTo(r.right, r.top + braccio)
                },
                Path().apply {
                    moveTo(r.right, r.bottom - braccio); lineTo(r.right, r.bottom); lineTo(r.right - braccio, r.bottom)
                },
                Path().apply {
                    moveTo(r.left + braccio, r.bottom); lineTo(r.left, r.bottom); lineTo(r.left, r.bottom - braccio)
                },
            )) {
                tela.drawPath(p, angoli)
            }
        }
    }
}
