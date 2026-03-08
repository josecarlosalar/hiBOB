import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import axios from 'axios';

export interface VirusTotalReport {
  status: 'safe' | 'dangerous' | 'suspicious' | 'unknown';
  positives: number;
  total: number;
  details: string;
}

@Injectable()
export class VirusTotalService {
  private readonly logger = new Logger(VirusTotalService.name);
  private readonly apiKey: string;

  constructor(private configService: ConfigService) {
    this.apiKey = this.configService.get<string>('VIRUSTOTAL_API_KEY') ?? '';
  }

  async analyzeUrl(url: string): Promise<VirusTotalReport> {
    if (!this.apiKey) {
      this.logger.error('VIRUSTOTAL_API_KEY no configurada');
      return { status: 'unknown', positives: 0, total: 0, details: 'Servicio de seguridad no configurado.' };
    }

    try {
      this.logger.log(`Analizando URL en VirusTotal: ${url}`);
      
      // En VirusTotal, primero enviamos la URL para analizar y obtener un ID
      const formData = new URLSearchParams();
      formData.append('url', url);

      const scanResponse = await axios.post(
        'https://www.virustotal.com/api/v3/urls',
        formData,
        {
          headers: {
            'x-apikey': this.apiKey,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        },
      );

      const analysisId = scanResponse.data.data.id;
      
      // Obtenemos el reporte usando el ID de análisis
      const reportResponse = await axios.get(
        `https://www.virustotal.com/api/v3/analyses/${analysisId}`,
        {
          headers: { 'x-apikey': this.apiKey },
        },
      );

      const stats = reportResponse.data.data.attributes.stats;
      const positives = stats.malicious + stats.suspicious;
      const total = stats.harmless + stats.malicious + stats.suspicious + stats.undetected;

      let status: 'safe' | 'dangerous' | 'suspicious' = 'safe';
      if (stats.malicious > 0) status = 'dangerous';
      else if (stats.suspicious > 0) status = 'suspicious';

      return {
        status,
        positives,
        total,
        details: `Reporte de seguridad: ${positives} de ${total} motores detectaron amenazas.`,
      };
    } catch (e) {
      this.logger.error(`Error en VirusTotal: ${e.message}`);
      return { status: 'unknown', positives: 0, total: 0, details: 'No se pudo completar el análisis de seguridad.' };
    }
  }
}
