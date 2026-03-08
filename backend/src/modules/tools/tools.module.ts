import { Module } from '@nestjs/common';
import { BraveSearchService } from './brave-search.service';
import { LocationService } from './location.service';
import { VirusTotalService } from './virustotal.service';

@Module({
  providers: [BraveSearchService, LocationService, VirusTotalService],
  exports: [BraveSearchService, LocationService, VirusTotalService],
})
export class ToolsModule { }
