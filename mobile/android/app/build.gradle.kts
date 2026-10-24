import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// La firma dell'APK. Le credenziali stanno in android/key.properties, che NON
// e' in git: contiene la password del keystore, ed e' l'unico modo di perdere
// per sempre la possibilita' di aggiornare l'app di chiunque ce l'abbia.
// Il modello e' in key.properties.esempio.
val fileChiavi = rootProject.file("key.properties")
val chiavi = Properties().apply {
    if (fileChiavi.exists()) fileChiavi.inputStream().use { load(it) }
}

android {
    namespace = "com.vaultmind.vaultmind"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.vaultmind.vaultmind"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("rilascio") {
            // Se key.properties manca, questi restano nulli e il controllo piu'
            // sotto ferma la build: meglio non costruire niente che consegnare
            // un APK firmato di debug credendolo firmato davvero.
            keyAlias = chiavi.getProperty("keyAlias")
            keyPassword = chiavi.getProperty("keyPassword")
            storePassword = chiavi.getProperty("storePassword")
            chiavi.getProperty("storeFile")?.let { storeFile = file(it) }
        }
    }

    buildTypes {
        release {
            // NIENTE ripiego sulla chiave di debug. Era il comportamento di
            // prima ed e' il piu' pericoloso possibile: la build riesce, l'APK
            // si installa, e nessuno si accorge che chiunque potrebbe
            // confezionare un finto aggiornamento che il telefono accetta.
            signingConfig =
                if (fileChiavi.exists()) signingConfigs.getByName("rilascio") else null
        }
    }
}

// Il controllo sta QUI e non dentro `release { }`: quel blocco Gradle lo valuta
// sempre, anche quando gli si chiede una build di debug, e un errore li' dentro
// impedirebbe pure `flutter build apk --debug`. Cosi' invece si ferma solo la
// cosa che sarebbe pericolosa consegnare.
tasks.matching { it.name.startsWith("package") && it.name.contains("Release") }
    .configureEach {
        doFirst {
            if (!fileChiavi.exists()) {
                throw GradleException(
                    "android/key.properties non trovato: senza, l'APK di rilascio " +
                    "non sarebbe firmato col timbro vero. Copia " +
                    "key.properties.esempio, mettici la password del keystore, " +
                    "e rilancia. Vedi TODO.md 1.1."
                )
            }
        }
    }

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Impronta digitale. Si usa direttamente la libreria di Android invece di
    // un pacchetto Flutter: la chiave del vault va protetta dal Keystore con
    // l'autenticazione obbligatoria, e quel controllo si fa solo di qui.
    implementation("androidx.biometric:biometric:1.1.0")

    // Lettura dei QR della 2FA. Stessa regola dell'impronta: librerie Android,
    // non pacchetti Flutter.
    //
    // ZXing core e' Java puro e sta tutto dentro l'APK: nessuna rete, nessun
    // Google Play Services, nessun modello da scaricare al primo uso. ML Kit
    // avrebbe fatto lo stesso lavoro meglio, ma e' un componente Google e
    // nella variante leggera il modello se lo scarica -- in un prodotto che
    // promette di non parlare con nessuno, non e' un dettaglio.
    implementation("com.google.zxing:core:3.5.3")

    // FileProvider, per passare l'APK dell'aggiornamento all'installer di
    // sistema. Arriverebbe comunque di rimbalzo da biometric e camera, ma una
    // dipendenza che si usa si dichiara: il giorno che una di quelle due
    // cambia, l'aggiornamento dentro l'app non deve smettere di compilare per
    // un motivo che non c'entra niente.
    implementation("androidx.core:core:1.13.1")

    // CameraX per l'anteprima dal vivo. camera2 nudo sarebbe cinque volte il
    // codice e una manciata di telefoni su cui non funziona.
    implementation("androidx.camera:camera-core:1.4.2")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
}

flutter {
    source = "../.."
}
