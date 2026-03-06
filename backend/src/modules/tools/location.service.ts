import { Injectable, Logger } from '@nestjs/common';

export interface ClientLocation {
  latitude: number;
  longitude: number;
  accuracy?: number;
}

@Injectable()
export class LocationService {
  private readonly logger = new Logger(LocationService.name);

  // Coordenadas GPS enviadas por el cliente móvil, indexadas por socketId
  private clientLocations = new Map<string, ClientLocation>();

  setClientLocation(socketId: string, location: ClientLocation) {
    this.clientLocations.set(socketId, location);
  }

  removeClientLocation(socketId: string) {
    this.clientLocations.delete(socketId);
  }

  /**
   * Devuelve la ubicación más precisa disponible:
   * 1. Coordenadas GPS enviadas por el cliente (más precisa)
   * 2. Geolocalización por IP del servidor como fallback
   */
  async getCurrentLocation(socketId?: string): Promise<string> {
    if (socketId) {
      const gps = this.clientLocations.get(socketId);
      if (gps) {
        return this.reverseGeocode(gps.latitude, gps.longitude);
      }
    }
    return this.getLocationByIp();
  }

  private async reverseGeocode(lat: number, lon: number): Promise<string> {
    try {
      const url = `https://nominatim.openstreetmap.org/reverse?lat=${lat}&lon=${lon}&format=json`;
      const res = await fetch(url, {
        headers: { 'User-Agent': 'hiBOB-Agent/1.0' },
        signal: AbortSignal.timeout(4000),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data: any = await res.json();
      const addr = data.address ?? {};
      const parts = [
        addr.road,
        addr.house_number,
        addr.city ?? addr.town ?? addr.village,
        addr.country,
      ].filter(Boolean);
      return parts.length > 0
        ? parts.join(', ')
        : `Coordenadas: ${lat.toFixed(4)}, ${lon.toFixed(4)}`;
    } catch (err) {
      this.logger.warn(`reverseGeocode error: ${err.message}`);
      return `Coordenadas: ${lat.toFixed(4)}, ${lon.toFixed(4)}`;
    }
  }

  private async getLocationByIp(): Promise<string> {
    try {
      const res = await fetch('http://ip-api.com/json/?fields=city,regionName,country,lat,lon', {
        signal: AbortSignal.timeout(4000),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data: any = await res.json();
      if (data.city) {
        return `${data.city}, ${data.regionName}, ${data.country}`;
      }
    } catch (err) {
      this.logger.warn(`getLocationByIp error: ${err.message}`);
    }
    return 'Ubicación no disponible. Pide al usuario que active el GPS.';
  }
}
