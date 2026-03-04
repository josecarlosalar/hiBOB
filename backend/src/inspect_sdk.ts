import { GoogleGenAI } from '@google/genai';
import * as dotenv from 'dotenv';
dotenv.config();

async function inspect() {
    console.log('--- SDK Inspection ---');
    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey) {
        console.error('Error: GEMINI_API_KEY no encontrada en .env');
        return;
    }

    const genAI = new GoogleGenAI({ apiKey });
    console.log('SDK initialized with API Key');

    try {
        console.log('Iniciando live.connect...');
        const session = await genAI.live.connect({
            model: 'gemini-2.0-flash-exp',
            config: {
                systemInstruction: { parts: [{ text: 'Di solo "Test Live OK"' }] }
            },
            callbacks: {
                onmessage: () => { }
            }
        });

        console.log('Session result:', Object.keys(session));
        console.log('Session constructor:', session.constructor.name);

        // Intentar enviar un mensaje de texto
        console.log('Enviando mensaje de prueba...');
        (session as any).send({
            clientContent: {
                turns: [{ role: 'user', parts: [{ text: 'Hola, prueba de live' }] }],
                turnComplete: true
            }
        });

        // Escuchar mensajes (asumiendo iterador asíncrono)
        console.log('Esperando respuesta (vía iterador)...');
        const timeoutPromise = new Promise((_, reject) => setTimeout(() => reject(new Error('Timeout de 10s')), 10000));

        const messagePromise = (async () => {
            for await (const msg of (session as any)) {
                console.log('Mensaje recibido:', JSON.stringify(msg, null, 2));
                break; // Solo queremos el primero para el test
            }
        })();

        await Promise.race([messagePromise, timeoutPromise]);
        console.log('Prueba finalizada con éxito');

    } catch (err) {
        console.error('Error durante la inspección Live:', err);
    }
}

inspect().catch(console.error);
