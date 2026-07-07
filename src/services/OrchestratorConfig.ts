// src/services/OrchestratorConfig.ts
//
// Tiny shared config bridge between the React settings layer and the plain
// `mobileOrchestrator` singleton. Mirrors the existing pattern where
// SettingsContext pushes state into non-React singletons (e.g.
// `iOSTts.setSpeechRate`). This lets the orchestrator branch on in-device mode
// WITHOUT threading a flag through every sendToWorkflow() call site.

export interface OrchestratorRuntimeConfig {
  /**
   * When true, the orchestrator resolves everything locally (Groq/Apple FM
   * intent → native ARKit reaching/navigation) and NEVER calls the backend
   * workflow. When false, the existing hybrid (local-first, backend-fallback)
   * behavior is preserved unchanged.
   */
  inDeviceMode: boolean;
}

const config: OrchestratorRuntimeConfig = {
  inDeviceMode: false,
};

export const orchestratorConfig = {
  get inDeviceMode(): boolean {
    return config.inDeviceMode;
  },
  setInDeviceMode(value: boolean): void {
    if (config.inDeviceMode !== value) {
      config.inDeviceMode = value;
      console.log(`[OrchestratorConfig] inDeviceMode → ${value ? 'ON (local-only)' : 'OFF (backend)'}`);
    }
  },
  snapshot(): OrchestratorRuntimeConfig {
    return { ...config };
  },
};