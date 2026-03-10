import { Module } from '@nestjs/common';
import { BraveSearchService } from './brave-search.service';
import { LocationService } from './location.service';
import { VirusTotalService } from './virustotal.service';
import { HibpService } from './hibp.service';

@Module({
  providers: [BraveSearchService, LocationService, VirusTotalService, HibpService],
  exports: [BraveSearchService, LocationService, VirusTotalService, HibpService],
})
export class ToolsModule { }
