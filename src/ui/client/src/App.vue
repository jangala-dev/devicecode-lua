<template>
  <div class="main-bg h-screen" :class="{ dark: darkMode }">
    <router-view />
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeMount } from 'vue';
import { useSettingsStore } from '@/stores/settings';

// Store
const settingsStore = useSettingsStore();

// Computed
const darkMode = computed(() => settingsStore.darkMode);

// Vue Lifecycle Functions
onBeforeMount(() => {
  settingsStore.toggleDarkMode(document.querySelector('body'));
});
</script>

<style lang="scss">
</style>
