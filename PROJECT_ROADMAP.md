# Roadmap: Gemini Live Agent Challenge (Mobile Edition)

Este documento guía la creación de un agente de IA que utiliza visión en tiempo real (cámara) y voz para asistir al usuario.

## 1. Stack Tecnológico

- **Frontend:** Flutter (Mobile App)
- **Backend:** NestJS (Cloud Run)
- **IA Engine:** Google Vertex AI (Gemini 2.0 Flash)
- **Auth/Distribution:** Firebase (Auth, App Distribution)
- **Base de Datos:** Firestore (Memoria del Agente)

## 2. Fases de Desarrollo

### Fase 0: Inicialización del Proyecto

- [ ] Estructura de carpetas: `/mobile` (Flutter) y `/backend` (NestJS).
- [ ] Configuración básica de Firebase en ambos proyectos.
- [ ] Creación de Service Account en GCP y configuración de credenciales (seguras).
- **DoD:** App Flutter compilando y Backend NestJS corriendo localmente.

### Fase 1: Motor Multimodal (Vertex AI)

- [ ] Implementar `AiService` en NestJS usando `@google-cloud/vertexai`.
- [ ] Crear endpoint `POST /chat` que acepte imágenes (base64 o bytes) y texto.
- [ ] Configurar las instrucciones del sistema (System Instructions) del agente.
- **DoD:** El backend procesa una imagen enviada y retorna una respuesta de Gemini.

### Fase 2: Streaming de Cámara y Voz

- [ ] Flutter: Implementar `camera` controller para capturar frames.
- [ ] Flutter: Implementar `microphone` para captura de audio.
- [ ] Integración: Enviar stream de frames (capturas periódicas) al backend.
- **DoD:** El agente "ve" lo que apunta la cámara y puede responder.

### Fase 3: Agente con Memoria y Herramientas

- [ ] Implementar base de datos en Firestore para el historial de conversaciones.
- [ ] Añadir 'Tools' (Function Calling) al `AiService` para que el agente acceda a información externa.
- [ ] Asegurar que el contexto histórico se envíe a Vertex AI en cada petición.
- **DoD:** El agente recuerda la conversación anterior.

### Fase 4: Despliegue y Distribución (GCP)

- [ ] Dockerizar el backend (NestJS) y desplegar en **Cloud Run**.
- [ ] Preparar build de Flutter (release mode).
- [ ] Subir app a **Firebase App Distribution** para acceso de los jueces.
- **DoD:** App funcionando en un móvil real sin necesidad de tiendas.

### Fase 5: Optimización Final

- [ ] Mejorar UX (estados de carga, feedback visual).
- [ ] Logs y monitoreo mediante Google Cloud Logging.
- **DoD:** Código limpio, sin secretos expuestos, listo para demo.
