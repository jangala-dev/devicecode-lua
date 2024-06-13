import { createRouter, createWebHistory, RouteRecordRaw } from 'vue-router';
import Dashboard from '../views/Dashboard.vue';
import ConfigManagement from '@/components/ConfigManagement.vue';
import DeviceOverview from '@/components/DeviceOverview.vue';

const routes: Array<RouteRecordRaw> = [
  {
    path: '/',
    name: 'Dashboard',
    component: Dashboard,
    children: [
      {
        path: '/overview',
        name: 'DeviceOverview',
        component: DeviceOverview,
      },
      {
        path: '/config',
        name: 'ConfigManagement',
        component: ConfigManagement,
      },
      {
        path: '/:pathMatch(.*)*',
        redirect: '/overview',
      },
      {
        path: '',
        redirect: '/overview',
      },
    ],
  },
];

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes,
});

export default router;
