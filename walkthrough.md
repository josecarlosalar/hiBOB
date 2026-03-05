# Walkthrough — hiBOB: El Asistente Multimodal Definitivo

¡Bienvenido a hiBOB! Esta guía detalla las capacidades y el estado actual de la aplicación diseñada para el **Gemini Live Agent Challenge**.

## 1. Experiencia Heroica (UI/UX)

### Aura de Gemini
El fondo de la aplicación es un gradiente radial animado que pulsa y cambia de color según lo que hiBOB esté haciendo:
- **Idle (Púrpura suave):** El asistente está listo y esperando.
- **Escuchando (Verde/Cyan):** Detectando actividad de voz.
- **Grabando (Rojo):** Capturando el audio para ser procesado.
- **Procesando (Púrpura Intenso):** Comunicándose con la Gemini Live API.
- **Hablando (Cian):** Reproduciendo la respuesta en tiempo real.

### Glassmorphism Premium
Paneles de control con efecto de cristal esmerilado (`BackdropFilter`) que permiten ver el aura y la cámara de fondo, ofreciendo una estética moderna y limpia.

## 2. Accesibilidad Inclusiva (A11y)

- **Feedback Háptico:** Vibraciones sutiles sincronizadas con los cambios de estado para que usuarios con discapacidad visual "sientan" la app.
- **Semántica Completa:** Uso intensivo de `Semantics` en Flutter para una navegación guiada por TalkBack/VoiceOver.
- **Modo Proactivo:** hiBOB describe el entorno automáticamente cada X segundos (configurable) sin que el usuario tenga que preguntar.

## 3. Excelencia Técnica

- **Bidi-streaming:** Latencia ultra-baja mediante el uso de LPCM 16-bit 16kHz y comunicación bidireccional continua con la Gemini Multimodal Live API.
- **Agentic Tools:** hiBOB puede controlar la linterna, ejecutar vibraciones, recordar lugares y ofrecer navegación guiada por visión.
- **Interrupciones (Barge-in):** Puedes interrumpir al asistente en cualquier momento simplemente empezando a hablar.

## 4. Estructura del Proyecto

- `mobile/`: Aplicación Flutter con el motor de audio y cámara.
- `backend/`: Servidor NestJS que actúa como bridge/proxy con Vertex AI.
- `ARCHITECTURE.md`: Detalle técnico profundo de la infraestructura.
- `task.md`: Seguimiento del progreso y tareas pendientes.

---
*hiBOB — Ojos para quien no puede ver.*
