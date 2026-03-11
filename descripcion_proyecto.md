# Descripción del Proyecto - hiBOB 📄

## Resumen de Características y Funcionalidades

**hiBOB** es un asistente de seguridad multimodal integrado en un dispositivo móvil que utiliza la **API Live de Gemini** para ofrecer una experiencia interactiva sin interrupciones.

El sistema permite a los usuarios:

* **Analizar amenazas en tiempo real:** Detectar phishing en URLs mediante escaneos de VirusTotal y búsquedas en Brave Search simplemente apuntando la cámara a un código QR o enviando una captura de pantalla.
* **Verificar seguridad personal:** Consultar brechas de contraseñas de forma segura con la API de "Have I Been Pwned" usando k-Anonymity para proteger la privacidad.
* **Gestionar el dispositivo por voz:** Controlar funciones físicas como linterna, vibración y cambio de cámara mediante órdenes naturales que el agente ejecuta de forma autónoma.
* **Asistencia Visual Proactiva:** El agente puede "pensar" y sugerir acciones al ver el contenido de la cámara, como proponer el análisis de un sitio web que detecta visualmente.

## Tecnologías Utilizadas

* **Google GenAI SDK & Vertex AI:** Núcleo de la inteligencia del agente, utilizando modelos multimodales para procesamiento de audio y visión.
* **Google Cloud Run:** Alojamiento del backend (NestJS) para garantizar escalabilidad y baja latencia.
* **Flutter:** Desarrollo de la aplicación móvil con flujos de audio PCM en tiempo real y componentes de hardware nativos.
* **WebSockets (Socket.io):** Comunicación bidireccional de baja latencia para envío de frames de audio y vídeo.
* **APIs Externas:** VirusTotal (Seguridad), Brave Search (Contexto web), Have I Been Pwned (Privacidad).

## Hallazgos y Aprendizajes

1. **Gestión de Interrupciones (Barge-in):** Uno de los mayores desafíos fue lograr que el agente se detuviera de inmediato cuando el usuario hablaba. Implementar una lógica de detección de amplitud dinámica en el cliente, combinada con el evento de interrupción del servidor, fue clave para que la conversación se sintiera natural.
2. **Multimodalidad Real:** Descubrimos que la potencia de Gemini Live reside en su capacidad para procesar audio y vídeo en una sola sesión continua. Esto permite al agente "ver" un problema mientras te explica cómo solucionarlo, eliminando la fricción de los modelos por turnos.
3. **Privacidad vs. Seguridad:** Implementar herramientas de ciberseguridad requiere un equilibrio. Aprendimos que técnicas como k-Anonymity permiten que el agente sea útil sin comprometer la privacidad real del usuario, un factor crítico para la confianza en la IA.
4. **Localización:** La personalización del acento (español de España) y el vocabulario local mejoran drásticamente la tasa de retención del usuario, haciendo que el agente se sienta más como un compañero que como una herramienta remota.

---
**hiBOB: El primer Agente en Vivo que no solo te escucha, sino que te protege.**
