# hiBOB — Tu Guardián Digital en Tiempo Real

**hiBOB** es un Agente de IA de última generación desarrollado para el **Gemini Live Agent Challenge 2026**. Es un asistente de ciberseguridad multimodal que escucha, ve y actúa en tiempo real para protegerte: analiza imágenes con VirusTotal, escanea códigos QR, verifica contraseñas filtradas, genera contraseñas seguras, te guía paso a paso en cualquier tarea de tu móvil en segundo plano y actúa como copiloto de seguridad en tu dispositivo.

> **Categoría:** Agentes en Vivo (Live Agents) — Interacción en tiempo real (audio/visión)

---

## Funcionalidades Principales

### 1. Análisis de Imágenes con VirusTotal

hiBOB puede analizar visualmente cualquier imagen para detectar amenazas de seguridad. El usuario comparte una foto (captura de pantalla, imagen de galería o fotografía directa) y el agente identifica URLs, dominios o elementos sospechosos visibles en ella.

**Flujo técnico:**

```text
Usuario comparte imagen
       ↓
Backend recibe imagen en base64 vía Socket.IO
       ↓
Gemini analiza visualmente la imagen (multimodal)
       ↓
Si detecta URL/dominio → llama analyze_security_url
       ↓
VirusTotal API v3: POST /api/v3/urls → polling GET /api/v3/analyses/{id}
       ↓
Reporte visual en overlay + veredicto de voz por hiBOB
```

El system prompt instruye a Gemini: *"Si ves una URL o dominio escrito claramente, léela tal cual y analízala. Nunca inventes URLs."* Esto garantiza que el análisis sea siempre sobre datos reales, sin alucinaciones.

El reporte visual muestra: motores que detectaron amenaza, total analizado, nivel de peligro (`clean` / `suspicious` / `dangerous` / `critical`).

**Archivos clave:**

- `backend/src/modules/tools/virustotal.service.ts` — `analyzeUrl()`, `analyzeIp()`, `analyzeDomain()`
- `backend/src/modules/live/live.gateway.ts` — `_emitVtReport()`, handler `analyze_security_url`
- `mobile/lib/features/camera/screens/camera_screen.dart` — overlay `VtReportOverlay`

---

### 2. Análisis en Tiempo Real con Cámara Trasera

hiBOB puede activar la cámara trasera del dispositivo y analizar en tiempo real lo que ve: detecta URLs, dominios y códigos QR visibles en el entorno físico —carteles, pantallas, documentos— y los analiza con VirusTotal automáticamente.

**Activación:**

> Usuario: *"Activa la cámara trasera"* → hiBOB activa la cámara y empieza a observar en tiempo real.

**Flujo técnico:**

```text
Usuario activa cámara trasera (voz o botón)
       ↓
Flutter: CameraController → cámara trasera a pantalla completa
       ↓
Stream de frames capturados → enviados al backend vía Socket.IO
       ↓
Gemini analiza visualmente cada frame (multimodal)
       ↓
Si detecta URL, dominio o QR visible en la imagen:
  → Llama analyze_security_url / analyze_domain
  → VirusTotal API v3: análisis en tiempo real
       ↓
Overlay de resultado + veredicto de voz por hiBOB
```

**Casos de uso:**

| Escenario | Qué hace hiBOB |
| --- | --- |
| Carteles con URLs | Lee la URL visible y la analiza con VirusTotal |
| Pantallas con dominios sospechosos | Detecta el dominio y lanza análisis automático |
| Documentos con enlaces | Extrae URLs del texto visible y verifica su seguridad |
| Códigos QR físicos | Detecta el QR, extrae la URL y la analiza antes de escanear |
| Entornos desconocidos | Descripción visual en tiempo real del contexto de seguridad |

La sesión Gemini Live mantiene el contexto visual activo durante toda la interacción: el usuario puede hacer preguntas sobre lo que hiBOB está viendo mientras se realiza el análisis.

**Archivos clave:**

- `backend/src/modules/live/live.gateway.ts` — handler `describe_camera_view`, `switch_camera`
- `mobile/lib/features/camera/screens/camera_screen.dart` — `_handleHardwareCommand()`, stream de frames
- `backend/src/modules/tools/virustotal.service.ts` — `analyzeUrl()`, `analyzeDomain()`

---

### 4. Escaneo de Códigos QR con VirusTotal

hiBOB extrae automáticamente la URL de cualquier código QR —tanto de imágenes de galería como de capturas en vivo con la cámara— y la analiza con VirusTotal antes de que el usuario haga clic en nada.

**Flujo técnico:**

```text
Imagen recibida (galería o frame de cámara)
       ↓
Backend: procesamiento con jsQR + Jimp
  - Estrategia 1: imagen original
  - Estrategia 2: aumento de contraste
  - Estrategia 3: escala de grises + umbralización
  - Cada estrategia probada en 4 rotaciones (0°, 90°, 180°, 270°)
       ↓
QR detectado → URL extraída
       ↓
VirusTotal: análisis de URL en tiempo real
       ↓
Overlay tipo qr_scan + veredicto por voz
```

Para el escaneo con cámara en vivo, el flujo es:

1. Usuario dice "escanea un QR" → Gemini llama `scan_qr_code`
2. Backend emite `frame_request` → Flutter activa cámara trasera a pantalla completa
3. Usuario encuadra el QR y dice "listo" → Gemini llama `trigger_qr_capture`
4. Flutter captura el frame, lo envía al backend vía Socket.IO
5. Backend detecta el QR, extrae URL y lanza análisis VirusTotal

Durante el escaneo, el micrófono se bloquea para evitar interrupciones falsas de la sesión Gemini, y se mantiene un heartbeat cada 5 segundos para preservar la conexión con Cloud Run.

**Archivos clave:**

- `backend/src/modules/live/live.gateway.ts` — lógica jsQR + handler `scan_qr_code` / `trigger_qr_capture`
- `mobile/lib/features/camera/screens/camera_screen.dart` — `_handleFrameRequest()`, overlay QR

---

### 5. Comprobación de Filtración de Contraseñas (HIBP)

hiBOB verifica si una contraseña ha aparecido en brechas de datos conocidas utilizando el protocolo **k-Anonymity** de Have I Been Pwned. La contraseña nunca abandona el servidor en texto plano.

**Flujo técnico con k-Anonymity:**

```text
Usuario proporciona contraseña
       ↓
Backend calcula SHA-1: hash = SHA1("mi_contraseña")
       ↓
Divide: prefix = hash[0:5] | suffix = hash[5:]
       ↓
GET https://api.pwnedpasswords.com/range/{prefix}
  (Solo 5 caracteres se envían a HIBP)
       ↓
HIBP devuelve ~500 hashes que empiezan con ese prefix
       ↓
Búsqueda local del suffix en la lista
       ↓
Si encontrado: contraseña comprometida N veces
Si no: contraseña segura
       ↓
Overlay password_check + veredicto de voz
```

El header `Add-Padding: true` en la petición a HIBP garantiza que la respuesta siempre tenga el mismo tamaño, impidiendo inferencias por análisis de tráfico.

El reporte visual muestra: estado (`Comprometida` / `Segura`), número de veces encontrada en brechas, y nivel de peligro.

**Archivos clave:**

- `backend/src/modules/tools/hibp.service.ts` — `checkPassword()` con k-Anonymity
- `backend/src/modules/live/live.gateway.ts` — handler `check_password_breach`
- `mobile/lib/features/camera/screens/camera_screen.dart` — overlay `_PasswordCheckOverlay`

---

### 6. Generación de Contraseña Segura

hiBOB genera contraseñas criptográficamente seguras con conjuntos de caracteres configurables y entropía calculada, siguiendo un flujo conversacional natural.

**Flujo conversacional:**

```text
Usuario: "Genera una contraseña segura"
       ↓
hiBOB pregunta: "¿La quieres de 16, 24 o 32 caracteres? ¿Con símbolos especiales?"
       ↓
Usuario responde con sus preferencias
       ↓
Gemini llama generate_password con los parámetros
       ↓
Backend genera contraseña + calcula entropía
       ↓
Overlay password_generated con contraseña + botón copiar
```

**Algoritmo de generación:**

```text
Charsets disponibles:
  - Mayúsculas: A-Z (26 caracteres)
  - Minúsculas: a-z (26 caracteres)
  - Números:    0-9 (10 caracteres)
  - Símbolos:   !@#$%^&*()-_=+[]{}|;:,.<>? (32 caracteres)

1. Garantiza al menos 1 carácter de cada charset activo
2. Rellena el resto aleatoriamente con caracteres del pool combinado
3. Mezcla el orden (Fisher-Yates shuffle)
4. Calcula entropía: bits = length × log₂(charsetSize)
   Ejemplo: 32 caracteres, todos los charsets (94) → ~202 bits
```

El resultado incluye: contraseña generada, longitud, entropía en bits y los tipos de caracteres utilizados. Botón de copia al portapapeles integrado en el overlay.

**Archivos clave:**

- `backend/src/modules/tools/hibp.service.ts` — `generateSecurePassword()`
- `backend/src/modules/ai/ai.service.ts` — tool declaration `generate_password`
- `mobile/lib/features/camera/screens/camera_screen.dart` — overlay `_PasswordGeneratedOverlay`

---

### 7. Modo Copiloto

hiBOB actúa como copiloto de seguridad en segundo plano: observa la pantalla del usuario, guía pasos de forma natural y analiza el contexto visual para dar instrucciones precisas y contextualizadas.

**Capacidades del modo copiloto:**

| Acción | Cómo se activa | Qué hace |
| --- | --- | --- |
| Ver pantalla | "¿Puedes ver mi pantalla?" | Captura screenshot → Gemini analiza visualmente → da instrucciones paso a paso |
| Ver cámara | "Activa la cámara trasera" / "¿Qué ves ahora?" | Activa cámara frontal/trasera → stream de frames → análisis visual en tiempo real con detección automática de URLs y QRs |
| Analizar imagen | "Analiza esta imagen" | Abre galería → usuario selecciona → análisis multimodal con Gemini |
| Analizar archivo | "Escanea este PDF" | Abre explorador → upload a VirusTotal → reporte de malware |
| Control de hardware | Comandos de voz | Linterna, vibración, cámara frontal/trasera |

**System prompt del copiloto** (inyectado dinámicamente con el nombre del usuario):

```text
"Eres hiBOB, un agente de seguridad experto.
 El usuario se llama {firstName}. Ya le conoces —
 eres su guardián digital de confianza.
 MODO COPILOTO: Si el usuario necesita ayuda con su móvil,
 guía sus pasos de forma natural como un copiloto experto.
 FLUJO DE SEGURIDAD: Cuando detectes cualquier amenaza,
 llama a la herramienta correspondiente EN EL MISMO TURNO,
 nunca digas 'voy a...' sin llamar a la herramienta inmediatamente."
```

El agente conoce el nombre del usuario (obtenido de Firebase Auth) y lo saluda personalmente en cada sesión, creando una experiencia de asistente que "ya te conoce".

**Herramientas hardware disponibles:**

```text
toggle_flashlight       → Linterna on/off
switch_camera           → Cambio cámara frontal/trasera
capture_device_screen   → Captura pantalla actual
describe_camera_view    → Análisis visual en vivo
open_gallery            → Selector de imágenes/archivos
trigger_haptic_feedback → Vibración con patrones (success/warning/error)
```

**Archivos clave:**

- `backend/src/modules/live/live.gateway.ts` — system prompt dinámico, handlers de hardware
- `mobile/lib/features/camera/screens/camera_screen.dart` — `_handleHardwareCommand()`

---

## Arquitectura Técnica

```text
┌─────────────────────────────────────────────────────────────┐
│                    App Flutter (Android/iOS)                  │
│  Cámara · Micrófono · Audio PCM · Overlays de seguridad      │
└──────────────────────┬──────────────────────────────────────┘
                       │ Socket.IO (WebSocket bidireccional)
                       │ Audio PCM 16kHz · Frames base64
                       ↓
┌─────────────────────────────────────────────────────────────┐
│            NestJS Backend — Google Cloud Run                  │
│                                                               │
│  LiveGateway (WebSocket)                                      │
│  ├─ Gestión de sesiones por UID (reconexión transparente)    │
│  ├─ Routing de tool calls de Gemini                          │
│  └─ Emisión de UI rica (display_content events)             │
│                                                               │
│  AiService                                                    │
│  ├─ Gemini Live Session (gemini-live-2.5-flash-native-audio) │
│  ├─ 15+ tool declarations                                    │
│  └─ System prompt dinámico con nombre de usuario            │
│                                                               │
│  Servicios de herramientas                                    │
│  ├─ VirusTotalService — URL, IP, dominio, hash, archivo      │
│  ├─ HibpService — k-Anonymity + generación de contraseñas   │
│  └─ BraveSearchService — contexto web de amenazas           │
└──────────────────────┬──────────────────────────────────────┘
                       │
          ┌────────────┼────────────┐
          ↓            ↓            ↓
┌─────────────┐ ┌──────────┐ ┌────────────┐
│  Vertex AI  │ │ Firebase │ │  Externos  │
│ Gemini Live │ │   Auth   │ │ VirusTotal │
│ gemini-2.5  │ │Firestore │ │    HIBP    │
│    flash    │ │          │ │   Brave    │
└─────────────┘ └──────────┘ └────────────┘
```

### Stack Tecnológico

#### Backend

- NestJS v11 (TypeScript) alojado en **Google Cloud Run**
- Google GenAI SDK `@google/genai` v1.0 — Gemini Live API via Vertex AI
- Socket.IO v4.8 — comunicación WebSocket bidireccional en tiempo real
- Firebase Admin SDK v13 — autenticación y Firestore
- jsQR + Jimp — detección y procesamiento de códigos QR

#### Mobile

- Flutter SDK ^3.5 (Dart) — Android e iOS
- Flutter Riverpod v2.6 — gestión de estado
- socket_io_client v3.1 — WebSocket cliente
- camera v0.11 + record v6.1 + flutter_pcm_sound v1.1 — captura y reproducción multimodal
- image_picker v1.1 + file_picker v8.1 — selección de imágenes y archivos

#### Servicios Google Cloud

- **Vertex AI** — Gemini 2.5 Flash (modelo principal de IA y herramientas)
- **Gemini Live API** — sesiones de audio/vídeo en tiempo real (`gemini-live-2.5-flash-native-audio`)
- **Cloud Run** — hosting del backend NestJS con escala automática
- **Firebase Auth** — autenticación de usuarios
- **Firestore** — configuración por usuario (voz, preferencias)

---

## Instrucciones de Desarrollo

### Requisitos Previos

- Flutter SDK 3.5+
- Node.js v20+
- Cuenta Google Cloud con **Vertex AI** y **Cloud Run** habilitados
- Proyecto Firebase configurado
- API Keys: `GEMINI_API_KEY`, `VIRUSTOTAL_API_KEY`, `BRAVE_SEARCH_API_KEY`

### Configuración del Backend

```bash
cd backend
cp .env.example .env       # Rellena las credenciales
npm install
npm run start:dev          # Desarrollo con hot-reload
```

Variables de entorno necesarias en `.env`:

```env
GCP_PROJECT_ID=tu-proyecto-gcp
GCP_LOCATION=us-central1
GEMINI_MODEL=gemini-2.5-flash
GEMINI_LIVE_MODEL=gemini-live-2.5-flash-native-audio
GEMINI_API_KEY=tu_api_key
GOOGLE_APPLICATION_CREDENTIALS=./credentials/sa-key.json
FIREBASE_PROJECT_ID=tu-proyecto-firebase
VIRUSTOTAL_API_KEY=tu_api_key
BRAVE_SEARCH_API_KEY=tu_api_key
```

### Configuración del Mobile (Flutter)

```bash
cd mobile
# Añade tu google-services.json (Android) o GoogleService-Info.plist (iOS)
flutter pub get
flutter run                # En dispositivo físico (recomendado)
```

### Despliegue automatizado en Google Cloud Run (CI/CD)

El despliegue está **completamente automatizado** mediante GitHub Actions. Cada push a `master` que modifique el backend dispara automáticamente el pipeline definido en [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml).

**Pipeline de CI/CD:**

1. Autenticación en GCP con **Workload Identity Federation** (sin claves de servicio en el repo)
2. Build de la imagen Docker y push a **Google Artifact Registry**
3. Deploy a **Google Cloud Run** con configuración de secrets desde **GCP Secret Manager**

```yaml
# .github/workflows/deploy.yml (fragmento)
- name: Build y push imagen Docker
  run: |
    docker build -t $IMAGE:${{ github.sha }} ./backend
    docker push $IMAGE:${{ github.sha }}

- name: Deploy a Cloud Run
  run: |
    gcloud run deploy hibob-backend \
      --image $IMAGE:${{ github.sha }} \
      --region europe-west1 \
      --set-secrets="GEMINI_API_KEY=hibob-gemini-api-key:latest,..."
```

Ver el workflow completo: [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)

---

## Prueba de Implementación en Google Cloud

El backend está desplegado en **Google Cloud Run** (`europe-west1`) mediante el pipeline CI/CD automatizado. La integración con Google Cloud puede verificarse en:

- [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) — pipeline completo de CI/CD con GitHub Actions → Artifact Registry → Cloud Run
- `backend/src/modules/ai/ai.service.ts` — inicialización del cliente Vertex AI con `new GoogleGenAI({ vertexai: true, project, location })`
- `backend/src/modules/live/live.gateway.ts` — creación de sesiones Gemini Live con `ai.live.connect()`
- Los logs de Cloud Run muestran las sesiones activas de Gemini Live en tiempo real

---

## Diagrama de Flujo de Seguridad

```text
Usuario habla / comparte imagen
           ↓
    Gemini escucha y analiza
           ↓
    Detecta amenaza o petición
           ↓
    Llama tool EN EL MISMO TURNO
    ┌──────┬──────┬──────┬──────┐
    ↓      ↓      ↓      ↓      ↓
  URL/QR   IP  Dominio  Hash  Contraseña
  VT API VT API VT API VT API  HIBP k-Anon
    ↓      ↓      ↓      ↓      ↓
    └──────┴──────┴──────┴──────┘
           ↓
  Overlay visual en Flutter
  + veredicto de voz en tiempo real
```

---

Desarrollado para el Gemini Live Agent Challenge 2026 · #GeminiLiveAgentChallenge
