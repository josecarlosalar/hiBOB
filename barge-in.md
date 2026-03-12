# Implementación de Barge-In y VAD Manual en hiBOB

Este documento detalla la solución técnica implementada para resolver los problemas de eco e interrupciones prematuras en la comunicación por voz con Gemini Live. Se ha pasado de un modelo de detección automática (VAD en la nube) a un modelo de **VAD Manual con Control Dinámico de Decibelios**.

## 1. El Problema
El sistema anterior utilizaba el VAD (Voice Activity Detection) automático de Gemini. Debido al volumen del altavoz del dispositivo, el micrófono captaba el eco de la propia voz de la IA, lo que provocaba que el modelo asumiera que el usuario estaba interrumpiendo, cortando su propia respuesta a los 2 segundos de empezar a hablar.

## 2. La Solución: VAD Manual Híbrido
Se ha implementado una arquitectura donde el cliente hiBOB (Flutter) toma el control total de cuándo se considera que el usuario ha empezado a hablar, utilizando señales explícitas y umbrales de energía (RMS/dB) dinámicos.

### A. Configuración del Backend (NestJS)
En `AiService.ts`, se ha modificado la configuración de conexión con Gemini Live:
- **Desactivación del VAD de Google**: Se ha configurado `automaticActivityDetection: { disabled: true }`. Esto evita que Gemini intente detectar el silencio o el inicio de habla por su cuenta.
- **Señalización Manual**: Se ha implementado el método `sendActivityStart()` en la clase `GeminiLiveSession` que utiliza el SDK `@google/genai` para enviar un `RealtimeInput` de tipo `activityStart`.
- **Gateway de Socket.IO**: `LiveGateway.ts` ahora escucha el evento `activity_start` desde el móvil y lo propaga instantáneamente a la sesión de Gemini.

### B. Lógica de Control en el Frontend (Flutter)
La inteligencia de la interrupción reside ahora en `CameraScreen.dart`:

1. **Umbral Dinámico (Anti-Eco)**:
   - **Estado Reposo**: El umbral de detección es de **-68 dB** (sensibilidad alta para detectar susurros).
   - **Agente Hablando**: En cuanto el agente empieza a emitir audio, el umbral de interrupción se eleva dinámicamente a **-15 dB** (equivalente a ~75-80 dB de presión sonora). Este nivel es lo suficientemente alto para ignorar el eco del altavoz pero permite que una voz humana cercana lo supere.

2. **Debounce de Interrupción (300ms)**:
   - No basta con un pico de volumen. El sistema requiere que el audio del usuario supere el umbral dinámico de forma sostenida durante **300ms**.
   - Esto evita que ruidos transitorios, golpes en el chasis del móvil o ruidos de fondo aleatorios corten la explicación del asistente.

3. **Señalización Única**:
   - Se utiliza un flag `_manualActivitySignaled` para asegurar que solo se envía una señal de `activity_start` por cada turno de habla, evitando saturar el socket.

## 3. Flujo de una Interrupción Correcta
1. El agente está hablando.
2. El usuario dice algo fuerte: *"¡Espera, hiBOB!"*.
3. El micrófono capta el audio. La lógica en `_handleAmplitudeSample` detecta que supera los **-15 dB**.
4. Tras **300ms** de consistencia, el móvil envía `activity_start` al servidor.
5. El servidor envía `activityStart` a Gemini Live API.
6. Gemini detecta la señal manual, detiene la generación de audio actual y envía un evento `interruption` de vuelta.
7. El móvil recibe el evento `interruption`, detiene la reproducción local del buffer PCM y limpia el estado visual.

## 4. Beneficios Técnicos
- **Inmunidad al Eco**: El asistente ya no se interrumpe a sí mismo por el sonido de su propia voz.
- **Latencia Reducida**: Al no depender de que un algoritmo en la nube procese el audio para decidir si es voz, la interrupción es casi instantánea una vez superado el debounce local.
- **Robustez**: El sistema es mucho más estable en entornos con ruido moderado.
