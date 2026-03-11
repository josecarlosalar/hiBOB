# hiBOB - Tu Guardián Multimodal en Tiempo Real 🛡️🗣️👁️

**hiBOB** es un Agente de IA de última generación diseñado para el **Gemini Live Agent Challenge**. Va más allá de un simple chatbot: es un asistente de ciberseguridad y hardware en tiempo real que escucha, ve y actúa para protegerte.

## 🚀 Categoría: Agentes en vivo (Live Agents)

hiBOB utiliza la **API Live de Gemini (Vertex AI)** para ofrecer una interacción humana natural, gestionando interrupciones de forma fluida y procesando vídeo/audio de manera síncrona para resolver problemas complejos de seguridad y asistencia en el dispositivo.

### ✨ Funcionalidades Clave

* **Conversación Fluida (Live Audio):** Interacción por voz con bajísima latencia, optimizada con acento de España y gestión avanzada de interrupciones (*barge-in*).
* **Visión Inteligente (Live Vision):** El agente puede "ver" a través de tu cámara o capturas de pantalla para analizar códigos QR maliciosos, estafas en webs o identificar objetos.
* **Arsenal de Ciberseguridad:** Integración nativa con:
  * **VirusTotal:** Análisis en tiempo real de URLs, IPs, Dominios y archivos sospechosos.
  * **Have I Been Pwned (HIBP):** Verificación segura de contraseñas mediante k-Anonymity (tu contraseña nunca sale del dispositivo).
  * **Brave Search:** Búsqueda activa de reportes de phishing y amenazas nuevas.
* **Control de Hardware (Device Actions):** hiBOB puede encender la linterna, hacer vibrar el teléfono, capturar la pantalla o abrir tu galería bajo demanda.
* **Memoria Visual:** Capacidad para "recordar" objetos o lugares que ha visto antes.

## 🏗️ Arquitectura Técnica

* **Backend:** NestJS (Node.js) alojado en **Google Cloud Run**.
* **IA:** Gemini 2.5 Flash (Vertex AI) vía **Google GenAI SDK**.
* **Mobile:** Flutter (Android/iOS) con comunicación **Socket.IO** para flujos multimodales.
* **Servicios Cloud:** Vertex AI, Cloud Run, Firebase Auth.

## 🛠️ Instrucciones de Desarrollo (Reproducibilidad)

### Requisitos Previos

* Flutter SDK (3.24+)
* Node.js (v20+)
* Cuenta de Google Cloud con Vertex AI habilitado.
* API Keys: `GEMINI_API_KEY`, `VIRUSTOTAL_API_KEY`, `BRAVE_SEARCH_API_KEY`.

### Configuración del Backend

1. Navega a `backend/`.
2. Copia `.env.example` a `.env` y rellena las credenciales.
3. Instala dependencias: `npm install`.
4. Ejecuta en desarrollo: `npm run start:dev`.

### Configuración del Mobile (Flutter)

1. Navega a `mobile/`.
2. Asegúrate de tener configurado Firebase (`google-services.json`).
3. Instala dependencias: `flutter pub get`.
4. Ejecuta en tu dispositivo: `flutter run`.

## 🖥️ Prueba de Implementación en Google Cloud

El backend de este proyecto está desplegado en **Google Cloud Run**. Puedes verificar la integración consultando los logs de Vertex AI en la consola de GCP o revisando el archivo `backend/src/modules/ai/ai.service.ts` que utiliza el SDK oficial de Google Cloud.

---
*Desarrollado con ❤️ para el Gemini Live Agent Challenge 2026.*
