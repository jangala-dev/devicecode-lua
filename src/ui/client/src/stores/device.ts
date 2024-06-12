import { defineStore } from 'pinia';
import { Device, Modem, Net } from '@/types/types';

interface PayloadI {
  n: string;
  v: number;
  vs: string;
  vb: boolean;
}

interface MessageI {
  type: string;
  topic: string;
  payload: PayloadI;
}

export const useDeviceStore = defineStore('device', {
  state: () => ({
    device: new Device(),
    eventStreamLoaded: false,
    eventStream: new EventSource('/sse/event-stats'),
  }),
  actions: {
    setModemState(message: MessageI) {
      const topicArr = message.topic.split('.');
      const key = `modem${topicArr[2]}`;

      if (!(key in this.device.modems)) {
        this.device.modems[key] = new Modem();
      }

      switch(message.payload.n) {
        case "access_tech":
          this.device.modems[key].access_tech = message.payload.vs;
          break
        case "access_fam":
          this.device.modems[key].access_fam = message.payload.vs;
          break
        case "operator":
          this.device.modems[key].operator = message.payload.vs;
          break
        case "sim":
          this.device.modems[key].sim = message.payload.vs;
          break
        case "state":
          this.device.modems[key].state = message.payload.vs;
          break
        case "signal_type":
          this.device.modems[key].signal_type = message.payload.vs;
          break
        case "band":
          this.device.modems[key].band = message.payload.vs;
          break
        case "bars":
          this.device.modems[key].bars = message.payload.vs;
          break
        case "wwan_type":
          this.device.modems[key].wwan_type = message.payload.vs;
          break
        case "imei":
          this.device.modems[key].imei = message.payload.vs;
          break
        default:
          console.error(`Unknown payload name ${message.payload.n}`);
      }
    },
    setNetState(message: MessageI) {
      const topicArr = message.topic.split('.');
      const key = topicArr[2];

      if (!(key in this.device.net)) {
        this.device.net[key] = new Net();
      }

      switch (message.payload.n) {
        case "is_online":
          this.device.net[key].is_online = message.payload.vb;
          break
        case "curr_uptime":
          this.device.net[key].curr_uptime = message.payload.v;
          break
        case "total_uptime":
          this.device.net[key].total_uptime = message.payload.v;
          break
        default:
          console.error(`Unknown payload name ${message.payload.n}`);
      }
    },
    setSystemState(message: MessageI) {
      switch (message.payload.n) {
        case "cpu_util":
          this.device.system.cpu_util = message.payload.v;
          break
        case "mem_util":
          this.device.system.mem_util = message.payload.v;
          break
        case "temp":
          this.device.system.temp = message.payload.v;
          break
        case "fw_id":
          this.device.system.fw_id = message.payload.vs;
          break
        case "hw_id":
          this.device.system.hw_id = message.payload.vs;
          break
        case "serial":
          this.device.system.serial = message.payload.vs;
          break
        case "uptime":
          this.device.system.uptime = message.payload.v;
          break
        case "power":
          this.device.system.power = message.payload.vs;
          break
        case "battery":
          this.device.system.battery = message.payload.vs;
          break
        default:
          console.error(`Unknown payload name ${message.payload.n}`);
      }
    },
    setMcuState(message: MessageI) {
      switch (message.payload.n) {
        case "temp":
          this.device.mcu.temp = message.payload.v;
          break
        default:
          console.error(`Unknown payload name ${message.payload.n}`);
      }
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

          const message: MessageI = JSON.parse(e.data);

          if (message.topic.includes('modem')) {
            this.setModemState(message);
          } else if (message.topic.includes('net')) {
            this.setNetState(message);
          } else if (message.topic.includes('mcu')) {
            this.setMcuState(message);
          } else if (message.topic.includes('system') || message.topic.includes('power') || message.topic.includes('battery')) {
            this.setSystemState(message);
          } else {
            console.error(`Message topic unknown ${message.topic}`)
          }
        };
      }
    },
  },
});
