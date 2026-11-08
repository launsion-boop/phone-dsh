// SPDX-License-Identifier: MIT
// Small, dependency-free helpers shared by the native HostService modules.
// Everything here is defensive about the JSON crossing the page/native seam:
// missing members are reported by helpers instead of leaking `undefined` into
// persisted state or ArkUI.
import { util } from '@kit.ArkTS';

const BASE64: util.Base64Helper = new util.Base64Helper();
const TEXT_ENCODER: util.TextEncoder = new util.TextEncoder();
const TEXT_DECODER: util.TextDecoder = new util.TextDecoder('utf-8');

export function asRecord(value: Object | null | undefined): Record<string, Object> | null {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, Object>;
}

export function asArray(value: Object | null | undefined): Object[] {
  if (value === null || value === undefined) {
    return [];
  }
  if (!Array.isArray(value)) {
    return [];
  }
  return value as Object[];
}

export function field(record: Record<string, Object> | null, key: string): Object | null {
  if (record === null) {
    return null;
  }
  const value: Object | undefined = record[key];
  if (value === undefined) {
    return null;
  }
  return value;
}

export function jsonString(record: Record<string, Object> | null, key: string, fallback: string = ''): string {
  const value = field(record, key);
  return typeof value === 'string' ? value : fallback;
}

export function jsonNumber(record: Record<string, Object> | null, key: string, fallback: number = 0): number {
  const value = field(record, key);
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  return fallback;
}

export function jsonBool(record: Record<string, Object> | null, key: string, fallback: boolean = false): boolean {
  const value = field(record, key);
  return typeof value === 'boolean' ? value : fallback;
}

export function stringArray(value: Object | null | undefined): string[] {
  const result: string[] = [];
  const rows = asArray(value);
  for (let index = 0; index < rows.length; index++) {
    const row = rows[index];
    if (typeof row === 'string') {
      result.push(row);
    }
  }
  return result;
}

export function parseJsonObject(text: string): Record<string, Object> | null {
  if (text.length === 0) {
    return null;
  }
  try {
    return asRecord(JSON.parse(text) as Object);
  } catch (error) {
    return null;
  }
}

export function stringify(value: Object): string {
  try {
    return JSON.stringify(value);
  } catch (error) {
    return '';
  }
}

export function encodeBase64(bytes: Uint8Array): string {
  return BASE64.encodeToStringSync(bytes);
}

export function decodeBase64(text: string): Uint8Array {
  return BASE64.decodeSync(text);
}

export function encodeUtf8(text: string): Uint8Array {
  return TEXT_ENCODER.encodeInto(text);
}

export function decodeUtf8(bytes: Uint8Array): string {
  return TEXT_DECODER.decodeToString(bytes);
}

export function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

export function emptyArrayBuffer(): ArrayBuffer {
  return new ArrayBuffer(0);
}

export function uniqueId(prefix: string): string {
  const time = Date.now().toString(36);
  const random = Math.floor(Math.random() * 0x7fffffff).toString(36);
  return `${prefix}-${time}-${random}`;
}

export function errorText(error: Error): string {
  if (error === null || error === undefined) {
    return 'unknown error';
  }
  const message = error.message;
  if (message !== undefined && message.length > 0) {
    return message.substring(0, 500);
  }
  return 'host operation failed';
}

export function redact(text: string, secret: string): string {
  let value = text;
  if (secret.length > 0) {
    value = value.split(secret).join('[redacted]');
  }
  value = value.replace(/Bearer\s+[^\s,;]+/gi, 'Bearer [redacted]');
  return value;
}

export function bounded(text: string, limit: number): string {
  if (text.length <= limit) {
    return text;
  }
  return text.substring(0, limit);
}

export function trimSlashes(value: string): string {
  let text = value.trim();
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

export function baseName(path: string): string {
  const noQuery = path.split('?')[0];
  const parts = noQuery.split('/');
  const last = parts[parts.length - 1];
  return last.length > 0 ? last : 'file';
}

export function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, milliseconds);
  });
}

// ---------------------------------------------------------------- bridge types

export interface BridgeCallFrame {
  id: number;
  method: string;
  args: Object;
}

export interface FollowArgs {
  sessionId: string;
  streamId: string;
}

export interface EventsArgs {
  streamId: string;
}

export interface CloseStreamArgs {
  streamId: string;
}

export interface WriteFileArgs {
  path: string;
  base64: string;
}

export interface ReadFileArgs {
  path: string;
}

export interface ListFilesArgs {
  path: string;
}

// image-resource-4: private Worker binary snapshot commands. Replies carry a
// random handle and one bounded base64 chunk; bytes never enter the snapshot.
export interface OpenBinaryReadArgs {
  path: string;
}

export interface ReadBinaryChunkArgs {
  id: string;
  offset: number;
}

export interface CloseBinaryReadArgs {
  id: string;
}

export interface BinaryOpenReply {
  id: string;
  size: number;
  mime: string;
}

export interface BinaryChunkReply {
  id: string;
  size: number;
  offset: number;
  base64: string;
}

export interface BinaryCloseReply {
  closed: boolean;
}

export interface CommandArgs {
  command: string;
  cwd: string;
}

export interface SessionCreateRequest {
  cwd: string;
  agentPreset?: string;
}

export interface SessionCreateArgs {
  request: SessionCreateRequest;
}

export interface PromptContent {
  type: string;
  text: string;
}

export interface SessionPromptRequest {
  requestId: string;
  sessionId: string;
  mode: string;
  content: PromptContent[];
}

export interface SessionPromptArgs {
  request: SessionPromptRequest;
}

export interface SessionCancelRequest {
  sessionId: string;
}

export interface SessionCancelArgs {
  request: SessionCancelRequest;
}

export interface EventAnswerArgs {
  clientId: string;
  eventId: string;
  outcome: Object;
}

export interface SettingsUpdateArgs {
  ns: string;
  patch: Record<string, Object>;
  expectedRevision?: number;
}

export interface PluginToggleArgs {
  entryId: string;
  enabled: boolean;
}

export function promptContent(text: string): PromptContent[] {
  const block: PromptContent = { type: 'text', text: text };
  return [block];
}
