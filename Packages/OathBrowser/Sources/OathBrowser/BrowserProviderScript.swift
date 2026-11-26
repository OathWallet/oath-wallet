import Foundation

public enum BrowserProviderScript {
    /// Page-world facade; authority lives entirely in native code and WebKit frame metadata.
    public static let source = #"""
    (() => {
      if (window !== window.top || window.oath?.isOath) return;
      const listeners = new Map();
      let documentID = null, accounts = [], chainId = '0x1', connected = false;
      const failure = (code, message) => Object.assign(new Error(message), {code});
      async function bridge(method, params, document) {
        const response = await window.webkit.messageHandlers.oathWallet.postMessage({method, params, document});
        if (response?.error) throw failure(response.error.code, response.error.message);
        return response?.result;
      }
      const emit = (name, value) => {
        for (const listener of [...(listeners.get(name) || [])]) { try { listener(value); } catch (_) {} }
      };
      const provider = {
        isOath: true,
        // Legacy dapps still write this switch. Oath emits chainChanged and never reloads the page.
        get autoRefreshOnNetworkChange() { return false; },
        set autoRefreshOnNetworkChange(_) {},
        get chainId() { return chainId; },
        get selectedAddress() { return accounts[0] || null; },
        isConnected: () => connected,
        async request(args) {
          if (!args || typeof args.method !== 'string' || args.method.length > 80) throw failure(-32600, 'Invalid request.');
          if (document.readyState === 'loading') await new Promise(resolve => document.addEventListener('DOMContentLoaded', resolve, {once: true}));
          if (!documentID) documentID = await bridge('oath_document', [], null);
          const result = await bridge(args.method, args.params ?? [], documentID);
          if (args.method === 'eth_requestAccounts' || args.method === 'eth_accounts') {
            if (JSON.stringify(accounts) !== JSON.stringify(result)) { accounts = result; emit('accountsChanged', accounts); }
          }
          if (args.method === 'eth_chainId') chainId = result;
          return result;
        },
        on(event, listener) {
          if (typeof event !== 'string' || event.length > 80 || (listeners.size >= 32 && !listeners.has(event))) throw new TypeError('Invalid event.');
          if (typeof listener !== 'function') throw new TypeError('A listener is required.');
          if (!listeners.has(event)) listeners.set(event, new Set());
          if (listeners.get(event).size < 100) listeners.get(event).add(listener);
          return provider;
        },
        removeListener(event, listener) { listeners.get(event)?.delete(listener); return provider; },
        enable() { return provider.request({method: 'eth_requestAccounts'}); },
        sendAsync(payload, callback) {
          provider.request(payload).then(result => callback(null, {id: payload.id, jsonrpc: '2.0', result}),
            error => callback(error, {id: payload.id, jsonrpc: '2.0', error: {code: error.code, message: error.message}}));
        },
        send(method, params) {
          if (typeof method === 'string') return provider.request({method, params});
          if (typeof params === 'function') return provider.sendAsync(method, params);
          return provider.request(method);
        }
      };
      window.addEventListener('oath:state', event => {
        const state = event.detail;
        if (!state || !Array.isArray(state.accounts) || typeof state.chainId !== 'string') return;
        if (chainId !== state.chainId) { chainId = state.chainId; emit('chainChanged', chainId); }
        if (JSON.stringify(accounts) !== JSON.stringify(state.accounts)) { accounts = state.accounts; emit('accountsChanged', accounts); }
        const next = !!state.connected;
        const previous = connected; connected = next;
        if (next && !previous) emit('connect', {chainId});
        if (!next && previous) emit('disconnect', failure(4900, 'Disconnected from Oath.'));
      });
      Object.freeze(provider);
      Object.defineProperty(window, 'oath', {value: provider, configurable: false});
      if (!window.ethereum) Object.defineProperty(window, 'ethereum', {value: provider, configurable: false});
      const icon = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#294ce7"/><g fill="none" stroke="white" stroke-width="6"><circle cx="24" cy="32" r="14"/><circle cx="40" cy="32" r="14"/></g></svg>');
      const info = Object.freeze({uuid: crypto.randomUUID(), name: 'Oath Wallet', icon, rdns: 'org.oathwallet'});
      const detail = Object.freeze({info, provider});
      const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {detail}));
      window.addEventListener('eip6963:requestProvider', announce);
      announce();
    })();
    """#
}
