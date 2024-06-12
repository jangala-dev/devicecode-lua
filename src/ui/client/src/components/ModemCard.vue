<template>
  <div class="card">
    <div class="card-header" :class="{ 'card-header-inactive': !props.is_online }">
      <div class="signal-icon" :class="'bars' + props.modem.bars">
        <div class="signal-bar" />
        <div class="signal-bar" />
        <div class="signal-bar" />
        <div class="signal-bar" />
        <div class="signal-bar" />
        <div class="signal-overlay">{{ props.modem.access_fam }}</div>
      </div>
    </div>

    <div class="card-content">
      <h5 class="card-title">{{ convertName(props.name) }}</h5>
      <div class="card-context">
        <p>operator: {{ props.modem.operator }}</p>
        <p>sim: {{ props.modem.sim == "error: no-atr-received (3)" ? "error: no sim detected" : props.modem.sim }}</p>
        <p>state: {{ props.modem.state }}</p>
        <p v-for="(tech_score) in filteredModemSignal(props.modem)" :key="tech_score.tech">
          {{ tech_score.type }}: {{ tech_score.value }}
        </p>
        <p>access tech: {{ props.modem.access_fam }} ({{ props.modem.access_tech }})</p>
        <p>band: {{ props.modem.band }}</p>
        <p>wann type: {{ props.modem.wann_type }}</p>
        <p>status: {{ props.is_online ? "online" : "offline" }}</p>
        <p>imei: {{ props.modem.imei }}</p>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { defineProps } from 'vue';
import { Modem, Signal } from '@/types/types';

const props = withDefaults(defineProps<{
  is_online: boolean,
  name: string,
  modem: Modem,
}>(), {
  is_online: false,
  name: '',
  modem: () => new Modem(),
});

// Functions
const convertName = (name: string): string => {
  return name == 'modem1' ? 'modem 1 (primary)' : name == 'modem2' ? 'modem 2 (backup)' : name;
};

const filteredModemSignal = (modem: Modem): Signal[] => {
  if (!modem.signal) {
    return [];
  }

  return modem.signal
    .filter(s => s.tech == modem.access_tech)
    .sort((a,b) => (a.tech > b.tech) ? 1 : ((b.tech > a.tech) ? -1 : 0));
};
</script>

<style lang="scss">
/* Lightly adapted from https://hungyi.net/posts/pure-css-signal-indicator/ */
.signal-overlay {
  position: absolute;
  top: 0;
  left: 0;
  color: #ffffff;
  font-size: 20px;
}

.signal-icon {
  margin: auto;
  height: 50%;
  width: 50%;
  /* Flexbox! */
  display: flex;
  /* Bars should be placed left to right */
  flex-direction: row;
  /* Evenly space the bars with space in between */
  justify-content: space-between;
  /* Sink the bars to the bottom, so they go up in steps */
  align-items: baseline;
  position: relative;
}

.signal-icon .signal-bar {
  /* 4 + 3 + 4 + 3 + 4 = 18px (as set above)
     4px per bar and 3px margins between */
  width: 12px;
  /* All bars faded by default */
  opacity: 0.15;
  /* Choose a color */
  background: #ffffff;
}

/* 5 different heights for 5 different bars */
.signal-icon .signal-bar:nth-child(1) {
  height: 20%;
}

.signal-icon .signal-bar:nth-child(2) {
  height: 40%;
}

.signal-icon .signal-bar:nth-child(3) {
  height: 60%;
}

.signal-icon .signal-bar:nth-child(4) {
  height: 80%;
}

.signal-icon .signal-bar:nth-child(5) {
  height: 100%;
}

/* Emphasize different bars depending on
   weak/medium/strong classes */
.signal-icon.bars1 .signal-bar:nth-child(1),
.signal-icon.bars2 .signal-bar:nth-child(1),
.signal-icon.bars2 .signal-bar:nth-child(2),
.signal-icon.bars3 .signal-bar:nth-child(1),
.signal-icon.bars3 .signal-bar:nth-child(2),
.signal-icon.bars3 .signal-bar:nth-child(3),
.signal-icon.bars4 .signal-bar:nth-child(1),
.signal-icon.bars4 .signal-bar:nth-child(2),
.signal-icon.bars4 .signal-bar:nth-child(3),
.signal-icon.bars4 .signal-bar:nth-child(4),
.signal-icon.bars5 .signal-bar:nth-child(1),
.signal-icon.bars5 .signal-bar:nth-child(2),
.signal-icon.bars5 .signal-bar:nth-child(3),
.signal-icon.bars5 .signal-bar:nth-child(4),
.signal-icon.bars5 .signal-bar:nth-child(5) {
  opacity: 1;
}</style>