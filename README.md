# hiBOB — Gemini Live Agent Challenge

Agente de IA multimodal que ve, escucha y habla en tiempo real usando **Gemini 2.5 Flash** en Google Cloud.

## Demostración rápida

| Función | Descripción |
|---------|-------------|
| 💬 Chat con streaming | Respuestas en tiempo real con historial persistido |
| 🎙️ Voz a voz | Graba un audio → el agente transcribe y responde |
| 📸 Visión puntual | Captura una foto y pregunta sobre ella |
| 📷 Visión en directo | Modo live: el agente ve la cámara cada 3 s y responde por voz |
| 🔍 Búsqueda web | Function calling con Tavily — busca en internet de forma autónoma |

## Stack tecnológico

```
Flutter 3.24 (Android / iOS)
  └── Riverpod · firebase_auth · socket_io_client · flutter_tts

NestJS 11 (Cloud Run — europe-west1)
  ├── Vertex AI Gemini 2.5 Flash (texto · imagen · audio · streaming)
  ├── WebSocket /live (socket.io) — visión continua
  ├── Tavily — búsqueda web via Function Calling
  └── Firebase Admin — Firestore (historial) · Auth (tokens)
```

## Ejecutar en local

### Backend

```bash
cd backend
cp .env.example .env        # rellenar GCP_PROJECT_ID, TAVILY_API_KEY...
npm install
npm run start:dev           # http://localhost:3000
```

Requisitos:
- Node 22+
- `GOOGLE_APPLICATION_CREDENTIALS` apuntando al JSON del Service Account
- API Key de Tavily en `TAVILY_API_KEY`

### Flutter (emulador Android)

```bash
cd mobile
flutter pub get
flutter run                 # apunta automáticamente a http://10.0.2.2:3000
```

## Arquitectura

```
Flutter App
  ├── _AuthGate → Firebase Auth anónimo
  ├── ChatScreen → POST /conversation/chat/stream (SSE)
  ├── CameraScreen (foto) → POST /conversation/chat
  ├── CameraScreen (live) → WS /live → frames cada 3 s → TTS
  └── ConversationsScreen → GET /conversation

NestJS Backend (Cloud Run)
  ├── FirebaseAuthGuard → verifica Bearer token
  ├── ConversationController (REST + SSE)
  ├── LiveGateway (WebSocket /live)
  ├── AiService → Gemini 2.5 Flash + agentic loop Function Calling
  │   └── TavilyService → búsqueda web en tiempo real
  └── Firebase Admin → Firestore + Auth
```

## Variables de entorno necesarias

| Variable | Descripción |
|----------|-------------|
| `GCP_PROJECT_ID` | ID del proyecto GCP |
| `GCP_LOCATION` | Región Vertex AI (ej. `europe-west1`) |
| `GEMINI_MODEL` | Modelo a usar (`gemini-2.5-flash`) |
| `GOOGLE_APPLICATION_CREDENTIALS` | Ruta al JSON del Service Account (solo local) |
| `FIREBASE_PROJECT_ID` | ID del proyecto Firebase |
| `TAVILY_API_KEY` | API Key de app.tavily.com |

## CI/CD

Cada push a `master` con cambios en `backend/` desencadena automáticamente:

```
GitHub Actions → Build Docker → Artifact Registry → Cloud Run (europe-west1)
```

Autenticación via Workload Identity Federation (sin key JSON en CI).

---

Proyecto desarrollado para el **Gemini Live Agent Challenge** de Google.
