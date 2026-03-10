import { Injectable, Logger } from '@nestjs/common';
import axios from 'axios';
import * as crypto from 'crypto';

export interface HibpBreach {
  name: string;
  domain: string;
  breachDate: string;
  dataClasses: string[];
  isVerified: boolean;
}

export interface HibpReport {
  isPwned: boolean;
  breachCount: number;
  breaches: HibpBreach[];
  summary: string;
}

@Injectable()
export class HibpService {
  private readonly logger = new Logger(HibpService.name);

  // HIBP k-Anonymity password check (no requiere API key)
  async checkPassword(password: string): Promise<{ pwned: boolean; count: number }> {
    try {
      const hash = crypto.createHash('sha1').update(password).digest('hex').toUpperCase();
      const prefix = hash.slice(0, 5);
      const suffix = hash.slice(5);
      const res = await axios.get(`https://api.pwnedpasswords.com/range/${prefix}`, {
        headers: { 'Add-Padding': 'true' },
      });
      const lines: string[] = res.data.split('\r\n');
      for (const line of lines) {
        const [h, countStr] = line.split(':');
        if (h === suffix) {
          return { pwned: true, count: parseInt(countStr, 10) };
        }
      }
      return { pwned: false, count: 0 };
    } catch (e) {
      this.logger.error(`Error HIBP contraseña: ${e.message}`);
      return { pwned: false, count: 0 };
    }
  }

  // Generador de contraseñas seguras (local, sin API)
  generateSecurePassword(length = 20): string {
    const upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    const lower = 'abcdefghijklmnopqrstuvwxyz';
    const digits = '0123456789';
    const symbols = '!@#$%^&*()-_=+[]{}|;:,.<>?';
    const all = upper + lower + digits + symbols;

    // Garantizamos al menos uno de cada tipo
    const required = [
      upper[Math.floor(Math.random() * upper.length)],
      lower[Math.floor(Math.random() * lower.length)],
      digits[Math.floor(Math.random() * digits.length)],
      symbols[Math.floor(Math.random() * symbols.length)],
    ];

    const rest = Array.from({ length: length - required.length }, () =>
      all[Math.floor(Math.random() * all.length)],
    );

    // Mezclar para evitar patrones predecibles
    return [...required, ...rest]
      .sort(() => Math.random() - 0.5)
      .join('');
  }
}
