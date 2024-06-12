import { defineStore } from 'pinia';

export const useLogsStore = defineStore('logs', {
  state: () => ({
    logs: [] as any[],
    eventStream: null, // EventSource setup
  }),
  actions: {
    addLogs(logs: any[]) {
      this.logs.push(...logs);
    },
    eventStreamLogs() {
      if (!this.eventStream.onmessage) { // Check to ensure setup once
        this.eventStream.onmessage = (e: MessageEvent) => {
          const logs = JSON.parse(e.data);
          if (logs && logs.length > 0) {
            this.addLogs(logs);
          }
        };
      }
    },
  },
});
