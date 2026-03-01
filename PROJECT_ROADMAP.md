# Roadmap: Gemini Live Agent Challenge (Mobile Edition)

Este documento guía la creación de un agente de IA que utiliza visión en tiempo real (cámara) y voz para asistir al usuario.

## 1. Stack Tecnológico

| Componente | Tecnología | Estado |
|---|---|---|
| Frontend | Flutter 3.24.4 | ✅ Activo |
| Backend | NestJS + Cloud Run | ✅ Activo |
| IA Engine | Vertex AI **Gemini 2.5 Flash** | ✅ Activo |
| Auth | Firebase Auth (anónimo) | ✅ Activo |
| Base de datos | Firestore | ✅ Activo |
| Despliegue | Cloud Run | 🔲 Fase 4 |

> ⚠️ Gemini 2.0 Flash se retira el 01/06/2026. El proyecto usa **gemini-2.5-flash**.

---

## 2. Fases de Desarrollo

### ✅ Fase 0: Inicialización del Proyecto — COMPLETADA

- [x] Estructura monorepo: `/mobile` (Flutter) y `/backend` (NestJS)
- [x] Firebase inicializado: Firestore + apps Android e iOS registradas
- [x] Service Account `gemini-agent-sa` creado con roles: `aiplatform.user`, `datastore.user`, `logging.logWriter`
- [x] APIs habilitadas: aiplatform, run, firestore, firebase, iam
- [x] Key JSON en `backend/credentials/` (protegida por .gitignore)
- [x] ADC configurado (`gcloud auth application-default login`)
- **DoD ✅:** Flutter analiza sin errores · Backend responde en `http://localhost:3000/health`

---

### ✅ Fase 1: Motor Multimodal + Auth + Streaming — COMPLETADA

**Backend:**
- [x] `AiService` con Vertex AI Gemini 2.5 Flash (texto, imágenes, audio, streaming SSE)
- [x] `FirebaseAuthGuard` — verifica ID token Firebase en cada request
- [x] `POST /conversation/chat` — respuesta bloqueante con historial Firestore
- [x] `POST /conversation/chat/stream` — SSE: chunks en tiempo real con historial
- [x] `POST /conversation/voice` — transcripción de audio M4A + respuesta del agente
- [x] `GET /conversation` — lista conversaciones del usuario autenticado
- [x] `GET /health` — health check
- [x] Filtro global de excepciones + LoggingInterceptor + ValidationPipe

**Flutter:**
- [x] `LoginScreen` + `_AuthGate` — login anónimo, redirige automáticamente
- [x] `ApiService` con Bearer token en todos los headers
- [x] `ChatScreen` — streaming SSE (chunks aparecen en tiempo real en la burbuja)
- [x] `InputBar` con botón de micrófono (grabar / detener)
- [x] `AudioService` — graba voz en M4A con `record` + `path_provider`
- [x] `CameraScreen` — captura foto y pregunta multimodal al agente
- [x] `ConversationsScreen` — historial persistido, navega a conversaciones anteriores
- [x] NavigationBar con 3 tabs: Chat · Cámara · Historial
- [x] Permisos `RECORD_AUDIO` + `CAMERA` en Android y iOS

- **DoD ✅:** Flutter → NestJS → Vertex AI → respuesta en pantalla · Auth end-to-end · Streaming real

---

### ✅ Fase 2: Streaming de Cámara Continuo — COMPLETADA

**Backend:**
- [x] `LiveGateway` — WebSocket gateway en namespace `/live` con socket.io
- [x] `FirebaseAuthGuard` en handshake WebSocket (verifica Bearer token al conectar)
- [x] Evento `frame` recibe `{conversationId, frameBase64, prompt?}` y llama a `AiService`
- [x] Emite chunks en tiempo real via `client.emit('chunk', {text})`
- [x] Emite respuesta completa via `client.emit('done', {text, conversationId})`
- [x] `LiveModule` registrado en `AppModule`

**Flutter:**
- [x] `LiveSessionService` — cliente socket.io conectando a `/live` con auth token
- [x] Streams: `onChunk`, `onDone`, `onStateChange` (disconnected/connecting/connected/error)
- [x] `TtsService` — wrapper `flutter_tts` en español, toggle on/off
- [x] `CameraScreen` — modo en directo: captura frame cada 3 s via `Timer.periodic`
- [x] Badge de estado "En directo / Conectando…" sobre la preview de cámara
- [x] Auto-reproducción TTS de las respuestas del agente
- [x] Toggle voz en AppBar

- **DoD ✅:** El agente "ve" lo que apunta la cámara de forma continua y responde en voz

---

### ✅ Fase 3: Agente con Herramientas (Function Calling) — COMPLETADA

**Backend:**
- [x] `TavilyService` — cliente `@tavily/core` con método `search(query, maxResults)`
- [x] `ToolsModule` — módulo que exporta `TavilyService`, importado por `AiModule`
- [x] `AiService` — Function Declaration `web_search` registrada con `SchemaType` de Vertex AI
- [x] Agentic loop (hasta 5 iteraciones): Gemini decide cuándo llamar a `web_search`, el backend ejecuta Tavily y devuelve `functionResponse`, Gemini genera la respuesta final con los datos
- [x] En modo streaming: el cliente recibe `[Buscando información…]` mientras se ejecuta la herramienta
- [x] `processAudio` usa modelo sin tools para evitar llamadas innecesarias en transcripción
- [x] `TAVILY_API_KEY` añadida a `.env.example` y `.env`

- **DoD ✅:** El agente busca en internet de forma autónoma cuando lo necesita, sin cambios en el cliente Flutter

---

### ✅ Fase 4: Despliegue y Distribución (GCP) — COMPLETADA

**Infraestructura como código:**
- [x] `backend/Dockerfile` multistage (builder + runner), node:22-alpine, usuario no-root, puerto 8080
- [x] `backend/.dockerignore` — excluye `.env`, `credentials/`, `dist/`, `node_modules/`
- [x] `.github/workflows/deploy.yml` — push a `master` → build Docker → push Artifact Registry → `gcloud run deploy`
- [x] Workload Identity Federation en el workflow (sin key JSON en CI/CD)
- [x] Variables de entorno via Secret Manager (`--set-secrets` en deploy)
- [x] CORS restrictivo en producción con variable `ALLOWED_ORIGINS`

**Pasos manuales pendientes (ejecutar una sola vez):**
1. Crear repo Artifact Registry: `gcloud artifacts repositories create hibob --repository-format=docker --location=us-central1`
2. Crear secrets en Secret Manager: `hibob-gcp-project-id`, `hibob-firebase-project-id`, `hibob-tavily-api-key`, `hibob-gemini-model`
3. Configurar Workload Identity Federation y añadir `WIF_PROVIDER` + `WIF_SERVICE_ACCOUNT` como secrets en GitHub
4. Flutter release: `cd mobile && flutter build apk --release`
5. Subir APK a Firebase App Distribution

- **DoD ✅:** Pipeline CI/CD listo · Dockerfile y workflow creados · APK distribuible

---

### ✅ Fase 5: Optimización Final — COMPLETADA

**UX Flutter:**
- [x] `InputBar` — animación pulsante (ScaleTransition) en botón micrófono durante grabación
- [x] `InputBar` — hint text dinámico: "Grabando…" / "El agente está respondiendo…" / "Escribe un mensaje…"
- [x] `InputBar` — campo de texto deshabilitado mientras el agente responde
- [x] `MessageBubble` — indicador de escritura animado (tres puntos) mientras el modelo genera respuesta

**Seguridad Backend:**
- [x] Rate limiting global: 60 peticiones/minuto por IP (`@nestjs/throttler` + `ThrottlerGuard`)
- [x] CORS restringido en producción con `ALLOWED_ORIGINS`
- [x] Sin secretos en código — todas las variables via `.env` / Secret Manager en Cloud Run

**Documentación:**
- [x] `README.md` en raíz del repositorio con tabla de funciones, stack, instrucciones de arranque y arquitectura

- **DoD ✅:** Código listo para demo · UX pulida · Seguridad aplicada · README para jueces

---

## 3. Arquitectura Actual

```
Flutter App
  ├── _AuthGate → Firebase Auth (anónimo)
  ├── ChatScreen → POST /conversation/chat/stream (SSE)
  ├── CameraScreen (foto) → POST /conversation/chat (foto + texto)
  ├── CameraScreen (live) → WS /live (frames cada 3s) → chunks + TTS
  └── ConversationsScreen → GET /conversation

NestJS Backend (localhost:3000 / Cloud Run)
  ├── FirebaseAuthGuard → verifica Bearer token (HTTP y WS handshake)
  ├── ConversationController
  │   ├── POST /chat → ConversationService.chat()
  │   ├── POST /chat/stream → ConversationService.chatStream() [SSE]
  │   ├── POST /voice → ConversationService.processVoice()
  │   └── GET / → ConversationService.listConversations()
  ├── LiveGateway (WebSocket /live)
  │   ├── on('frame') → AiService.generateContentStream() [streaming]
  │   ├── emit('chunk') → texto parcial al cliente
  │   └── emit('done') → respuesta completa
  ├── AiService → Vertex AI Gemini 2.5 Flash (agentic loop + Function Calling)
  │   └── ToolsModule → TavilyService → búsqueda web en tiempo real
  └── Firebase Admin → Firestore (historial) + Auth (verify token)
```

## 4. Comandos de Desarrollo

```bash
# Backend
cd backend
cp .env.example .env   # completar con valores reales
npm run start:dev      # http://localhost:3000

# Flutter (emulador Android)
cd mobile
flutter run            # apunta a http://10.0.2.2:3000
```
