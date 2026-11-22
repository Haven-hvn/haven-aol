/**
 * Haven OS Cross-Site Runtime Bridge (`haven-os:v1`)
 *
 * Allows any Haven app (embedded same-origin or cross-site, e.g. *.pinme.dev)
 * to share a single EIP-1193 / EIP-6963 wallet, VetKD gate keyring, and
 * Control Panel network configuration with Haven OS via `window.postMessage`.
 */

export const HAVEN_OS_BRIDGE_CHANNEL = "haven-os:v1" as const;

export interface HavenOsBridgeConfig {
  arkivNetworkName: string;
  arkivRpcUrl: string;
  ipfsGateway: string;
  havenAolCanisterId: string;
  icpHost: string;
}

export interface HavenOsBridgeWalletInfo {
  address: string | null;
  chainId: number | null;
  walletName: string | null;
  watchOnly?: boolean;
}

export interface HavenOsWelcomePayload {
  wallet: HavenOsBridgeWalletInfo;
  config: HavenOsBridgeConfig;
  unlockedGates: string[];
}

export interface HavenOsBridgeRequest {
  channel: typeof HAVEN_OS_BRIDGE_CHANNEL;
  kind: "request";
  id: string;
  method: string;
  params?: unknown;
}

export interface HavenOsBridgeResponse {
  channel: typeof HAVEN_OS_BRIDGE_CHANNEL;
  kind: "response";
  id: string;
  result?: unknown;
  error?: { code: number; message: string };
}

export interface HavenOsBridgeHello {
  channel: typeof HAVEN_OS_BRIDGE_CHANNEL;
  kind: "hello";
  appId?: string;
}

export interface HavenOsBridgeWelcome {
  channel: typeof HAVEN_OS_BRIDGE_CHANNEL;
  kind: "welcome";
  payload: HavenOsWelcomePayload;
}

export interface HavenOsBridgeEvent {
  channel: typeof HAVEN_OS_BRIDGE_CHANNEL;
  kind: "event";
  event: "accountsChanged" | "chainChanged" | "configChanged" | "keyringChanged";
  data: unknown;
}

export type HavenOsBridgeMessage =
  | HavenOsBridgeHello
  | HavenOsBridgeWelcome
  | HavenOsBridgeRequest
  | HavenOsBridgeResponse
  | HavenOsBridgeEvent;

export interface BridgeEip1193Provider {
  isHavenOsBridge: true;
  request: (args: { method: string; params?: unknown[] | Record<string, unknown> }) => Promise<unknown>;
  on: (event: string, listener: (...args: unknown[]) => void) => void;
  removeListener: (event: string, listener: (...args: unknown[]) => void) => void;
}

export interface HavenOsBridgeClient {
  isEmbedded: boolean;
  connectedToHost: boolean;
  hostOrigin: string | null;
  provider: BridgeEip1193Provider;
  waitForWelcome: (timeoutMs?: number) => Promise<HavenOsWelcomePayload | null>;
  getConfig: () => Promise<HavenOsBridgeConfig>;
  getGateKey: (gateId: string, epoch?: number) => Promise<{ gateId: string; epoch: number; rawKeyBase64: string } | null>;
  unlockGate: (params: {
    gateId: string;
    chainId: number;
    tokenAddress: string;
    threshold: string;
    epoch?: number;
  }) => Promise<{ gateId: string; epoch: number; rawKeyBase64: string }>;
  onEvent: (
    event: HavenOsBridgeEvent["event"],
    listener: (data: unknown) => void,
  ) => () => void;
  destroy: () => void;
}

const HAVEN_OS_ICON_SVG =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="4" fill="#0a246a"/><text x="16" y="22" font-family="Tahoma,sans-serif" font-size="16" font-weight="bold" fill="#fff" text-anchor="middle">H</text></svg>`,
  );

let singletonClient: HavenOsBridgeClient | null = null;

/**
 * Registers the Haven OS cross-site EIP-6963 + VetKD + Config bridge when
 * running inside an iframe (`window.self !== window.top`).
 */
export function registerHavenOsBridge(options?: {
  appId?: string;
  announceEip6963?: boolean;
}): HavenOsBridgeClient | null {
  if (typeof window === "undefined") return null;
  if (singletonClient) return singletonClient;

  const isEmbedded = window.self !== window.top;
  if (!isEmbedded) return null;

  let seq = 0;
  let hostOrigin: string | null = null;
  let connectedToHost = false;
  let welcomePayload: HavenOsWelcomePayload | null = null;

  const pending = new Map<
    string,
    { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: number }
  >();
  const listeners = new Map<string, Set<(...args: unknown[]) => void>>();
  const welcomeWaiters: Array<(p: HavenOsWelcomePayload) => void> = [];

  const emit = (event: string, data: unknown) => {
    const set = listeners.get(event);
    if (!set) return;
    for (const fn of set) {
      try {
        fn(data);
      } catch {
        // ignore listener errors
      }
    }
  };

  const rpc = (method: string, params?: unknown, timeoutMs = 45_000): Promise<unknown> => {
    const id = `hos-${Date.now().toString(36)}-${++seq}`;
    const target = hostOrigin || "*";
    return new Promise((resolve, reject) => {
      const timer = window.setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Haven OS bridge timeout for ${method}`));
      }, timeoutMs);
      pending.set(id, { resolve, reject, timer });
      const msg: HavenOsBridgeRequest = {
        channel: HAVEN_OS_BRIDGE_CHANNEL,
        kind: "request",
        id,
        method,
        params,
      };
      window.parent.postMessage(msg, target);
    });
  };

  const provider: BridgeEip1193Provider = {
    isHavenOsBridge: true,
    request: ({ method, params }) => rpc(method, params),
    on: (event, listener) => {
      let set = listeners.get(event);
      if (!set) {
        set = new Set();
        listeners.set(event, set);
      }
      set.add(listener);
    },
    removeListener: (event, listener) => {
      listeners.get(event)?.delete(listener);
    },
  };

  const onMessage = (ev: MessageEvent) => {
    if (ev.source !== window.parent) return;
    const data = ev.data as Partial<HavenOsBridgeMessage> | null;
    if (!data || data.channel !== HAVEN_OS_BRIDGE_CHANNEL) return;

    if (data.kind === "welcome" && data.payload) {
      hostOrigin = ev.origin || "*";
      connectedToHost = true;
      welcomePayload = data.payload;
      while (welcomeWaiters.length > 0) {
        welcomeWaiters.shift()?.(data.payload);
      }
      return;
    }

    if (data.kind === "response" && data.id) {
      const entry = pending.get(data.id);
      if (!entry) return;
      clearTimeout(entry.timer);
      pending.delete(data.id);
      if (data.error) {
        const err = new Error(data.error.message) as Error & { code?: number };
        err.code = data.error.code;
        entry.reject(err);
      } else {
        entry.resolve(data.result);
      }
      return;
    }

    if (data.kind === "event" && data.event) {
      emit(data.event, data.data);
    }
  };

  window.addEventListener("message", onMessage);

  // Announce via EIP-6963 so Wagmi, AppKit, ethers, viem discover it automatically
  const announce = () => {
    if (options?.announceEip6963 === false) return;
    window.dispatchEvent(
      new CustomEvent("eip6963:announceProvider", {
        detail: Object.freeze({
          info: Object.freeze({
            uuid: "haven-os-shared-wallet-v1",
            name: "Haven OS Shared Wallet",
            icon: HAVEN_OS_ICON_SVG,
            rdns: "network.haven.os",
          }),
          provider,
        }),
      }),
    );
  };

  const onRequestProvider = () => announce();
  window.addEventListener("eip6963:requestProvider", onRequestProvider);
  announce();

  // Send handshake hello to parent Haven OS host
  const hello: HavenOsBridgeHello = {
    channel: HAVEN_OS_BRIDGE_CHANNEL,
    kind: "hello",
    appId: options?.appId,
  };
  window.parent.postMessage(hello, "*");

  const client: HavenOsBridgeClient = {
    isEmbedded: true,
    get connectedToHost() {
      return connectedToHost;
    },
    get hostOrigin() {
      return hostOrigin;
    },
    provider,
    waitForWelcome: (timeoutMs = 1800) => {
      if (welcomePayload) return Promise.resolve(welcomePayload);
      return new Promise((resolve) => {
        const t = window.setTimeout(() => resolve(null), timeoutMs);
        welcomeWaiters.push((p) => {
          clearTimeout(t);
          resolve(p);
        });
      });
    },
    getConfig: () => rpc("haven_getConfig") as Promise<HavenOsBridgeConfig>,
    getGateKey: (gateId, epoch) =>
      rpc("haven_getGateKey", { gateId, epoch }) as Promise<{
        gateId: string;
        epoch: number;
        rawKeyBase64: string;
      } | null>,
    unlockGate: (params) =>
      rpc("haven_unlockGate", params, 120_000) as Promise<{
        gateId: string;
        epoch: number;
        rawKeyBase64: string;
      }>,
    onEvent: (event, listener) => {
      provider.on(event, listener as (...args: unknown[]) => void);
      return () => provider.removeListener(event, listener as (...args: unknown[]) => void);
    },
    destroy: () => {
      window.removeEventListener("message", onMessage);
      window.removeEventListener("eip6963:requestProvider", onRequestProvider);
      singletonClient = null;
    },
  };

  singletonClient = client;
  return client;
}
