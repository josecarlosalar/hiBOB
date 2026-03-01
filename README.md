# Gemini Live Agent Challenge - Mobile Edition

Agente de IA multimodal con visión y voz en tiempo real, construido con:

- **Mobile**: Flutter 3.24.4
- **Backend**: NestJS + Cloud Run
- **IA**: Vertex AI Gemini 2.5 Flash
- **Auth/DB**: Firebase Auth + Firestore
- **GCP Project**: `websites-technology`

## Estructura del Monorepo

```
/
├── mobile/          # Flutter app (iOS + Android)
├── backend/         # NestJS API (desplegable en Cloud Run)
├── PROJECT_ROADMAP.md
└── FASE_0_PLAN.md   # Plan de ejecución detallado de la Fase 0
```

## Arranque rápido

Ver [FASE_0_PLAN.md](./FASE_0_PLAN.md) para las instrucciones completas de configuración de GCP, Firebase, backend y mobile.

### Backend (NestJS)

```bash
cd backend
cp .env.example .env
# Editar .env con tus valores reales
npm install
npm run start:dev
# Disponible en http://localhost:3000
```

### Mobile (Flutter)

```bash
cd mobile
flutter pub get
flutter run
```

## Arquitectura

```
[Flutter App]
    │ HTTP (imagen base64 + texto)
    ▼
[NestJS Backend - Cloud Run]
    │ @google-cloud/vertexai
    ▼
[Vertex AI - Gemini 2.5 Flash]
    │
    ▼
[Firestore - Historial de conversación]
```

## Requisitos

- Google Cloud SDK (`gcloud`)
- Node.js 22+
- Flutter 3.24+
- Firebase CLI
