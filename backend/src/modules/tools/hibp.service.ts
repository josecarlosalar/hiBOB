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
  generateSecurePassword(
    length = 20,
    options: {
      includeUppercase?: boolean;
      includeLowercase?: boolean;
      includeNumbers?: boolean;
      includeSymbols?: boolean;
    } = {},
  ): { password: string; usedUppercase: boolean; usedLowercase: boolean; usedNumbers: boolean; usedSymbols: boolean } {
    const {
      includeUppercase = true,
      includeLowercase = true,
      includeNumbers = true,
      includeSymbols = true,
    } = options;

    const upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    const lower = 'abcdefghijklmnopqrstuvwxyz';
    const digits = '0123456789';
    const symbols = '!@#$%^&*()-_=+[]{}|;:,.<>?';

    // Al menos un charset activo
    const charsets: string[] = [];
    if (includeUppercase) charsets.push(upper);
    if (includeLowercase) charsets.push(lower);
    if (includeNumbers) charsets.push(digits);
    if (includeSymbols) charsets.push(symbols);
    if (charsets.length === 0) charsets.push(lower, digits); // fallback

    const all = charsets.join('');

    // Garantizamos al menos uno de cada charset activo
    const required = charsets.map(cs => cs[Math.floor(Math.random() * cs.length)]);

    const rest = Array.from({ length: Math.max(0, length - required.length) }, () =>
      all[Math.floor(Math.random() * all.length)],
    );

    const password = [...required, ...rest]
      .sort(() => Math.random() - 0.5)
      .join('');

    return {
      password,
      usedUppercase: includeUppercase,
      usedLowercase: includeLowercase,
      usedNumbers: includeNumbers,
      usedSymbols: includeSymbols,
    };
  }
}
