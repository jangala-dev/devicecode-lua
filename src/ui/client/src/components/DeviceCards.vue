<template>
  <div>
    <h3 v-if="!eventStreamLoaded" class="text-center text-xl dark:text-white my-3">Waiting for data...</h3>

    <div class="cards">
      <div class="card">
        <div class="card-header" :class="{ 'card-header-inactive': !internetOnline }">
          <div class="sphwrapper">
            <div class="sphere" :class="{ rotate: internetOnline }">
              <div v-for="index in 8" :key="index" :style="{ transform: `rotateY(${(360 / 8) * index}deg)` }" />
            </div>
          </div>
        </div>

        <div class="card-content">
          <h5 class="card-title">internet {{ internetOnline ? "online" : "offline" }}</h5>
          <div class="card-context">
            <!-- TODO how do we guarantee display in correct order -->
            <div v-for="(net, netInterface) in device.net" :key="netInterface">
              <p>
                {{ convertNetInterface(netInterface) }}
                {{ net.is_online ? `online for ${secondsToDhms(net.curr_uptime)}` : "offline" }}
              </p>
            </div>
          </div>
        </div>
      </div>

      <!-- TODO how do we guarantee display in correct order -->
      <ModemCard v-for="(modem, index) in orderedModems" :key="index" :modem="modem" :name="'modem' + (index + 1)"
        :is_online="device.net?.[modem.wwan_type]?.is_online ?? false" />

      <div class="card">
        <div class="card-header">
          <div class="tech-text">{{ device.system.temp ? device.system.temp : "--" }}</div>
          <div class="tech-text"><sup>&#8451;</sup></div>
        </div>

        <div class="card-content">
          <h5 class="card-title">system</h5>
          <div class="card-context">
            <p>hardware: {{ device.system.hw_id }}</p>
            <p>firmware: {{ device.system.fw_id }}</p>
            <p>serial: {{ device.system.serial }}</p>
            <p>cpu load: {{ device.system.cpu_util }}%</p>
            <p>memory load: {{ device.system.mem_util }}%</p>
            <p>power: {{ device.system.power }}</p>
            <p>battery: {{ device.system.battery }}</p>
            <p>mcu temp: {{ device.mcu.temp }}%</p>
            <!-- <p>bootloader: {{ system.stats.blid }}</p> -->
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ComputedRef, computed, onMounted } from 'vue';
import { useDeviceStore } from '@/stores/device';
import ModemCard from '@/components/ModemCard.vue';
import { Device, Modem } from '@/types/types';

// Store
const deviceStore = useDeviceStore();

// Computed
const device: ComputedRef<Device> = computed(() => deviceStore.device);
const eventStreamLoaded: ComputedRef<boolean> = computed(() => deviceStore.eventStreamLoaded);
const internetOnline: ComputedRef<boolean> = computed(() => Object.values(device.value.net).some(net => net.is_online));
const orderedModems: ComputedRef<Modem[]> = computed(() => {
  const sorted = Object.keys(device.value.modems)
    .sort()  // Sort the keys in alphabetical order
    .map(key => device.value.modems[key]);
  return sorted;
});

// Vue Lifecycle Functions
onMounted(() => {
  deviceStore.eventSystemState();
});

// Functions
const convertNetInterface = (netInterface: string): string => {
  // TODO think of cleaner way to do this
  const reverseLookup: Record<string, string> = {
    'wan': 'wired',
    'wwan': 'modem 1',
    'wwanb': 'modem 2',
  };

  return reverseLookup[netInterface] ?? netInterface;
};

const secondsToDhms = (seconds: number) => {
  seconds = Number(seconds);
  const d = Math.floor(seconds / (3600 * 24)),
    h = Math.floor(seconds % (3600 * 24) / 3600),
    m = Math.floor(seconds % 3600 / 60),
    s = Math.floor(seconds % 60);
  const dDisplay = d > 0 ? d + 'd:' : '',
    hDisplay = h > 0 ? h + 'h:' : '',
    mDisplay = m > 0 ? m + 'm:' : '',
    sDisplay = s > 0 ? s + 's' : '';


  return (dDisplay + hDisplay + mDisplay + sDisplay).replace(/:\s*$/, '');
};
</script>

<style lang="scss">
.toggle-checkbox:checked {
  right: 0;
}

:root {
  font-family: sans-serif;
  font-weight: light;
}

.tech-text {
  font-variant-numeric: tabular-nums;
  font-size: 60px;
}
/* Lightly adapted from https://codepen.io/chris22smith/pen/LGeVzz */
.sphwrapper {
  display: flex;
  height: 100%;
  width: 100%;
  perspective: 800px;
  perspective-origin: 0% 0px;
}

.sphere {
  margin: auto;
  width: 75px;
  height: 75px;
  transform-style: preserve-3d;
}

.sphere > div {
  border: dashed 3px #ffffff;
  border-radius: 50%;
  height: 75px;
  opacity: 1;
  position: absolute;
  width: 75px;
}

@keyframes spinGlobe {
  0% {
    transform: rotateX(23deg) rotateY(0) rotateZ(0deg);
  }
  50% {
    transform: rotateX(0deg) rotateY(180deg) rotateZ(23deg);
  }
  100% {
    transform: rotateX(23deg) rotateY(360deg) rotateZ(0deg);
  }
}

.rotate {
  animation: spinGlobe 30s infinite linear;
}
</style>
