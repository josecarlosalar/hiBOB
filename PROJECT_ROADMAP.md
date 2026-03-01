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

### 🔲 Fase 2: Streaming de Cámara Continuo

- [ ] Flutter: captura periódica de frames (cada N segundos) mientras el agente escucha
- [ ] Flutter: integrar audio en tiempo real con el stream de cámara
- [ ] Backend: endpoint WebSocket o SSE bidireccional para sesión de visión continua
- [ ] Gemini Live API: evaluar `BidiGenerateContent` para latencia mínima
- **DoD:** El agente "ve" lo que apunta la cámara de forma continua y responde en voz

---

### 🔲 Fase 3: Agente con Memoria y Herramientas (Function Calling)

- [ ] System instructions configurables por conversación
- [ ] Function Calling en `AiService`: definir herramientas (búsqueda web, calendario, etc.)
- [ ] Ejecutar herramientas en el backend y devolver resultado a Gemini
- [ ] Historial de conversaciones persistido correctamente en Firestore
- **DoD:** El agente recuerda la conversación anterior y puede llamar herramientas externas

---

### 🔲 Fase 4: Despliegue y Distribución (GCP)

- [ ] Dockerfile en `backend/` optimizado para Cloud Run
- [ ] CI/CD con GitHub Actions: build → push a Artifact Registry → deploy Cloud Run
- [ ] Variables de entorno en Secret Manager (no en el contenedor)
- [ ] Workload Identity Federation (eliminar key JSON en producción)
- [ ] Flutter build release APK
- [ ] Subir app a Firebase App Distribution para los jueces
- **DoD:** App funcionando en un móvil real sin necesidad de tiendas ni localhost

---

### 🔲 Fase 5: Optimización Final

- [ ] UX: indicadores de carga, animaciones de grabación, feedback de error
- [ ] Google Cloud Logging: structured logs con severity y traceId
- [ ] Revisión de seguridad: sin secretos en código, CORS restringido, rate limiting
- [ ] README con instrucciones de demo para los jueces
- **DoD:** Código limpio, sin secretos expuestos, listo para demo pública

---

## 3. Arquitectura Actual

```
Flutter App
  ├── _AuthGate → Firebase Auth (anónimo)
  ├── ChatScreen → POST /conversation/chat/stream (SSE)
  ├── CameraScreen → POST /conversation/chat (foto + texto)
  └── ConversationsScreen → GET /conversation

NestJS Backend (localhost:3000 / Cloud Run)
  ├── FirebaseAuthGuard → verifica Bearer token
  ├── ConversationController
  │   ├── POST /chat → ConversationService.chat()
  │   ├── POST /chat/stream → ConversationService.chatStream() [SSE]
  │   ├── POST /voice → ConversationService.processVoice()
  │   └── GET / → ConversationService.listConversations()
  ├── AiService → Vertex AI Gemini 2.5 Flash
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
