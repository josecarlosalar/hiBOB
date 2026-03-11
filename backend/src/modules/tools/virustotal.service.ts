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
  private readonly baseHeaders: Record<string, string>;

  constructor(private configService: ConfigService) {
    this.apiKey = (this.configService.get<string>('VIRUSTOTAL_API_KEY') ?? '').trim().replace(/[\r\n\t]/g, '');
    this.baseHeaders = { 'x-apikey': this.apiKey };
    if (this.apiKey) {
      this.logger.log(`VirusTotal API Key cargada (${this.apiKey.length} chars)`);
    } else {
      this.logger.warn('VIRUSTOTAL_API_KEY no configurada');
    }
  }

  private notConfigured(): VirusTotalReport {
    return { status: 'unknown', positives: 0, total: 0, details: JSON.stringify({ error: 'API key de VirusTotal no configurada.' }) };
  }

  private buildStats(stats: any, extra: Record<string, any> = {}): VirusTotalReport {
    const malicious = stats.malicious ?? 0;
    const suspicious = stats.suspicious ?? 0;
    const harmless = stats.harmless ?? 0;
    const undetected = stats.undetected ?? 0;
    const positives = malicious + suspicious;
    const total = harmless + malicious + suspicious + undetected;
    const status: VirusTotalReport['status'] = malicious > 0 ? 'dangerous' : suspicious > 0 ? 'suspicious' : 'safe';
    return {
      status,
      positives,
      total,
      details: JSON.stringify({ positives, total, malicious, suspicious, harmless, undetected, ...extra }),
    };
  }

  // ─── URL ─────────────────────────────────────────────────────────────────

  async analyzeUrl(url: string): Promise<VirusTotalReport> {
    if (!this.apiKey) return this.notConfigured();
    try {
      this.logger.log(`Analizando URL: ${url}`);
      const formData = new URLSearchParams();
      formData.append('url', url);
      const scanRes = await axios.post('https://www.virustotal.com/api/v3/urls', formData, {
        headers: { ...this.baseHeaders, 'Content-Type': 'application/x-www-form-urlencoded' },
      });
      this.logger.log(`[VT] Scan enviado, analysisId: ${scanRes.data?.data?.id}`);
      const analysisId = scanRes.data.data.id;
      // Esperar a que el análisis esté listo (hasta 6 intentos con 3s de pausa = 18s máx)
      for (let i = 0; i < 6; i++) {
        await new Promise(r => setTimeout(r, 3000));
        const reportRes = await axios.get(`https://www.virustotal.com/api/v3/analyses/${analysisId}`, {
          headers: this.baseHeaders,
        });
        const status = reportRes.data.data.attributes.status;
        this.logger.log(`[VT] Análisis estado: ${status} (intento ${i + 1}/6)`);
        if (status === 'completed') {
          const stats = reportRes.data.data.attributes.stats;
          return this.buildStats(stats, { url });
        }
      }
      // Si no completó tras los intentos, devolver resultado parcial indicando que está en proceso
      return { status: 'unknown', positives: 0, total: 0, details: JSON.stringify({ pending: true, url, message: 'El análisis está en cola en VirusTotal. Inténtalo de nuevo en unos segundos.' }) };
    } catch (e) {
      this.logger.error(`Error VT URL: ${e.message} | status: ${e.response?.status} | data: ${JSON.stringify(e.response?.data)}`);
      return { status: 'unknown', positives: 0, total: 0, details: JSON.stringify({ error: 'No se pudo completar el análisis.', url }) };
    }
  }

  // ─── IP ──────────────────────────────────────────────────────────────────

  async analyzeIp(ip: string): Promise<VirusTotalReport> {
    if (!this.apiKey) return this.notConfigured();
    try {
      this.logger.log(`Analizando IP: ${ip}`);
      const res = await axios.get(`https://www.virustotal.com/api/v3/ip_addresses/${encodeURIComponent(ip)}`, {
        headers: this.baseHeaders,
      });
      const attr = res.data.data.attributes;
      const stats = attr.last_analysis_stats ?? {};
      return this.buildStats(stats, {
        ip,
        country: attr.country ?? 'Desconocido',
        asOwner: attr.as_owner ?? 'Desconocido',
        network: attr.network ?? '',
        reputation: attr.reputation ?? 0,
      });
    } catch (e) {
      this.logger.error(`Error VT IP: ${e.message} | status: ${e.response?.status}`);
      return { status: 'unknown', positives: 0, total: 0, details: JSON.stringify({ error: 'No se pudo analizar la IP.', ip }) };
    }
  }

  // ─── Dominio ─────────────────────────────────────────────────────────────

  async analyzeDomain(domain: string): Promise<VirusTotalReport> {
    if (!this.apiKey) return this.notConfigured();
    try {
      this.logger.log(`Analizando dominio: ${domain}`);
      const res = await axios.get(`https://www.virustotal.com/api/v3/domains/${encodeURIComponent(domain)}`, {
        headers: this.baseHeaders,
      });
      const attr = res.data.data.attributes;
      const stats = attr.last_analysis_stats ?? {};
      const creationDate = attr.creation_date
        ? new Date(attr.creation_date * 1000).toLocaleDateString('es-ES')
        : 'Desconocida';
      const categories = attr.categories ? Object.values(attr.categories).join(', ') : 'Sin categoría';
      return this.buildStats(stats, {
        domain,
        registrar: attr.registrar ?? 'Desconocido',
        creationDate,
        categories,
        reputation: attr.reputation ?? 0,
      });
    } catch (e) {
      this.logger.error(`Error VT dominio: ${e.message} | status: ${e.response?.status}`);
      return { status: 'unknown', positives: 0, total: 0, details: JSON.stringify({ error: 'No se pudo analizar el dominio.', domain }) };
    }
  }

  // ─── Hash de archivo ─────────────────────────────────────────────────────

  async analyzeHash(hash: string): Promise<VirusTotalReport> {
    if (!this.apiKey) return this.notConfigured();
    try {
      this.logger.log(`Analizando hash: ${hash}`);
      const res = await axios.get(`https://www.virustotal.com/api/v3/files/${encodeURIComponent(hash)}`, {
        headers: this.baseHeaders,
      });
      const attr = res.data.data.attributes;
      const stats = attr.last_analysis_stats ?? {};
      return this.buildStats(stats, {
        hash,
        fileName: attr.meaningful_name ?? 'Desconocido',
        fileType: attr.type_description ?? 'Desconocido',
        fileSize: attr.size ? `${Math.round(attr.size / 1024)} KB` : 'Desconocido',
        tags: (attr.tags ?? []).join(', '),
      });
    } catch (e) {
      this.logger.error(`Error VT hash: ${e.message} | status: ${e.response?.status}`);
      return { status: 'unknown', positives: 0, total: 0, details: JSON.stringify({ error: 'Hash no encontrado en VirusTotal.', hash }) };
    }
  }

  // ─── Archivo (upload) ────────────────────────────────────────────────────

  async analyzeFile(fileBase64: string, fileName: string): Promise<VirusTotalReport> {
    if (!this.apiKey) return this.notConfigured();
    try {
      this.logger.log(`Subiendo archivo a VirusTotal: ${fileName}`);
      const buffer = Buffer.from(fileBase64, 'base64');

      const FormData = (await import('form-data')).default;
      const form = new FormData();
      form.append('file', buffer, { filename: fileName });

      const uploadRes = await axios.post('https://www.virustotal.com/api/v3/files', form, {
        headers: { ...this.baseHeaders, ...form.getHeaders() },
        maxContentLength: 32 * 1024 * 1024,
      });
      const analysisId = uploadRes.data.data.id;

      // Esperar resultado (poll hasta 3 intentos con 3s de pausa)
      for (let i = 0; i < 3; i++) {
        await new Promise(r => setTimeout(r, 3000));
        const reportRes = await axios.get(`https://www.virustotal.com/api/v3/analyses/${analysisId}`, {
          headers: this.baseHeaders,
        });
        const status = reportRes.data.data.attributes.status;
        if (status === 'completed') {
          const stats = reportRes.data.data.attributes.stats;
          return this.buildStats(stats, { fileName });
        }
      }
      return { status: 'unknown', positives: 0, total: 0, details: 'Análisis en progreso. Intenta de nuevo en unos segundos.' };
    } catch (e) {
      this.logger.error(`Error VT archivo: ${e.message} | status: ${e.response?.status}`);
      return { status: 'unknown', positives: 0, total: 0, details: JSON.stringify({ error: 'No se pudo analizar el archivo.', fileName }) };
    }
  }
}
