import { Injectable, Logger } from '@nestjs/common';

@Injectable()
export class LocationService {
  private readonly logger = new Logger(LocationService.name);

  /**
   * Simula la obtención de la ubicación actual.
   * En una implementación real, esto podría recibir coordenadas del cliente
   * o usar una API de IP/Geolocalización.
   */
  async getCurrentLocation(): Promise<string> {
    this.logger.log('Obteniendo ubicación actual...');
    
    // Hardcoded para el demo del hackathon, o se podría mejorar para ser dinámico
    return 'Calle Gran Vía, 28, 28013 Madrid, España. Estás cerca de la estación de metro Gran Vía.';
  }
}
