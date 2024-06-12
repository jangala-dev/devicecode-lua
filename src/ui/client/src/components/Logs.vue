<template>
  <div>
    <div class="text-center">
      <button class="btn" @click="showLogs = !showLogs">
        <span v-if="!showLogs">Show logs</span>
        <span v-else>Hide logs</span>
      </button>
    </div>

    <div v-if="showLogs" class="logs-div">
      <div v-if="logs.length > 0">
        <div class="flex justify-center mb-2">
          <button :class="logTypes[LOG_TYPE.TRACE] ? 'btn-selected' : 'btn'" @click="updateLogType(LOG_TYPE.TRACE)">
            {{ LOG_TYPE.TRACE }}
          </button>
          <button :class="logTypes[LOG_TYPE.INFO] ? 'btn-selected' : 'btn'" @click="updateLogType(LOG_TYPE.INFO)">
            {{ LOG_TYPE.INFO }}
          </button>
          <button :class="logTypes[LOG_TYPE.ERROR] ? 'btn-selected' : 'btn'" @click="updateLogType(LOG_TYPE.ERROR)">
            {{ LOG_TYPE.ERROR }}
          </button>
          <button :class="logTypes[LOG_TYPE.WARN] ? 'btn-selected' : 'btn'" @click="updateLogType(LOG_TYPE.WARN)">
            {{ LOG_TYPE.WARN }}
          </button>
        </div>
        <p v-for="(log, i) in filteredLogs" :key="i">{{ log }}</p>
      </div>
      <div v-else>
        <p>No logs</p>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ComputedRef, Ref, ref, computed, onMounted } from 'vue';
import { useLogsStore } from '@/stores/logs';
import { LogTypes, LOG_TYPE } from '@/types/types';

// Store
const logsStore = useLogsStore();

// Computed
const logs: ComputedRef<string[]> = computed(() => logsStore.logs);
const filteredLogs: ComputedRef<string[]> = computed(() => {
  // If all log types selected show all logs
  const vals = Object.values(logTypes.value), showAll = vals.every(v => !v);

  if (showAll) return logs.value;

  // Filter only selected log types
  const filtered = logs.value.filter((log: string) => {
    for(const logType in logTypes.value) {
      if (logTypes.value[logType] && log.includes(logType)) {
        return true;
      }
    }

    return false;
  });

  return filtered;
});

// Variables
const showLogs = ref(false);
const logTypes: Ref<LogTypes> = ref(new LogTypes());

// Vue Lifecycle Functions
onMounted(() => {
  // logsStore.eventStreamLogs();
});

// Functions
const updateLogType = (logType: LOG_TYPE): void => {
  logTypes.value[logType] = !logTypes.value[logType];
};
</script>

<style lang="scss" scoped></style>
