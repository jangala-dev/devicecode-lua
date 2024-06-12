import { defineStore } from 'pinia';
import { Apn } from '@/types/types';

export const useConfigStore = defineStore('config', {
  actions: {
    async getApns(): Promise<Apn[]> {
      const get_options = {
        method: 'GET',
        headers: {
          'Content-Type': 'application/json',
        },
      };

      // TODO put into try / catch
      const resp = await fetch('/api/user-config/default/apns', get_options);
      if (!resp.ok) {
        const error = await resp.json().catch(() => 'Error while fetching APNs');
        alert(`Error while fetching APNs: ${error.err || error}`);
        return [];
      }
      return resp.json(); // Assuming the server returns an array of Apn objects
    },
    async updateApns(body: string): Promise<boolean> {
      const put_options = {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
        },
        body: body,
      };

      // TODO put into try / catch
      const resp = await fetch('/api/user-config/default/apns', put_options);
      if (!resp.ok) {
        const error = await resp.json().catch(() => 'Error while updating APNs');
        alert(`Error while updating APNs: ${error.err || error}`);
      }
      return resp.ok;
    },
  },
});
