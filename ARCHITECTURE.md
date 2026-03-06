# hiBOB — Estado del Desarrollo y Arquitectura Técnica

> Documento generado: 2026-03-05
> Proyecto: **Gemini Live Agent Challenge** — Asistente multimodal accesible (vista + habla) para personas con discapacidad visual

---

## Índice

1. [Visión general del sistema](#1-visión-general-del-sistema)
2. [Stack tecnológico](#2-stack-tecnológico)
3. [Arquitectura del Backend (NestJS)](#3-arquitectura-del-backend-nestjs)
4. [Arquitectura de la App (Flutter)](#4-arquitectura-de-la-app-flutter)
5. [Flujo multimodal: visión + habla con gestión de interrupciones](#5-flujo-multimodal-visión--habla-con-gestión-de-interrupciones)
6. [Autenticación y seguridad](#6-autenticación-y-seguridad)
7. [Persistencia de datos](#7-persistencia-de-datos)
8. [Despliegue](#8-despliegue)

---

## 1. Visión general del sistema

hiBOB es un agente de IA multimodal que utiliza la **Gemini Multimodal Live API** para ofrecer una interacción fluida y en tiempo real. A diferencia de los sistemas secuenciales tradicionales, hiBOB utiliza **Bidi-Streaming** (bidirectional streaming): el usuario envía audio LPCM e imágenes de forma continua, y Gemini responde con audio y texto en tiempo real, permitiendo interrupciones naturales (barge-in).

```
┌──────────────────────────────────────────────────────────────────┐
│                      Dispositivo Móvil (Flutter)                 │
│                                                                  │
│  ┌─────────────┐   ┌──────────────┐   ┌───────────────────────┐ │
│  │   Cámara    │   │  Micrófono   │   │  Altavoz (PCM)        │ │
│  │  (frames)   │   │ (LPCM 16kHz) │   │ (PcmAudioService)     │ │
│  └──────┬──────┘   └──────┬───────┘   └──────────▲────────────┘ │
│         │                 │                       │              │
│  ┌──────▼─────────────────▼───────────────────────┼────────────┐ │
│  │                  CameraScreen                  │            │ │
│  │   Stream continuo → bytes → WebSocket ◄────────┘            │ │
│  │   Control Hardware (Linterna/Haptics) ◄────────┐            │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                              │  Socket.IO         │              │
└──────────────────────────────┼────────────────────┼──────────────┘
                               │ audio_chunk        │ command
                               ▼                    │
┌───────────────────────────────────────────────────┴──────────────┐
│                  Backend NestJS (Cloud Run)                      │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    LiveGateway (WebSocket)                  │ │
│  │  Proxy de bytes ◄──► GeminiLiveSession (Bidi-Stream)        │ │
│  │  Gestión de comandos de hardware (Flashlight/Vibrate)       │ │
│  └──────────────────────┬──────────────────────────────────────┘ │
│                         │                                        │
│  ┌──────────────────────▼──────────────────────────────────────┐ │
│  │                    AiService (Agentic Loop)                 │ │
│  │   Gemini 2.0 Flash (Live API) + Agentic Tools               │ │
│  │   [Ubicación, Seguridad, Hardware, Navegación, Web]         │ │
│  └──────────────────────┬──────────────────────────────────────┘ │
│                         │                                        │
│  ┌──────────────────────▼──────────────────────────────────────┐ │
│  │             ConversationService (Firestore)                 │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                   ┌───────────────────────┐
                   │  Google Cloud         │
                   │  ├─ Vertex AI (Live)  │
                   │  ├─ Firestore         │
                   │  └─ Firebase Auth     │
                   └───────────────────────┘
```

---

## 2. Stack tecnológico

### Backend
| Componente | Tecnología | Versión |
|---|---|---|
| Framework | NestJS | ^11.x |
| Runtime | Node.js | LTS |
| IA | Vertex AI (Multimodal Live API) | SDK `@google/genai` (v1.43+) |
| Modelo Live | `gemini-live-2.5-flash-preview` | (modelo multimodal Live usado en este proyecto) |
| WebSocket | `@google/genai` live.connect() + `socket.io` | — |
| Auth | Firebase Admin + Google Auth (GCP Tokens) | — |
| Base de datos | Firestore (Firebase) | — |
| Búsqueda web | Tavily (`@tavily/core`) | ^0.7.2 |

### Mobile
| Componente | Tecnología | Versión |
|---|---|---|
| Framework | Flutter | SDK stable |
| Reproducción LPCM | `flutter_pcm_sound` (24kHz salida Gemini) | ^1.1.0 |
| Registro PCM | `record` (LPCM 16-bit 16kHz entrada usuario) | 6.1.2 |
| Linterna | `torch_light` | ^1.0.1 |
| Vibración | `vibration` | ^2.0.1 |
| Diseño | Glassmorphism & Aura UI | Custom |
| Navegación | Google Maps (simulado/IA) | — |
| TTS | `flutter_tts` (Fallback) | ^4.2.5 |

---

## 3. Arquitectura del Backend (NestJS)

### 3.1 Estructura de directorios

```
backend/src/
├── main.ts                          ← Bootstrap (JSON 20MB, CORS, guards globales)
├── app.module.ts                    ← Módulo raíz (ConfigModule, ThrottlerModule)
├── app.controller.ts / app.service.ts
│
├── common/
│   ├── filters/
│   │   └── http-exception.filter.ts ← Formato JSON unificado para errores
│   ├── guards/
│   │   └── firebase-auth.guard.ts   ← Valida Bearer token Firebase
│   ├── interceptors/
│   │   └── logging.interceptor.ts   ← Registra método, URL, ms de respuesta
│   └── pipes/
│       └── validation.pipe.ts       ← ValidationPipe global (whitelist + transform)
│
└── modules/
    ├── ai/                          ← Integración con Gemini
    │   ├── ai.module.ts
    │   ├── ai.service.ts            ← Agentic loop (principal)
    │   ├── ai.controller.ts         ← POST /ai/generate | POST /ai/stream
    │   └── dto/generate-content.dto.ts
    │
    ├── conversation/                ← Chat persistente
    │   ├── conversation.module.ts
    │   ├── conversation.service.ts  ← Historial en Firestore
    │   ├── conversation.controller.ts
    │   └── dto/create-message.dto.ts
    │
    ├── live/                        ← Sesión en tiempo real
    │   ├── live.module.ts
    │   └── live.gateway.ts          ← WebSocket Gateway
    │
    ├── tools/                       ← Herramientas del agente
    │   ├── tools.module.ts
    │   └── tavily.service.ts        ← Búsqueda web
    │
    └── health/
        ├── health.module.ts
        └── health.controller.ts     ← GET /health
```

### 3.2 AiService — Agentic loop con Gemini

**Inicialización y Conexión:**
hiBOB usa el SDK oficial `@google/genai` con Vertex AI (cuenta de servicio GCP). La conexión Live se establece a través de `ai.live.connect()` del SDK, que gestiona internamente el WebSocket bidi-stream:

```typescript
const liveAi = new GoogleGenAI({ vertexai: true, project, location });
const session = await liveAi.live.connect({
  model: 'models/gemini-2.0-flash',
  config: {
    responseModalities: [Modality.AUDIO],       // Audio bidi
    speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: 'Aoede' } } },
    inputAudioTranscription: {},                // Transcripción del usuario
    outputAudioTranscription: {},               // Transcripción de Gemini
    tools: AGENT_TOOLS,
  },
  // Patrón de Callbacks (SDK v1.43+)
  onmessage: (msg) => this._handleSdkMessage(msg),
  onerror: (err) => this.logger.error(`Error SDK: ${err.message}`),
  onclose: () => this.logger.warn('Sesión cerrada'),
});
```

**Clase `GeminiLiveSession`:**
Clase encargada de la comunicación bidi-stream:

- `connect()`: Establece sesión Live con callbacks (`onmessage`, etc).
- `sendFrameWithPrompt(base64Image, prompt?)`: Envía imagen + texto opcinal en **un único** `sendClientContent` con `turnComplete: true`, garantizando que Gemini genere la respuesta.
- `sendAudioFrame(base64)`: Usa `session.sendRealtimeInput({ audio: ... })` para audio en tiempo real.
- `sendToolResponse(responses)`: Usa `session.sendToolResponse()`.
- `_handleSdkMessage(msg)`: Procesa `LiveServerMessage` (no iterador).

> **Por qué un solo mensaje:** Enviar texto e imagen en llamadas separadas con `turnComplete: false` seguido de un tercer mensaje vacío con `turnComplete: true` es frágil. El SDK puede ignorar el turn complete si no hay contenido adjunto. Consolidar todo en un único `sendClientContent` con `turnComplete: true` es el patrón fiable.

**Variables de entorno relevantes:**
```
GCP_PROJECT_ID=websites-technology
GCP_LOCATION=europe-west1
GEMINI_MODEL=gemini-2.5-flash          ← para endpoints REST (no Live)
GEMINI_MAX_OUTPUT_TOKENS=8192
GEMINI_TEMPERATURE=1.0
GOOGLE_APPLICATION_CREDENTIALS=./credentials/gemini-agent-sa-key.json
```

**Herramientas (Agentic Tools):**
Se han implementado y registrado las siguientes herramientas para dar autonomía al agente:

| Herramienta | Descripción | Acción |
|---|---|---|
| `web_search` | Búsqueda en internet vía Tavily | Información actualizada |
| `get_current_location` | Obtención de coordenadas y dirección | Contexto geográfico |
| `detect_safety_hazards` | Análisis visual profundo de seguridad | Detección de obstáculos/peligros |
| `toggle_flashlight` | Control de la linterna del móvil | Mejora de visión nocturna |
| `trigger_haptic_feedback` | Ejecución de vibraciones (vibrate) | Alertas táctiles |
| `mark_place` | Memoria espacial de objetos/lugares | "Recuerda dónde dejé X" |
| `get_navigation_directions`| Guía de navegación paso a paso | Integración visual tipo Maps |

**Flujo del agentic loop (hasta 5 iteraciones):**
```
1. Enviar prompt + historial + imágenes → Gemini
2. Si la respuesta contiene functionCall:
   a. Extraer nombre y argumentos de la herramienta
   b. Notificar al cliente con "[Buscando información…]" (solo en streaming)
   c. Ejecutar Tavily con la query
   d. Añadir resultado al historial como functionResponse
   e. Repetir desde paso 1
3. Si la respuesta contiene texto → devolver al cliente
4. Si se superan 5 iteraciones → responder con lo disponible
```

**Métodos principales:**

| Método | Descripción |
|---|---|
| `generateContent(prompt, history, images?)` | Genera respuesta bloqueante con agentic loop |
| `generateContentStream(prompt, history, images?, onChunk?)` | Genera respuesta con streaming. El callback `onChunk` se llama por cada fragmento de texto |
| `transcribeAudio(audioBase64, mimeType)` | Transcribe audio usando Gemini multimodal |

**Procesamiento multimodal de imágenes:**
```typescript
// Las imágenes se incluyen como partes inline base64 en el prompt
{
  inlineData: {
    mimeType: 'image/jpeg',
    data: imageBase64  // sin prefijo data:
  }
}
```

### 3.3 LiveGateway — Proxy y Bridging bidi-stream

El `LiveGateway` ya no procesa el audio secuencialmente, sino que actúa como un **Proxy/Bridge** entre el cliente Socket.io y la `GeminiLiveSession`.

**Nuevos Eventos:**
- `audio_chunk`: Recibe fragmentos de audio PCM directamente desde Gemini Vertex y los envía al móvil.
- `command`: Envía instrucciones de hardware (linterna, vibración) al móvil disparadas por tool calls de Gemini.
- `interruption`: Notifica al móvil que Gemini ha detectado una interrupción para detener el TTS actual.

**Protocolo de Audio:**
Se ha migrado de AAC (latencia alta) a **LPCM 16-bit 16kHz Mono**. Este formato es nativo para el procesamiento de Gemini Vertex AI, eliminando la necesidad de transcodificación en el backend.

**Flujo interno de `voice_frame`:**
```
1. Recibir `audioBase64` + `frameBase64` desde el móvil
2. Enviar audio realtime a Gemini: `sendAudioFrame(audioBase64)` con `audio/pcm;rate=16000`
3. Enviar contexto visual: `sendFrameWithPrompt(frameBase64)`
4. Retransmitir eventos Live al cliente:
   - `transcription` (input del usuario)
   - `chunk` (texto incremental)
   - `audio_chunk` (`data` + `mimeType`)
   - `interruption` y `done`
```

#### `frame` — Solo imagen (modo proactivo)
```
Cliente → Gateway:
{
  image: string   // Base64 JPEG
}

Gateway → Cliente (streaming):
- Evento 'chunk': { text: string }   ← descripción de lo que ve la cámara
- Evento 'done':  {}
```

**Gestión del historial de conversación:**
- El historial se mantiene **en memoria por sesión WebSocket**
- Se acumula durante toda la sesión activa
- Se pierde al desconectar (no se persiste en Firestore para la sesión Live)

### 3.4 ConversationService — Chat persistente

Gestiona conversaciones REST con historial persistido en Firestore.

**Endpoints:**

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/conversation` | Listar conversaciones del usuario |
| `POST` | `/conversation/chat` | Enviar mensaje (bloqueante) |
| `POST` | `/conversation/chat/stream` | Enviar mensaje (SSE streaming) |
| `POST` | `/conversation/voice` | Enviar audio |
| `GET` | `/conversation/:id/messages` | Obtener mensajes de una conversación |

**Todos los endpoints requieren** `Authorization: Bearer <Firebase ID Token>`.

**Estructura Firestore:**
```
conversations/{conversationId}/
  ├── userId: string
  ├── createdAt: timestamp
  └── messages/{messageId}/
        ├── role: 'user' | 'model'
        ├── text: string
        ├── imageBase64List?: string[]
        └── timestamp: timestamp
```

### 3.5 Configuración global

**Rate limiting:**
```typescript
ThrottlerModule.forRoot([{ ttl: 60000, limit: 60 }])
// 60 requests por minuto por IP
```

**CORS:**
- Desarrollo: wildcard `*`
- Producción: lista de orígenes permitidos

**Límite de body:**
- JSON: 20MB (para soportar imágenes base64 en requests REST)

---

## 4. Arquitectura de la App (Flutter)

### 4.1 Estructura de directorios

```
mobile/lib/
├── main.dart
├── core/
│   ├── services/
│   │   ├── api_service.dart
│   │   ├── live_session_service.dart
│   │   ├── audio_service.dart (LPCM)
│   │   ├── pcm_audio_service.dart [NUEVO]
│   │   └── tts_service.dart
├── features/
│   ├── camera/screens/camera_screen.dart (Bidi-stream logic)
```

### 4.2 Navegación

El usuario interactúa principalmente con `CameraScreen`, donde ocurre la sesión Live.

### 4.3 Servicios core

#### `AudioService` — Grabación PCM
- Formato: **LPCM 16-bit, 16000 Hz, Mono**.
- Requisito: Formato nativo para Gemini Live API para mínima latencia.

#### `PcmAudioService` [NUEVO] — Reproducción en tiempo real
- Motor: `flutter_pcm_sound`.
- Función: Recibe `audio_chunk` (`data` + `mimeType`) y reproduce inmediatamente solo si el `mimeType` es `audio/pcm`.
- Ventaja: Conversación fluida con latencia imperceptible.

#### `LiveSessionService` — Cliente WebSocket
- Eventos añadidos:
  - `onAudioChunk`: Stream de audio PCM entrante.
  - `onInterruption`: Notificación de interrupción detectada por el modelo.
  - `onCommand`: Instrucciones de hardware (linterna/vibración).

#### `FirebaseService` — Autenticación
- Auth con email/contraseña
- `getIdToken(forceRefresh: true)` para tokens siempre frescos
- Stream `authStateChanges` para reactividad

---

### 5.1 Bidi-Streaming vs Secuencial

En la nueva arquitectura, el flujo es **bidireccional y simultáneo**:

1. **Entrada:** El móvil capta audio PCM e imágenes. El audio se captura en PCM y se envía en cada turno de voz detectado por VAD junto con el frame actual.
2. **Procesamiento:** Gemini consume los bytes en tiempo real.
3. **Salida:** En cuanto Gemini genera el primer token de respuesta, el backend envía el `audio_chunk` PCM al móvil.
4. **Interrupción (Barge-in):** Si el usuario empieza a hablar mientras suena el audio de Gemini, el modelo lo detecta (vía backend) y envía una señal de `interruption`. El móvil detiene `PcmAudioService` inmediatamente.

### 5.2 Control de Hardware y Navegación
Gemini puede actuar como un agente físico:
- **Linterna:** "Está muy oscuro" → `toggle_flashlight(true)`.
- **Haptics:** "¡Peligro!" → `vibrate(pattern: 'error')`.
- **Navegación:** "Llévame a la plaza" → Gemini activa el panel de navegación y guía al usuario basándose en la visión de la cámara.

### 5.4 Modo proactivo (descripciones automáticas)

Cuando el usuario no interactúa, el sistema puede enviar frames de la cámara periódicamente para que el agente describa el entorno.

```
Timer configurable (3s – 30s, por defecto 10s)
    │
    ▼
Captura frame actual de la cámara (JPEG base64)
    │
    ▼
Envía evento 'frame' por WebSocket
    │
    ▼
Backend: generateContentStream("Describe lo que ves", [], [imagen])
    │
    ▼
Chunks → TTS (si el usuario no ha interrumpido)
```

El slider de la UI permite ajustar el intervalo en tiempo real. Cambiar el valor reinicia el timer.

### 5.5 Flujo completo de una interacción vocal

```
USUARIO habla
│
▼
[App] AudioService.startRecording()
│     ↑ VAD detecta voz (umbral configurado en app)
│
▼ (fin de voz por silencio o max duración)
[App] AudioService.stopAndGetBase64()
    → audio: string (base64 PCM16 16kHz mono)
│
▼
[App] CameraController.captureFrame()
    → image: string (base64 JPEG)
│
▼
[App] LiveSessionService.sendVoiceFrame(audio, image)
    → WebSocket 'voice_frame' { audioBase64, frameBase64, mimeType='audio/pcm;rate=16000' }
│
▼ (servidor recibe)
[Backend] LiveGateway.handleVoiceFrame()
│
├──► session.sendAudioFrame(audioBase64)
└──► session.sendFrameWithPrompt(frameBase64)
│
▼ (Gemini Live responde en streaming)
[Backend] emite al móvil:
  - 'transcription' { text }
  - 'chunk' { text }
  - 'audio_chunk' { data, mimeType }
  - 'interruption' {}
  - 'done' {}
│
▼
[App] onAudioChunk:
  - si mimeType empieza por 'audio/pcm' → PcmAudioService.feedBase64(data)
  - si no → se ignora el chunk (guardrail)
│
▼ (app recibe 'done')
[App] Estado → 'listening' (listo para siguiente interacción)
```

Nota: el endpoint REST `/conversation/voice` se mantiene como flujo legado y conserva fallback `audio/m4a`.

### 5.6 Animaciones y Diseño Heroico (UI/UX)

hiBOB no solo es funcional, sino que busca un impacto visual "Wow" mediante:

- **Aura de Gemini:** Un fondo animado con gradientes radiales que cambian de color según el estado:
  - `listening`: Azul/Cyan suave.
  - `recording`: Rojo alerta.
  - `processing`: Púrpura cíclico.
  - `speaking`: Cian vibrante.
- **Glassmorphism:** Uso intensivo de `BackdropFilter` para crear paneles de cristal desenfocado, dando una sensación premium y moderna.
- **Feedback Háptico:** Las transiciones de estado disparan vibraciones sutiles (`vibration`), permitiendo que usuarios invidentes "sientan" la aplicación.

### 5.7 Accesibilidad Universal (A11y)

- **Semantics:** Cada componente visual relevante está envuelto en widgets `Semantics` con etiquetas descriptivas para lectores de pantalla.
- **High Contrast:** El tema oscuro ("Cyber Dark") utiliza contrastes altos para usuarios con baja visión.
- **Barge-in Nativo:** La capacidad de interrumpir al agente por voz hace que la interacción sea natural para personas que no pueden ver botones de "Stop".

---

## 6. Autenticación y seguridad

### Flujo de autenticación

```
[App] Usuario hace login con email/contraseña
    → Firebase Auth SDK
    → Obtiene Firebase User con ID Token (JWT, expira en 1h)

[App] En cada request REST:
    Authorization: Bearer <idToken>
    (Token se refresca automáticamente con forceRefresh: true)

[Backend] FirebaseAuthGuard
    → firebase-admin.auth().verifyIdToken(token)
    → Extrae uid del token verificado
    → Añade req.user = { uid } para el controlador

[App] Al conectar WebSocket:
    io(url, { auth: { token: idToken } })
    → LiveGateway valida token en el handshake antes de aceptar conexión
```

### Consideraciones de seguridad

- Todos los endpoints REST (excepto `/health`) requieren autenticación
- El WebSocket valida el token antes de aceptar la conexión
- Rate limiting: 60 req/min por IP (previene abuso)
- Archivos sensibles en `.gitignore`:
  - `google-services.json` (Android)
  - `GoogleService-Info.plist` (iOS)
  - `*.env`, `credentials/`

---

## 7. Persistencia de datos

### Firestore — Estructura

```
conversations/
└── {conversationId}/              ← ID generado por UUID en el cliente
    ├── userId: string             ← UID de Firebase Auth
    ├── createdAt: Timestamp
    └── messages/
        └── {messageId}/
            ├── role: 'user' | 'model'
            ├── text: string
            ├── imageBase64List: string[]  ← opcional
            └── timestamp: Timestamp
```

### Qué se persiste y qué no

| Canal | Persistencia |
|---|---|
| Chat REST (`/conversation/chat`) | Sí, en Firestore |
| Sesión Live (WebSocket) | No, historial en memoria durante la sesión |

El historial de la sesión Live se mantiene en memoria en el `LiveGateway` por socket. Al desconectar, se pierde. Esto es intencional para reducir latencia y costes de escritura en Firestore durante interacciones en tiempo real.

---

## 8. Despliegue

---

## 9. Informe de depuracion Live API (2026-03-05)

### 9.1 Resumen de causa raiz

- La app **si conectaba** al backend local (`host=10.0.2.2:3000` en `LiveGateway`).
- El cierre temprano de sesion no era por camara, Socket.io ni Firebase Auth.
- El problema era el modelo Live configurado:
  - `gemini-2.0-flash-live-001` era rechazado en este entorno con cierre `1008`.
- Modelo validado en AI Studio/Vertex para este proyecto:
  - `gemini-2.0-flash-live-preview-04-09`

### 9.2 Evidencia observada en logs

- Con modelo incorrecto:
  - `Gemini Live SDK: loop cerrado`
  - `Close code 1008` con razon de `Publisher Model ...`
- Con modelo correcto:
  - `setupComplete`
  - `audio_chunk` en streaming
  - `done` y `interruption` segun flujo
  - cierre `1000` limpio al desconectar

### 9.3 Cambios aplicados en backend

- `backend/src/modules/live/live.gateway.ts`
  - Logs de handshake para confirmar origen/host/token.
  - Manejo explicito de sesion cerrada para evitar timeouts silenciosos.
  - Reenvio de `transcription`, `error`, `close` al cliente.
- `backend/src/modules/ai/ai.service.ts`
  - Live config parametrizable por entorno:
    - `GEMINI_LIVE_MODEL`
    - `GEMINI_LIVE_MINIMAL_CONFIG`
    - `GEMINI_LIVE_DISABLE_TOOLS`
    - `GEMINI_LIVE_DISABLE_SPEECH_CONFIG`
    - `GEMINI_LIVE_DISABLE_TRANSCRIPTIONS`
  - Estado interno de sesion (`isClosed`, `getLastErrorMessage`).
  - Mejor telemetria de cierre/error para diagnostico.
  - Nuevo control de verbosidad:
    - `GEMINI_LIVE_DEBUG_VERBOSE`
    - `false`: logs resumidos
    - `true`: payload/raw detallado para investigacion

### 9.4 Cambios aplicados en mobile

- `mobile/lib/core/services/live_session_service.dart`
  - Log de URL real de WebSocket para confirmar destino efectivo:
    - `Connecting to WebSocket: <base>/live`

### 9.5 Configuracion recomendada actual

Para desarrollo local:

```env
GEMINI_LIVE_MODEL=gemini-live-2.5-flash-preview
GEMINI_LIVE_MINIMAL_CONFIG=true
GEMINI_LIVE_DISABLE_TOOLS=false
GEMINI_LIVE_DISABLE_SPEECH_CONFIG=false
GEMINI_LIVE_DISABLE_TRANSCRIPTIONS=false
GEMINI_LIVE_DEBUG_VERBOSE=false
```

### 9.6 Nota operativa

- Los warnings de `CameraValidator` en emulador Android pueden aparecer de forma intermitente y no implican fallo de la sesion Live.
- Si se necesita analizar cierres nuevamente, activar temporalmente:
  - `GEMINI_LIVE_DEBUG_VERBOSE=true`

### Backend — Google Cloud Run

- **Servicio:** `hibob-backend`
- **Región:** `europe-west1`
- **URL:** `https://hibob-backend-777378009998.europe-west1.run.app`
- **Autenticación GCP:** Service Account con `GOOGLE_APPLICATION_CREDENTIALS`
- **Configuración:** Variables de entorno vía Secret Manager (producción)
- **CI/CD:** GitHub Actions (`.github/workflows/`)

### App — Flutter Mobile

- Plataformas configuradas: iOS y Android
- Configuración de backend: URL hardcodeada en `ApiService` (producción)
- Firebase: `google-services.json` (Android) y `GoogleService-Info.plist` (iOS)

### Variables de entorno (backend)

```env
GCP_PROJECT_ID=websites-technology
GCP_LOCATION=europe-west1
GEMINI_MODEL=gemini-3.1-flash-lite-preview
GEMINI_MAX_OUTPUT_TOKENS=8192
GEMINI_TEMPERATURE=1.0
GOOGLE_APPLICATION_CREDENTIALS=./credentials/gemini-agent-sa-key.json
FIREBASE_PROJECT_ID=websites-technology
TAVILY_API_KEY=tvly-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
PORT=3000
NODE_ENV=production
```

### 9.7 Ajustes recientes de estabilidad de audio y turn-taking (2026-03-05)

Cambios aplicados para evitar respuestas interrumpidas y mejorar deteccion de voz del usuario:

- `mobile/lib/features/camera/screens/camera_screen.dart`
  - Ajuste de VAD para mejorar turn-taking:
    - `_vadThresholdDb: -68.0`
    - `_silenceMs: 900`
    - `_maxRecordMs: 6000`
    - `_proactiveIntervalSec: 30`
  - Se actualiza `_lastInteractionTime` al recibir:
    - `onAudioChunk`
    - `onInterruption`
    - `onDone`
  - El temporizador proactivo ahora evita disparos si hay voz activa:
    - `if (_isVoiceActive) return;`
- `mobile/lib/core/services/live_session_service.dart`
  - `voice_frame` usa MIME consistente con el audio capturado:
    - `audio/pcm;rate=16000`
  - `audio_chunk` incluye metadata de formato:
    - `{ data, mimeType }`
- `mobile/lib/core/services/pcm_audio_service.dart`
  - Reproducción defensiva:
    - Solo acepta chunks `audio/pcm`
    - Ignora formatos no PCM

Resultado esperado:
- Menos interrupciones espurias entre turnos.
- Menos casos de "solo responde al inicio y luego no vuelve a contestar".
- Mejor deteccion de entrada de voz frente al modo proactivo.

---

## 10. Checklist de cumplimiento del Hackathon (Devpost) - estado al 2026-03-05

Referencia oficial:
- Pagina principal: `https://geminiliveagentchallenge.devpost.com/`
- Reglas: `https://geminiliveagentchallenge.devpost.com/rules`

### 10.1 Requisitos tecnicos del proyecto (codigo/arquitectura)

1. Agente multimodal con entradas/salidas no solo texto:
   - Estado: CUMPLE
   - Evidencia: camara + audio de usuario + salida de audio en Live API.
2. Uso de Gemini Live API / Gemini model:
   - Estado: CUMPLE
   - Evidencia: `AiService` + `GeminiLiveSession` con `@google/genai`.
3. Uso de Google GenAI SDK o ADK:
   - Estado: CUMPLE
   - Evidencia: `@google/genai` en backend.
4. Backend alojado en Google Cloud:
   - Estado: CUMPLE
   - Evidencia: despliegue en Cloud Run documentado.
5. Uso de al menos un servicio de Google Cloud:
   - Estado: CUMPLE
   - Evidencia: Cloud Run + Vertex AI + Firestore/Firebase Auth.
6. Arquitectura de agente robusta (manejo de errores/interrupciones):
   - Estado: CUMPLE (con mejoras recientes)
   - Evidencia: manejo `close/error/interruption`, estados de sesion y telemetria.

### 10.2 Requisitos de entrega Devpost (submission package)

1. Descripcion de proyecto (features, stack, aprendizajes):
   - Estado: CUMPLE (material disponible en README/arquitectura; requiere pegar en Devpost).
2. Repositorio publico + instrucciones de arranque:
   - Estado: CUMPLE (README con pasos; requiere repo publico al enviar).
3. Prueba de despliegue en Google Cloud (video corto o evidencia de codigo):
   - Estado: PARCIAL
   - Nota: hay evidencia en codigo; falta adjuntar prueba explicita en la submission.
4. Diagrama de arquitectura:
   - Estado: CUMPLE
   - Evidencia: diagrama incluido en este documento.
5. Video demo (<= 4 min, software real, pitch claro, en ingles o subtitulado):
   - Estado: PENDIENTE DE ENTREGA
   - Nota: requisito de submission, no del runtime del repo.

### 10.3 Conclusion de cumplimiento

Con la implementacion actual del repositorio, hiBOB CUMPLE los requisitos tecnicos centrales del Gemini Live Agent Challenge.

Para una conformidad completa de submission en Devpost, solo falta asegurar que en la entrega final esten adjuntos:
- video demo final,
- prueba explicita de despliegue en Google Cloud,
- y completar el formulario de texto en Devpost con el material ya documentado.
