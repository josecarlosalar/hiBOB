import { GoogleGenAI } from '@google/genai';
import * as dotenv from 'dotenv';
dotenv.config();

async function inspect() {
    const genAI = new GoogleGenAI({
        vertexai: true,
        project: process.env.GCP_PROJECT_ID || 'test',
        location: process.env.GCP_LOCATION || 'us-central1',
    });

    console.log('--- GenAI Inspection ---');
    console.log('Methods:', Object.keys(genAI));

    // En @google/genai (Unified SDK), no existe getGenerativeModel en la instancia principal.
    // Se usa directamente genAI.models o se inspecciona el objeto models.
    console.log('--- Models Inspection ---');
    console.log('Available in .models:', Object.keys(genAI.models));

    try {
        const response = await genAI.models.generateContent({
            model: 'gemini-2.0-flash-exp',
            contents: [{ role: 'user', parts: [{ text: 'Hola, di "Conexión exitosa"' }] }]
        });
        console.log('--- Test Response ---');
        console.log('Response text:', response.text);
    } catch (err) {
        console.error('Error al generar contenido:', err);
    }
}

inspect().catch(console.error);
