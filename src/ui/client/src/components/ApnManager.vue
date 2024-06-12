<template>
  <div class="bg-card">
    <h3 class="header">APNs</h3>
    <p class="card-text">
      An Access Point Name (APN) provides the details your box needs to connect to mobile data when using a SIM card.
      APNs may be different depending on the region, internet service provider, and internet contract types.
      Jangala's boxes come pre-loaded with the APN details of common service providers.
      However, if the APN details of your service provider are not included, you will need to add them using the form
      below.
      If you are unsure of how to use this form, please reach out to Jangala through your normal support channels for
      assistance.
    </p>
  </div>
  <div class="bg-card">
    <div>
      <h3 class="header">Custom APNs</h3>
      <span class="card-text">APNs previously added to this device will appear here</span>
      <h4 v-if="updatingApns" class="text-center text-xl dark:text-white my-3"> Loading...</h4>
    </div>
    <table class="list-table">
      <thead class="list-table-head">
        <tr>
          <th class="p-2">Carrier</th>
          <th class="p-2">MCC</th>
          <th class="p-2">MNC</th>
          <th class="p-2">APN</th>
        </tr>
      </thead>
      <tbody class="list-table-tbody">
        <tr v-for="(apn, index) in apns" :key="index" class="list-table-tr">
          <td class="p-2">{{ apn.carrier }}</td>
          <td class="p-2">{{ apn.mcc }}</td>
          <td class="p-2">{{ apn.mnc }}</td>
          <td class="p-2">{{ apn.apn }}</td>
          <button class="btn" @click="showFullApnDetails(apn)">
            Details
          </button>
          <button :class="updatingApns ? 'btn-disabled' : 'btn'" :disabled="updatingApns" @click="removeApn(index)">
            Remove
          </button>
        </tr>
      </tbody>
    </table>
  </div>
  <div class="bg-card">
    <div>
      <h3 class="header">Add APN</h3>
    </div>
    <div class="flex flex-row flex-wrap space-x-4 space-y-4">
      <br />
      <input v-model="apnForm.carrier" type="text" placeholder="Carrier" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.mcc" type="text" placeholder="MCC" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.mnc" type="text" placeholder="MNC" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.apn" type="text" placeholder="APN" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.type" type="text" placeholder="Type" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.protocol" type="text" placeholder="Protocol" class="dark:text-white dark:bg-gray-700" />
      <input
        v-model="apnForm.roaming_protocol" type="text" placeholder="Roaming Protocol"
        class="dark:text-white dark:bg-gray-700"
      />
      <input
        v-model="apnForm.user_visible" type="text" placeholder="User Visible"
        class="dark:text-white dark:bg-gray-700"
      />
      <input v-model="apnForm.authtype" type="text" placeholder="Auth Type" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.mmsc" type="text" placeholder="MMSC" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.mmsproxy" type="text" placeholder="MMS Proxy" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.mmsport" type="text" placeholder="MMS Port" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.proxy" type="text" placeholder="Proxy" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.port" type="text" placeholder="Port" class="dark:text-white dark:bg-gray-700" />
      <input
        v-model="apnForm.bearer_bitmask" type="text" placeholder="Bearer Bitmask"
        class="dark:text-white dark:bg-gray-700"
      />
      <input v-model="apnForm.read_only" type="text" placeholder="Read Only" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.user" type="text" placeholder="User" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.password" type="text" placeholder="Password" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.mvno_type" type="text" placeholder="MVNO Type" class="dark:text-white dark:bg-gray-700" />
      <input
        v-model="apnForm.mvno_match_data" type="text" placeholder="MVNO Match Data"
        class="dark:text-white dark:bg-gray-700"
      />
      <input v-model="apnForm.mtu" type="text" placeholder="MTU" class="dark:text-white dark:bg-gray-700" />
      <input
        v-model="apnForm.ppp_number" type="text" placeholder="PPP Number"
        class="dark:text-white dark:bg-gray-700"
      />
      <input
        v-model="apnForm.vivoentry" type="text" placeholder="VIVO Entry"
        class="dark:text-white dark:bg-gray-700"
      />
      <input v-model="apnForm.server" type="text" placeholder="Server" class="dark:text-white dark:bg-gray-700" />
      <input
        v-model="apnForm.localized_name" type="text" placeholder="Localized Name"
        class="dark:text-white dark:bg-gray-700"
      />
      <input
        v-model="apnForm.visit_area" type="text" placeholder="Visit Area"
        class="dark:text-white dark:bg-gray-700"
      />
      <input v-model="apnForm.bearer" type="text" placeholder="Bearer" class="dark:text-white dark:bg-gray-700" />
      <input
        v-model="apnForm.profile_id" type="text" placeholder="Profile ID"
        class="dark:text-white dark:bg-gray-700"
      />
      <input
        v-model="apnForm.modem_cognitive" type="text" placeholder="Modem Cognitive"
        class="dark:text-white dark:bg-gray-700"
      />
      <input v-model="apnForm.max_conns" type="text" placeholder="Max Conns" class="dark:text-white dark:bg-gray-700" />
      <input
        v-model="apnForm.max_conns_time" type="text" placeholder="Max Conns Time"
        class="dark:text-white dark:bg-gray-700"
      />
      <input
        v-model="apnForm.skip_464xlat" type="text" placeholder="Skip 464XLAT"
        class="dark:text-white dark:bg-gray-700"
      />
      <input
        v-model="apnForm.carrier_enabled" type="text" placeholder="Carrier Enabled"
        class="dark:text-white dark:bg-gray-700"
      />
      <input v-model="apnForm.mtusize" type="text" placeholder="MTU Size" class="dark:text-white dark:bg-gray-700" />
      <input v-model="apnForm.auth" type="text" placeholder="Auth" class="dark:text-white dark:bg-gray-700" />
    </div>
    <div class="pt-4">
      <button :disabled="updatingApns" :class="updatingApns ? 'btn-disabled' : 'btn'" @click="submitApn()">
        Add APN
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { Ref, ref, onMounted } from 'vue';
import { useConfigStore } from '@/stores/config';
import { Apn } from '@/types/types';

// Store
const configStore = useConfigStore();

// Variables
const apns: Ref<Apn[]> = ref([]);
const updatingApns = ref(true);
const apnForm = ref(new Apn());

// Vue Lifecycle Functions
onMounted(() => {
  fetchApns();
});

// Functions
const fetchApns = async () => {
  updatingApns.value = true;
  const resp = await configStore.getApns();
  apns.value = !resp ? [] : resp;
  updatingApns.value = false;
};

const submitApn = async (): Promise<void> => {
  updatingApns.value = true;
  sanitiseApnSubmission();

  if (!validateApnSubmission()) {
    alert('Carrier, MCC, MNC and APN fields must be non-empty to set a new APN');
    updatingApns.value = false;
    return;
  }

  if (apnSubmissionIsDuplicate()) {
    alert('APNs must have a unique combination of Carrier, MCC, MNC and APN values');
    updatingApns.value = false;
    return;
  }

  const newApn = apnForm.value;
  const success = await configStore.updateApns(JSON.stringify(apns.value.concat(newApn)));

  if (success) {
    fetchApns();
    apnForm.value = new Apn();
  }

  updatingApns.value = false;
};

const removeApn = async (index: number): Promise<void> => {
  updatingApns.value = true;

  if (confirm('Are you sure you want to delete this APN?')) {
    const updatedApns = apns.value.slice(0);
    updatedApns.splice(index, 1);
    const success = await configStore.updateApns(JSON.stringify(updatedApns));
    if (success) {
      fetchApns();
    }
  }

  updatingApns.value = false;
};

const validateApnSubmission = (): boolean => {
  return apnForm.value.carrier && !apnForm.value.mcc && !apnForm.value.mnc && !apnForm.value.apn;
};

const apnSubmissionIsDuplicate = (): boolean => {
  for (let a of apns.value) {
    if (
      a.carrier === apnForm.value.carrier && a.mcc === apnForm.value.mcc
      && a.mnc === apnForm.value.mnc && a.apn === apnForm.value.apn
    ) {
      return true;
    }
  }

  return false;
};

const sanitiseApnSubmission = (): void => {
  Object.entries(apnForm.value).forEach(([key, value]) => {
    if (value && (value as string).trim().length === 0) {
      Object.assign(apnForm.value, { [key]: undefined });
    }
  });
};

const showFullApnDetails = (apn: Apn): void => {
  alert(JSON.stringify(apn));
};
</script>

<style lang="scss" scoped></style>
