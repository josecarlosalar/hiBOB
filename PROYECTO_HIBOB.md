# hiBOB — Documentación del Proyecto

## El Problema

**Cada día, millones de personas caen víctimas de ciberataques que podrían haberse evitado.**

El usuario medio no tiene las herramientas ni los conocimientos para detectar:

- Un enlace de phishing en un SMS que simula ser su banco
- Una APK maliciosa descargada fuera de la tienda oficial
- Un código QR en un cartel público que redirige a una web fraudulenta
- Una contraseña que lleva años comprometida en filtraciones de datos
- Una IP desconocida que está sondeando su red

Las soluciones actuales son herramientas técnicas aisladas (VirusTotal, HIBP, etc.) que requieren conocimientos previos, cambian de contexto constantemente y no ofrecen ninguna guía de actuación. El usuario no sabe qué hacer con los datos que le devuelven.

---

## La Solución: hiBOB

**hiBOB es un agente de ciberseguridad multimodal que actúa como guardián digital personal**, accesible por voz desde el móvil, capaz de ver lo que el usuario ve (cámara, pantalla, galería) y de actuar en tiempo real sobre las amenazas detectadas.

No es una app de análisis. Es un compañero inteligente que:

- Conoce al usuario por su nombre desde que inicia sesión
- Actúa inmediatamente ante una amenaza, sin esperar a que el usuario sepa qué herramienta usar
- Explica los resultados en lenguaje natural y da instrucciones de acción concretas
- Presenta los datos técnicos con gráficos animados claros en pantalla

---

## Propuesta de Valor

| Para el usuario | Para la seguridad |
|---|---|
| Sin fricción: solo hablar | Análisis técnico real (VirusTotal, HIBP) |
| Sin conocimientos previos | 70+ motores antivirus en cada análisis |
| Respuesta inmediata | k-Anonymity: las contraseñas nunca salen del dispositivo |
| Multimodal: voz + imagen + pantalla | Detección de phishing en URLs, IPs, dominios y QR |
| Personalizado por usuario | Generación de contraseñas de alta entropía |

---

## Funcionalidades Principales

### Análisis de Amenazas con VirusTotal

| Herramienta | Qué analiza | Cómo se activa |
|---|---|---|
| `analyze_security_url` | URL completa | El usuario menciona o muestra un enlace |
| `analyze_domain` | Dominio (sin protocolo) | El usuario menciona un dominio |
| `analyze_ip` | Dirección IP | El usuario menciona una IP |
| `analyze_file_hash` | Hash SHA256/MD5/SHA1 | El usuario proporciona el hash |
| `scan_file` | Archivo completo (APK, PDF...) | El usuario lo selecciona desde galería |
| `scan_qr_code` | Código QR en tiempo real | El usuario apunta la cámara a un QR |

### Seguridad de Contraseñas (Have I Been Pwned)

- **`check_password_breach`**: Verifica si una contraseña ha aparecido en filtraciones de datos usando el protocolo k-Anonymity. Solo se envía el prefijo del hash SHA1 (5 caracteres), la contraseña nunca sale del dispositivo.
- **`generate_password`**: Genera contraseñas seguras con entropía calculada, toggle de visibilidad y botón de copia al portapapeles.

### Captura Multimodal

- **Pantalla en tiempo real**: El agente puede pedir una captura de la pantalla del usuario para analizar cualquier SMS, email, notificación o web sospechosa.
- **Cámara frontal/trasera**: Analiza visualmente lo que el usuario tiene delante.
- **Galería**: El usuario puede seleccionar capturas guardadas para análisis posterior.
- **QR Scanner**: Captura cámara → extrae URL con Gemini Vision → analiza con VirusTotal automáticamente.

### Modo Copiloto

El agente guía al usuario paso a paso por su propio móvil: ajustes de privacidad, revisión de permisos de apps, configuración de seguridad, sin que el usuario necesite saber dónde está cada opción.

### Control del Dispositivo

El agente puede controlar hardware del teléfono: linterna, vibración (feedback háptico), cambio entre cámara frontal/trasera, todo en respuesta a las necesidades de la situación.

---

## Arquitectura del Sistema

```
┌─────────────────────────────────────────────────────────────────────┐
│                        USUARIO                                       │
│                    (Habla / Muestra pantalla)                        │
└───────────────────────────┬─────────────────────────────────────────┘
                            │  Voz (PCM 16kHz) + Imágenes (JPEG)
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    FLUTTER APP (Android/iOS)                         │
│                                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│  │ AudioService │  │ CameraScreen │  │   LiveSessionService     │  │
│  │ (PCM Record) │  │ (Overlays UI)│  │   (Socket.IO Client)     │  │
│  └──────────────┘  └──────────────┘  └──────────┬───────────────┘  │
│                                                  │                  │
│  ┌──────────────────────────────────────────┐    │  Firebase Auth   │
│  │ Firebase Auth (Google Sign-In / Email)   │────┤  JWT idToken     │
│  └──────────────────────────────────────────┘    │                  │
└──────────────────────────────────────────────────┼──────────────────┘
                                                   │ WebSocket TLS
                                                   │ Bearer {idToken}
                                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│              NESTJS BACKEND — Google Cloud Run                       │
│              (europe-west1 / us-central1)                            │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    LiveGateway (Socket.IO)                   │    │
│  │                                                              │    │
│  │  1. Verifica Firebase JWT                                    │    │
│  │  2. Obtiene displayName del usuario (Firebase Admin)         │    │
│  │  3. Crea GeminiLiveSession personalizada                     │    │
│  │  4. Enruta tool_calls → servicios externos                   │    │
│  │  5. Emite UI rica (display_content) al cliente               │    │
│  └───────────────────────────┬─────────────────────────────────┘    │
│                              │                                       │
│         ┌────────────────────┼──────────────────────┐               │
│         ▼                    ▼                       ▼               │
│  ┌─────────────┐    ┌─────────────────┐    ┌──────────────────┐    │
│  │  AiService  │    │  ToolsModule    │    │  ConversationMod │    │
│  │             │    │                 │    │                  │    │
│  │ GeminiLive  │    │ VirusTotal      │    │ Firestore (CRUD) │    │
│  │ Session     │    │ Service         │    │ Historial chats  │    │
│  │             │    │                 │    └──────────────────┘    │
│  │ 19 tools    │    │ HibpService     │                             │
│  │ declaradas  │    │                 │                             │
│  └──────┬──────┘    │ BraveSearch     │                             │
│         │           │ Service         │                             │
│         │           │                 │                             │
│         │           │ LocationService │                             │
│         │           └────────┬────────┘                             │
│         │                    │                                       │
│  ┌──────▼──────────────────────────────────────────────────────┐    │
│  │              Firebase Auth Guard (JWT global)               │    │
│  │              ThrottlerGuard (60 req/min)                    │    │
│  └─────────────────────────────────────────────────────────────┘    │
└──────────────────────────┬──────────────────┬────────────────────────┘
                           │                  │
              ┌────────────▼──┐    ┌──────────▼────────────┐
              │ Gemini Live   │    │   APIs Externas       │
              │ API (Vertex)  │    │                       │
              │               │    │  VirusTotal API v3    │
              │ gemini-live-  │    │  Have I Been Pwned    │
              │ 2.5-flash-    │    │  Brave Search API     │
              │ preview       │    │                       │
              │               │    │  Firebase Auth Admin  │
              │ Multimodal:   │    │  Firestore (NoSQL)    │
              │ Audio+Video+  │    │                       │
              │ Text+Tools    │    └───────────────────────┘
              └───────────────┘
```

### Flujo de una Interacción Típica

```
Usuario: "hiBOB, me ha llegado este mensaje, ¿es seguro?"

    1. Voz (PCM) → Backend → Gemini Live (transcripción + comprensión)
    2. Gemini → tool_call: capture_device_screen
    3. Backend → frame_request → Flutter
    4. Flutter → captura pantalla → frame → Backend
    5. Gemini analiza imagen → detecta URL → tool_call: analyze_security_url
    6. Backend → VirusTotal API v3 → resultado (70+ motores)
    7. Backend → display_content (vt_report) → Flutter (overlay animado)
    8. Gemini → respuesta de voz: "José Carlos, esta URL está marcada como phishing
       por 23 motores. No la abras y elimina el mensaje."
    9. Backend → trigger_haptic_feedback (error) → vibración de alerta

Tiempo total: ~4 segundos
```

---

## Stack Tecnológico

### Backend

| Tecnología | Versión | Rol |
|---|---|---|
| **NestJS** | 11.x | Framework principal, WebSocket Gateway |
| **Socket.IO** | 4.8.3 | Comunicación bidireccional en tiempo real |
| **@google/genai** | 1.0.0 | SDK oficial de Gemini (Vertex AI) |
| **firebase-admin** | 13.7.0 | Autenticación y Firestore |
| **axios** | 1.13.x | Llamadas a APIs externas (VT, HIBP) |
| **TypeScript** | 5.7.x | Lenguaje |
| **Google Cloud Run** | — | Hosting serverless (europe-west1) |

### Mobile

| Tecnología | Versión | Rol |
|---|---|---|
| **Flutter** | 3.x (Dart 3.5) | Framework UI multiplataforma |
| **socket_io_client** | 3.1.4 | WebSocket al backend |
| **firebase_auth** | 6.1.4 | Autenticación de usuarios |
| **flutter_riverpod** | 2.6.1 | State management |
| **camera** | 0.11.x | Acceso a cámara frontal/trasera |
| **record** | 6.1.2 | Grabación de audio PCM |
| **flutter_pcm_sound** | 1.1.0 | Reproducción de audio PCM |
| **geolocator** | 13.x | GPS |
| **torch_light** | 1.0.1 | Control de linterna |
| **vibration** | 2.0.1 | Feedback háptico |
| **image_picker** | 1.1.2 | Selección de imágenes/archivos |
| **flutter_background_service** | 5.1.0 | Servicio de fondo (micrófono) |

### IA y Modelos

| Modelo | Proveedor | Uso |
|---|---|---|
| **gemini-live-2.5-flash-preview** | Google Vertex AI | Sesiones live (voz + visión + herramientas) |
| **gemini-2.5-flash** | Google Vertex AI | Procesamiento de contenido (REST) |

### Fuentes de Datos Externas

| Servicio | Proveedor | Datos que aporta |
|---|---|---|
| **VirusTotal API v3** | Google / VirusTotal | 70+ motores antivirus, historial de URLs, reputación de IPs y dominios, análisis de archivos |
| **Have I Been Pwned** | Troy Hunt | Base de datos de 12.000M+ contraseñas comprometidas, consulta por k-Anonymity |
| **Brave Search API** | Brave Software | Búsqueda web sin rastreo, resultados en tiempo real |
| **Firebase Auth** | Google | Autenticación OAuth2/Email, perfil de usuario (displayName) |
| **Firestore** | Google | Almacenamiento NoSQL de historial de conversaciones |

---

## Modelo de Seguridad

```
┌─────────────────────────────────────────────┐
│              CAPAS DE SEGURIDAD              │
│                                             │
│  1. Firebase JWT (AuthN)                    │
│     └── Todo WebSocket requiere idToken     │
│                                             │
│  2. ThrottlerGuard (60 req/min)             │
│     └── Protección contra abuso de API     │
│                                             │
│  3. k-Anonymity (HIBP)                      │
│     └── Contraseña → SHA1 → solo 5 chars   │
│         se envían al servidor externo       │
│                                             │
│  4. Credenciales en servidor                │
│     └── API keys nunca llegan al cliente   │
│                                             │
│  5. TLS/HTTPS                               │
│     └── Todo tráfico cifrado en tránsito   │
└─────────────────────────────────────────────┘
```

---

## Casos de Uso Reales

### 1. SMS de Phishing Bancario
>
> El usuario recibe: *"Su cuenta BBVA ha sido bloqueada. Acceda aquí: bbva-secure-login.ru"*

**hiBOB**: Capta el SMS por voz o pantalla → extrae la URL → VirusTotal → overlay rojo animado con "23/85 motores detectan phishing" → voz: *"No lo abras, es una estafa. Bloquea el número y borra el mensaje."*

### 2. QR Code Sospechoso
>
> El usuario ve un QR en un cartel en la calle y no sabe si es seguro.

**hiBOB**: *"Enséñame el QR"* → captura cámara → Gemini extrae URL → VirusTotal → respuesta en 3 segundos.

### 3. APK Descargada Fuera de Play Store
>
> El usuario descargó una app de un enlace y quiere saber si es segura antes de instalarla.

**hiBOB**: Solicita el archivo desde galería → lo sube a VirusTotal → overlay con resultado de 70+ motores antivirus.

### 4. Contraseña Reutilizada
>
> El usuario quiere saber si su contraseña de siempre ha sido filtrada.

**hiBOB**: Verifica sin transmitir la contraseña real (k-Anonymity) → overlay con contador animado de exposiciones → genera nueva contraseña segura con barra de entropía.

### 5. IP de una Llamada Desconocida
>
> El usuario recibió una llamada de un número extranjero y quiere saber quién es.

**hiBOB**: Analiza la IP con VirusTotal → overlay con país, proveedor, ASN y reputación.

---

## Métricas del Proyecto

| Métrica | Valor |
|---|---|
| Herramientas del agente | 19 tool declarations |
| APIs externas integradas | 4 (VirusTotal, HIBP, Brave, Firebase) |
| Tipos de análisis de seguridad | 7 (URL, IP, dominio, hash, archivo, QR, contraseña) |
| Latencia media de análisis | ~3-5 segundos (end-to-end) |
| Motores antivirus por análisis | 70+ (VirusTotal) |
| Contraseñas en HIBP | 12.000M+ (base de datos k-Anonymity) |
| Plataformas soportadas | Android (primario), iOS (secundario) |
