Roadmap:

Gemini Live Agent Challenge (Hackathon Edition)Este plan de acción prioriza el uso del Mandatory Stack: Gemini Model + Google Cloud + Real-time Multimodal UX.📍

Fase 1: Migración a Multimodal Live API

El corazón del reto es ir más allá del texto.

Implementar Bidi-Streaming: En lugar de REST, usa WebSockets para conectar Flutter con NestJS y NestJS con la Gemini Live API.

Formato de Audio Nativo: Configura el envío de audio en LPCM (16kHz, 16-bit) para aprovechar el Native Audio de Gemini, lo que reduce la latencia al mínimo.

Barge-in (Interrupciones): Asegura que la IA se calle cuando el usuario hable. Esto suma puntos directos en la categoría de Multimodal UX.

📍 Fase 2: Agentic Skills (Function Calling) (Día 3-4)Un "Agente" no solo habla, también actúa.

Herramientas de Navegación: Crea funciones que Gemini pueda "invocar".get_current_location(): Para dar contexto de calles.detect_safety_hazards(): Una función que analice el frame actual con más prioridad.[ ] System Instructions: Define una personalidad clara. Para el hackathon, esto cuenta como "Creatividad".

📍 Fase 3: Integración con Google Cloud (Obligatorio)  

Cloud Run & Secret Manager: Despliega tu NestJS en Cloud Run y usa Secret Manager para las API Keys de Gemini. Los jueces revisarán que sigas las buenas prácticas de arquitectura.[ ] Deployment Proof: Asegúrate de tener el link de producción (Cloud Run) listo, ya que es un requisito de entrega.

📍 Fase 4: Entregables de "Grand Prize"

Architecture Diagram: Dibuja el flujo: Flutter (Camera/Mic) -> NestJS (Cloud Run) -> Gemini Live API -> Firestore. (Usa herramientas como Lucidchart o Excalidraw).[ ] Demo Video (< 4 min): Muestra el asistente en una situación real. Tip de oro: Muestra la interrupción fluida y cómo el asistente ayuda a "ver" un objeto difícil. El audio del video debe estar en Inglés (o subtitulado perfectamente) para ser elegible.⚖️ Verificación de Reglas (Compliance Check)

Requisito¿Tu proyecto cumple?Nota para Claude CodeMandatory Stack✅ SíEstás usando Gemini + Cloud Run + Google GenAI SDK.Multimodal UX✅ SíAl usar visión y voz en tiempo real, estás en el top de la categoría.Real-time Interaction✅ SíAl usar WebSockets cumples con la exigencia de "Live Agent".Public Repo⚠️ PendienteRecuerda que el código debe ser público al final.

💡 Pro-Tip para el Hackathon:Añade una "Side Quest" técnica: Usa Context Caching de Gemini si el usuario está en un lugar fijo (como su casa) para que la IA recuerde la disposición de los muebles sin gastar tantos tokens y con mayor rapidez.
