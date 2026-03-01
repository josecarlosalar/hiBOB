import { IsString, IsNotEmpty, IsOptional, IsArray, IsEnum } from 'class-validator';

export enum MessageRole {
  USER = 'user',
  MODEL = 'model',
}

export class CreateMessageDto {
  @IsString()
  @IsNotEmpty()
  conversationId: string;

  @IsEnum(MessageRole)
  role: MessageRole;

  @IsString()
  @IsNotEmpty()
  text: string;

  @IsOptional()
  @IsArray()
  imageBase64List?: string[];
}
