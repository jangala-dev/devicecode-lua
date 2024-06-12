import { defineStore } from 'pinia';

export const useSettingsStore = defineStore('settings', {
  state: () => ({
    darkMode: false,
  }),
  actions: {
    updateDarkMode(darkMode: boolean) {
      this.darkMode = darkMode;
    },
    toggleDarkMode(body: HTMLBodyElement) {
      const darkMode = !this.darkMode;
      localStorage.setItem('darkMode', `${darkMode}`);
      this.updateDarkMode(darkMode);

      if (this.darkMode) {
        body.classList.add('dark');
      } else {
        body.classList.remove('dark');
      }
    },
    setDarkMode(body: HTMLBodyElement) {
      const darkMode = localStorage.getItem('darkMode') === 'true';
      this.updateDarkMode(darkMode);

      if (this.darkMode) {
        body.classList.add('dark');
      } else {
        body.classList.remove('dark');
      }
    },
  },
});
