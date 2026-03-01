# Plan de Ejecución - Fase 0: Gemini Live Agent Challenge

## Contexto

El usuario participa en el **Gemini Live Agent Challenge** de Google, categoría "Agentes en vivo" (interacción en tiempo real con audio/visión). El objetivo es construir una app móvil Flutter con backend NestJS en Cloud Run que use Vertex AI para ser un agente multimodal (cámara + voz).

**GCP Project:** `websites-technology` (ya existe, Cloud Storage API ya habilitada)
**Directorio raíz:** `c:\Code\08 - hiBOB`
**Estado actual:** ✅ Fase 0 completada — código en `main` de [github.com/josecarlosalar/hiBOB](https://github.com/josecarlosalar/hiBOB)

> ⚠️ **CAMBIO IMPORTANTE de modelo:** Google ha anunciado el retiro de Gemini 2.0 Flash el 1 de junio de 2026 (proyecto `websites-technology` está afectado). El plan usa **Gemini 2.5 Flash** (`gemini-2.5-flash`) como modelo base.

---

## Stack Tecnológico

| Componente | Tecnología | Versión detectada |
|---|---|---|
| Frontend | Flutter | 3.24.4 |
| Backend | NestJS | CLI 11.0.16 |
| IA Engine | Vertex AI **Gemini 2.5 Flash** | `gemini-2.5-flash` |
| Auth | Firebase Auth | vía CLI 15.5.1 |
| Base de datos | Firestore | — |
| Despliegue | Cloud Run | — |
| Runtime | Node.js | 22.12.0 |

---

## Prerrequisito: Instalar gcloud CLI

> gcloud NO está instalado en el sistema. Es el primer paso obligatorio.

```bash
# Descargar e instalar desde:
# https://cloud.google.com/sdk/docs/install-sdk#windows
# (Usar el instalador .exe para Windows)

# Tras la instalación, en nueva terminal bash, verificar:
gcloud --version

# Autenticarse:
gcloud auth login

# Configurar el proyecto:
gcloud config set project websites-technology
gcloud config get-value project
# Esperado: websites-technology
```

---

## PASO 1: Verificación y Configuración de GCP

```bash
# Verificar proyecto activo y cuenta
gcloud config get-value project
gcloud auth list

# Ver APIs ya habilitadas
gcloud services list --enabled --project=websites-technology \
  --filter="name:(storage OR aiplatform OR run OR firestore OR firebase OR iam)"
```

---

## PASO 2: Habilitar APIs necesarias

```bash
gcloud services enable aiplatform.googleapis.com \
  run.googleapis.com \
  firestore.googleapis.com \
  firebase.googleapis.com \
  iam.googleapis.com \
  --project=websites-technology

# Verificar resultado (todas deben aparecer como ENABLED):
gcloud services list --enabled --project=websites-technology \
  --filter="name:(aiplatform OR run OR firestore OR firebase OR iam OR storage)"
```

---

## PASO 3: Crear Service Account y Credenciales

```bash
# Crear SA
gcloud iam service-accounts create gemini-agent-sa \
  --display-name="Gemini Agent Service Account" \
  --description="SA para el backend NestJS del Gemini Live Agent" \
  --project=websites-technology

# Asignar roles
gcloud projects add-iam-policy-binding websites-technology \
  --member="serviceAccount:gemini-agent-sa@websites-technology.iam.gserviceaccount.com" \
  --role="roles/aiplatform.user"

gcloud projects add-iam-policy-binding websites-technology \
  --member="serviceAccount:gemini-agent-sa@websites-technology.iam.gserviceaccount.com" \
  --role="roles/datastore.user"

gcloud projects add-iam-policy-binding websites-technology \
  --member="serviceAccount:gemini-agent-sa@websites-technology.iam.gserviceaccount.com" \
  --role="roles/logging.logWriter"

# Verificar roles
gcloud projects get-iam-policy websites-technology \
  --flatten="bindings[].members" \
  --format="table(bindings.role)" \
  --filter="bindings.members:gemini-agent-sa@websites-technology.iam.gserviceaccount.com"
```

---

## PASO 4: Crear Estructura de Carpetas del Monorepo

```bash
cd "c:/Code/08 - hiBOB"

# Estructura del backend NestJS
mkdir -p backend/credentials
mkdir -p backend/src/modules/ai
mkdir -p backend/src/modules/conversation
mkdir -p backend/src/modules/health
mkdir -p backend/src/common/filters
mkdir -p backend/src/common/interceptors
mkdir -p backend/src/common/pipes

# Estructura del mobile Flutter
mkdir -p mobile/lib/core/providers
mkdir -p mobile/lib/core/services
mkdir -p mobile/lib/core/models
mkdir -p mobile/lib/features/chat/screens
mkdir -p mobile/lib/features/chat/widgets
mkdir -p mobile/lib/features/camera/screens
mkdir -p mobile/lib/features/camera/widgets
```

**Estructura resultante:**
```
c:/Code/08 - hiBOB/
├── backend/
│   ├── credentials/        ← key JSON del SA (en .gitignore)
│   └── src/
│       ├── modules/ai/
│       ├── modules/conversation/
│       ├── modules/health/
│       └── common/filters|interceptors|pipes/
├── mobile/
│   └── lib/
│       ├── core/providers|services|models/
│       └── features/chat|camera/
├── PROJECT_ROADMAP.md
├── FASE_0_PLAN.md          ← este archivo
├── .gitignore
└── README.md
```

---

## PASO 5: Descargar Key JSON del Service Account

```bash
cd "c:/Code/08 - hiBOB"

# Descargar key JSON (NUNCA commitear)
gcloud iam service-accounts keys create backend/credentials/gemini-agent-sa-key.json \
  --iam-account=gemini-agent-sa@websites-technology.iam.gserviceaccount.com \
  --project=websites-technology

# Verificar (sin mostrar contenido)
ls -la backend/credentials/

# Configurar ADC para desarrollo local
gcloud auth application-default login
```

---

## PASO 6: Crear .gitignore y README.md en raíz

**`.gitignore`** (crítico - protege credenciales):
```gitignore
# SECRETS - NUNCA COMMITEAR
backend/credentials/
**/*-sa-key.json
.env
.env.local
.env.production
**/.env

# NestJS / Node
backend/node_modules/
backend/dist/
backend/coverage/

# Flutter / Dart
mobile/.dart_tool/
mobile/build/
mobile/.flutter-plugins
mobile/.flutter-plugins-dependencies
mobile/android/.gradle/
mobile/android/local.properties
mobile/android/key.properties
mobile/ios/.symlinks/
mobile/ios/Pods/
mobile/ios/Flutter/flutter_export_environment.sh

# IDEs y OS
.idea/
.vscode/settings.json
*.swp
.DS_Store
Thumbs.db
```

**`README.md`** (raíz del proyecto):
```markdown
# Gemini Live Agent Challenge - Mobile Edition

Agente de IA multimodal con visión y voz en tiempo real.

- **Mobile**: Flutter 3.24.4
- **Backend**: NestJS + Cloud Run
- **IA**: Vertex AI Gemini 2.5 Flash
- **Auth/DB**: Firebase Auth + Firestore
- **GCP Project**: `websites-technology`

## Arranque rápido

Ver `backend/README.md` y `mobile/README.md` para instrucciones específicas.
```

---

## PASO 7: Inicializar Firebase

```bash
cd "c:/Code/08 - hiBOB"

# Autenticarse en Firebase CLI
firebase login

# Verificar que websites-technology aparece
firebase projects:list

# Inicializar Firestore en el proyecto
firebase init firestore --project=websites-technology
# Respuestas: firestore.rules (default), firestore.indexes.json (default)

# Registrar app Android
firebase apps:create android \
  --project=websites-technology \
  --package-name=com.hibob.geminiagent \
  --display-name="Gemini Agent Android"

# Registrar app iOS
firebase apps:create ios \
  --project=websites-technology \
  --bundle-id=com.hibob.geminiagent \
  --display-name="Gemini Agent iOS"

# Descargar configs (sustituir <APP_ID_X> por el ID generado arriba)
firebase apps:sdkconfig android <APP_ID_ANDROID> \
  --project=websites-technology > mobile/android/app/google-services.json

firebase apps:sdkconfig ios <APP_ID_IOS> \
  --project=websites-technology > mobile/ios/Runner/GoogleService-Info.plist
```

---

## PASO 8: Crear Backend NestJS

```bash
cd "c:/Code/08 - hiBOB"

# Crear proyecto (NestJS CLI ya instalado v11.0.16)
nest new backend --package-manager npm --language typescript --skip-git

cd backend

# Instalar dependencias de producción
npm install \
  @google-cloud/vertexai \
  firebase-admin \
  @nestjs/config \
  class-validator \
  class-transformer

# Verificar que levanta
npm run start:dev
# Esperado: Application is running on: http://localhost:3000
# Ctrl+C para detener
```

**Archivo `backend/.env.example`** a crear tras `nest new`:
```bash
# Google Cloud Platform
GCP_PROJECT_ID=websites-technology
GCP_LOCATION=us-central1

# Vertex AI / Gemini
# NOTA: Gemini 2.0 Flash se retira el 01/06/2026 - usar 2.5 Flash
GEMINI_MODEL=gemini-2.5-flash
GEMINI_MAX_OUTPUT_TOKENS=8192
GEMINI_TEMPERATURE=1.0

# Credenciales (desarrollo local con key JSON)
GOOGLE_APPLICATION_CREDENTIALS=./credentials/gemini-agent-sa-key.json

# Firebase
FIREBASE_PROJECT_ID=websites-technology

# Server
PORT=3000
NODE_ENV=development
```

**Módulos a crear en `backend/src/`:**
```
src/
├── app.module.ts        ← ConfigModule.forRoot({ isGlobal: true })
├── main.ts              ← CORS habilitado, ValidationPipe global, PORT desde .env
├── modules/
│   ├── ai/              ← AiService wrappea @google-cloud/vertexai con gemini-2.5-flash
│   ├── conversation/    ← ConversationService interactúa con Firestore
│   └── health/          ← GET /health → { status: 'ok' }
└── common/
    ├── filters/         ← http-exception.filter.ts
    ├── interceptors/    ← logging.interceptor.ts
    └── pipes/           ← validation.pipe.ts
```

---

## PASO 9: Crear Mobile Flutter

```bash
cd "c:/Code/08 - hiBOB"

# Crear proyecto Flutter (CLI ya instalado v3.24.4)
flutter create mobile \
  --org com.hibob \
  --project-name gemini_agent \
  --platforms android,ios \
  --template app

cd mobile

# Agregar dependencias
flutter pub add camera
flutter pub add record
flutter pub add http
flutter pub add firebase_core
flutter pub add firebase_auth
flutter pub add flutter_riverpod
flutter pub add riverpod_annotation

# Dev dependencies
flutter pub add --dev build_runner
flutter pub add --dev riverpod_generator
flutter pub add --dev json_serializable

# Verificar
flutter pub get
flutter analyze
```

**Estructura `mobile/lib/`:**
```
lib/
├── main.dart                          ← Firebase.initializeApp() + ProviderScope
├── core/
│   ├── providers/
│   │   ├── firebase_providers.dart
│   │   └── api_providers.dart
│   ├── services/
│   │   ├── api_service.dart           ← Cliente HTTP al backend NestJS
│   │   └── firebase_service.dart
│   └── models/
│       ├── message.dart
│       └── agent_response.dart
└── features/
    ├── chat/screens/chat_screen.dart
    ├── chat/widgets/message_bubble.dart
    ├── chat/widgets/input_bar.dart
    ├── camera/screens/camera_screen.dart
    └── camera/widgets/camera_preview_widget.dart
```

---

## PASO 10: Verificación Final (Definition of Done)

```bash
# 1. GCP: SA existe con roles correctos
gcloud iam service-accounts describe \
  gemini-agent-sa@websites-technology.iam.gserviceaccount.com

# 2. Backend: levanta sin errores
cd "c:/Code/08 - hiBOB/backend"
cp .env.example .env   # editar con valores reales
npm run start:dev
# En otra terminal:
curl http://localhost:3000
# Esperado: respuesta HTTP 200

# 3. Flutter: compila sin errores
cd "c:/Code/08 - hiBOB/mobile"
flutter analyze    # Esperado: No issues found!
flutter build apk --debug   # Esperado: Built app-debug.apk

# 4. Firebase: archivos de config existen
ls mobile/android/app/google-services.json
ls mobile/ios/Runner/GoogleService-Info.plist
```

---

## Orden de Ejecución (Checklist)

```
[x] Prerrequisito: Instalar gcloud CLI + gcloud auth login          ← COMPLETADO (manual)
[x] PASO 1: Verificar proyecto GCP websites-technology activo       ← COMPLETADO
[ ] PASO 2: Habilitar 5 APIs (aiplatform, run, firestore, firebase, iam) ← PENDIENTE (manual)
[x] PASO 3: Crear SA gemini-agent-sa + asignar 3 roles              ← COMPLETADO
[x] PASO 4: Crear estructura de carpetas del monorepo               ← COMPLETADO
[x] PASO 5: Descargar key JSON a backend/credentials/ + ADC         ← COMPLETADO
[x] PASO 6: Crear .gitignore y README.md en raíz                    ← COMPLETADO
[x] PASO 7: firebase init Firestore + registrar apps Android e iOS  ← PARCIAL (init hecho, falta registrar apps)
[x] PASO 8: nest new backend + módulos AI/Conversation/Health + common ← COMPLETADO
[x] PASO 9: flutter create mobile + dependencias + pantallas + providers ← COMPLETADO
[x] PASO 10: DoD - backend en :3000 ✓ + Flutter analyze sin errores ✓ ← COMPLETADO
[x] EXTRA: Commit inicial + push a github.com/josecarlosalar/hiBOB  ← COMPLETADO
```

---

## Notas de Seguridad Críticas

1. `backend/credentials/gemini-agent-sa-key.json` → **NUNCA** commitear (cubierto por `.gitignore`)
2. `.env` → **NUNCA** commitear (solo commitear `.env.example`)
3. En Cloud Run (Fase 4): usar Workload Identity Federation, no la key JSON
4. `google-services.json` y `GoogleService-Info.plist` no contienen secretos privados pero en repositorio público es recomendable no commitearlos

## Archivos Críticos a Crear/Modificar

| Archivo | Acción | Prioridad |
|---|---|---|
| `c:/Code/08 - hiBOB/.gitignore` | Crear primero (protege credenciales) | CRÍTICA |
| `c:/Code/08 - hiBOB/backend/.env.example` | Crear con `GEMINI_MODEL=gemini-2.5-flash` | ALTA |
| `c:/Code/08 - hiBOB/backend/src/main.ts` | Modificar (CORS + ValidationPipe + PORT) | ALTA |
| `c:/Code/08 - hiBOB/backend/src/app.module.ts` | Modificar (ConfigModule.forRoot global) | ALTA |
| `c:/Code/08 - hiBOB/mobile/lib/main.dart` | Modificar (Firebase init + ProviderScope) | ALTA |
