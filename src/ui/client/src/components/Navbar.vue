<template>
  <div class="navbar">
    <a class="main-header" href="#jangala">Jangala</a>

    <router-link to="/overview">
      <button class="btn">Home</button>
    </router-link>
    <router-link to="/config">
      <button class="btn">Configuration</button>
    </router-link>


    <div class="mode-div">
      <div class="toggle-div">
        <input type="checkbox" :checked="darkMode" class="toggle toggle-checkbox" @click="toggleDarkMode()" />
        <label for="toggle" class="toggle-label" />
      </div>

      <img :src="darkMode ? darkThemeImage : lightThemeImage" />
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { useSettingsStore } from '@/stores/settings';
import darkThemeImage from '../assets/dark.svg';
import lightThemeImage from '../assets/light.svg';

// Store
const settingsStore = useSettingsStore();

// Computed
const darkMode = computed(() => settingsStore.darkMode);

// Functions
const toggleDarkMode = (): void => {
  settingsStore.toggleDarkMode(document.querySelector('body'));
};
</script>

<style lang="scss" scoped></style>
