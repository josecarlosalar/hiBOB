import { IsString, IsNotEmpty, IsOptional, IsArray } from 'class-validator';

export class GenerateContentDto {
  @IsString()
  @IsNotEmpty()
  prompt: string;

  @IsOptional()
  @IsString()
  conversationId?: string;

  @IsOptional()
  @IsArray()
  imageBase64List?: string[];
}
