import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { AllExceptionsFilter } from './common/filters/http-exception.filter';
import { LoggingInterceptor } from './common/interceptors/logging.interceptor';
import { globalValidationPipe } from './common/pipes/validation.pipe';
import { writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

// Si viene el JSON de la SA como variable de entorno, lo escribe a disco
// para que las librerías de Google (ADC) lo encuentren via GOOGLE_APPLICATION_CREDENTIALS
if (process.env.GOOGLE_APPLICATION_CREDENTIALS_JSON) {
  const keyPath = join(tmpdir(), 'sa-key.json');
  writeFileSync(keyPath, process.env.GOOGLE_APPLICATION_CREDENTIALS_JSON, 'utf8');
  process.env.GOOGLE_APPLICATION_CREDENTIALS = keyPath;
  console.log(`SA key written to ${keyPath}`);
}

async function bootstrap() {
  const app = await NestFactory.create(AppModule, {
    bodyParser: true,
  });
  app.use(require('express').json({ limit: '20mb' }));

  const isProd = process.env.NODE_ENV === 'production';
  app.enableCors({
    origin: isProd
      ? (process.env.ALLOWED_ORIGINS ?? '').split(',').filter(Boolean)
      : '*',
    methods: ['GET', 'POST', 'PUT', 'DELETE'],
    allowedHeaders: ['Content-Type', 'Authorization'],
  });

  app.useGlobalFilters(new AllExceptionsFilter());
  app.useGlobalInterceptors(new LoggingInterceptor());
  app.useGlobalPipes(globalValidationPipe);

  const port = process.env.PORT ?? 3000;
  await app.listen(port);
  console.log(`Application is running on: http://localhost:${port}`);
}
bootstrap();
// Fri Mar  6 17:58:24     2026
