package com.vaultmind.vaultmind

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.Image
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.io.InputStream

/**
 * Decodifica un QR, da un'immagine o da un fotogramma della fotocamera.
 *
 * Si usa ZXing core (`com.google.zxing:core`), che e' Java puro: nessuna
 * chiamata di rete, nessun Google Play Services, nessun modello da scaricare.
 * L'alternativa ovvia sarebbe ML Kit, che pero' e' un componente Google e
 * nella variante leggera il modello se lo scarica: due cose che in un
 * prodotto offline-first non si possono avere.
 *
 * Scrivere un decodificatore da zero non era in discussione: correzione
 * Reed-Solomon, ricerca dei tre quadrati di allineamento e raddrizzamento
 * prospettico sono ~1500 righe che poi vanno mantenute.
 */
object LettoreQr {

    // TRY_HARDER costa qualche millisecondo e trova i QR storti, piccoli o
    // sfocati: su un fotogramma dal vivo si puo' pagare, e su uno screenshot
    // e' irrilevante.
    private val suggerimenti = mapOf<DecodeHintType, Any>(
        DecodeHintType.TRY_HARDER to true,
    )

    /**
     * Il lato lungo oltre il quale uno screenshot viene rimpicciolito.
     *
     * Uno screenshot di un telefono moderno e' 1440x3200: tenerlo intero vuol
     * dire un array da 4,6 milioni di interi (18 MB) per leggere un quadrato
     * che ne occupa un ventesimo. A 1600 px il QR resta abbondantemente
     * leggibile.
     */
    private const val LATO_MASSIMO = 1600

    /** Il testo del QR, o `null` se nell'immagine non ce n'e' uno leggibile. */
    fun daFlusso(flusso: InputStream): String? {
        val byte = flusso.readBytes()

        // Due passaggi: il primo misura e basta (`inJustDecodeBounds`), cosi'
        // si sa quanto rimpicciolire prima di allocare qualcosa.
        val misura = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(byte, 0, byte.size, misura)
        val lato = maxOf(misura.outWidth, misura.outHeight)
        var scala = 1
        while (lato / scala > LATO_MASSIMO) scala *= 2

        val opzioni = BitmapFactory.Options().apply { inSampleSize = scala }
        val bitmap = BitmapFactory.decodeByteArray(byte, 0, byte.size, opzioni)
            ?: return null
        return try {
            daBitmap(bitmap)
        } finally {
            bitmap.recycle()
        }
    }

    private fun daBitmap(bitmap: Bitmap): String? {
        val l = bitmap.width
        val a = bitmap.height
        val pixel = IntArray(l * a)
        bitmap.getPixels(pixel, 0, l, 0, 0, l, a)
        return leggi(RGBLuminanceSource(l, a, pixel))
    }

    /**
     * Il fotogramma della fotocamera in formato YUV_420_888.
     *
     * Si usa il solo piano Y, che *e'* la luminanza: convertire in RGB per poi
     * riportarlo a scala di grigi sarebbe lavoro sprecato trenta volte al
     * secondo.
     */
    fun daFotogramma(immagine: Image): String? {
        if (immagine.format != android.graphics.ImageFormat.YUV_420_888) return null
        val piano = immagine.planes[0]
        val larghezza = immagine.width
        val altezza = immagine.height
        val passo = piano.rowStride
        val buffer = piano.buffer

        // rowStride puo' essere piu' largo della riga: alcune fotocamere
        // allineano ogni riga in memoria. Copiare tutto il buffer senza
        // tenerne conto darebbe un'immagine inclinata, e nessun QR verrebbe
        // mai trovato -- senza che nulla si lamenti.
        val dati = ByteArray(larghezza * altezza)
        if (passo == larghezza) {
            buffer.get(dati, 0, dati.size)
        } else {
            val riga = ByteArray(passo)
            for (y in 0 until altezza) {
                buffer.position(y * passo)
                val quante = minOf(passo, buffer.remaining())
                buffer.get(riga, 0, quante)
                System.arraycopy(riga, 0, dati, y * larghezza, larghezza)
            }
        }

        return leggi(
            PlanarYUVLuminanceSource(
                dati, larghezza, altezza, 0, 0, larghezza, altezza, false
            )
        )
    }

    /**
     * Tre tentativi, dal piu' probabile al piu' raro.
     *
     * `HybridBinarizer` e' quello giusto per una foto (illuminazione
     * disuniforme), `GlobalHistogramBinarizer` per uno screenshot (due colori
     * netti). Il terzo giro e' sull'immagine **invertita**: un QR bianco su
     * nero non e' conforme allo standard, ma le pagine in tema scuro ne
     * mostrano lo stesso -- e chi ha fatto lo screenshot non ha modo di
     * saperlo.
     */
    private fun leggi(sorgente: LuminanceSource): String? {
        val lettore = QRCodeReader()
        for (bitmap in sequenceOf(
            BinaryBitmap(HybridBinarizer(sorgente)),
            BinaryBitmap(GlobalHistogramBinarizer(sorgente)),
            BinaryBitmap(HybridBinarizer(sorgente.invert())),
        )) {
            try {
                return lettore.decode(bitmap, suggerimenti).text
            } catch (e: Exception) {
                // "Qui non c'e' un QR" e' l'esito normale, non un errore: su un
                // fotogramma dal vivo capita trenta volte al secondo.
                lettore.reset()
            }
        }
        return null
    }
}
