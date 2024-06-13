<template>
  <div>
    <DeviceCards :device="device" :event-stream-loaded="eventStreamLoaded" :internet-online="internetOnline" />

    <Logs />
  </div>
</template>

<script setup lang="ts">
import { ComputedRef, computed, onMounted } from 'vue';
import { Device, Net } from '@/types/types';
import DeviceCards from '@/components/DeviceCards.vue';
import Logs from './Logs.vue';
import { useDeviceStore } from '@/stores/device';

// Store
const deviceStore = useDeviceStore();

// Computed
const device: ComputedRef<Device> = computed(() => deviceStore.device);
const eventStreamLoaded: ComputedRef<boolean> = computed(() => deviceStore.eventStreamLoaded);
const internetOnline: ComputedRef<boolean> = computed(() => {
  return Object.values(device.value.net as Record<string, Net>).some(net => net.is_online);
});

// Vue Lifecycle Functions
onMounted(() => {
  deviceStore.eventSystemState();
});
</script>

<style lang="css"></style>