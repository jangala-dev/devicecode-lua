import { defineStore } from 'pinia';
import { Device } from '@/types/types';

export const useDeviceStore = defineStore('device', {
  state: () => ({
    device: new Device(),
    eventStreamLoaded: false,
    eventStream: new EventSource('/sse/event-stats'),
  }),
  actions: {
    setSystemState(device: Device) {
      this.device = device;
    },
    setEventStreamLoaded() {
      this.eventStreamLoaded = true;
    },
    eventSystemState() {
      if (!this.eventStream.onmessage) { // Ensure it's only set once
        this.eventStream.onmessage = (e: MessageEvent) => {
          if (!this.eventStreamLoaded) {
            this.setEventStreamLoaded();
          }

          console.log(this.device);
          const message = JSON.parse(e.data);
          console.log(message);
          // const device: Device = JSON.parse(e.data);
          // this.setSystemState(device);
        };
      }
    },
  },
});
