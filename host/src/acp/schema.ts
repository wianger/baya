/**
 * The slice of ACP v1 (https://agentclientprotocol.com) that Baya reads.
 * Baya is a proxy: everything else passes through untouched, so these types
 * describe only fields the host inspects or produces.
 */

export const PROTOCOL_VERSION = 1;

/** `text`, `image`, `audio`, `resource_link` or `resource`. */
export type ContentBlock = { type: string; [key: string]: unknown };

/** One `session/update` payload; `sessionUpdate` is the discriminator. */
export type SessionUpdate = { sessionUpdate: string; [key: string]: unknown };

interface PromptCapabilities {
  image?: boolean;
  audio?: boolean;
  embeddedContext?: boolean;
}

export interface AgentCapabilities {
  loadSession?: boolean;
  promptCapabilities?: PromptCapabilities;
  sessionCapabilities?: {
    list?: object | null;
    resume?: object | null;
    close?: object | null;
    delete?: object | null;
  };
}

export interface InitializeResponse {
  protocolVersion: number;
  agentCapabilities?: AgentCapabilities;
  agentInfo?: { name: string; title?: string | null; version: string } | null;
  authMethods?: Array<{ id: string; name: string; description?: string | null }>;
}

export interface SessionSetup {
  configOptions?: unknown[] | null;
  modes?: { currentModeId: string; availableModes: unknown[] } | null;
}

export interface NewSessionResponse extends SessionSetup {
  sessionId: string;
}

export type StopReason = "end_turn" | "max_tokens" | "max_turn_requests" | "refusal" | "cancelled";

export interface PromptResponse {
  stopReason: StopReason;
}

/** Baya's own wire additions travel in `_meta.baya` or as `_baya/*` methods. */
export const BAYA_META = "baya";
