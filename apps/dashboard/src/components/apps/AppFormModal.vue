<script setup lang="ts">
import { ref, reactive, watch, computed, onMounted } from 'vue'
import { trpc } from '../../lib/trpc'
import PortsTable,      { type PortMapping }    from './PortsTable.vue'
import EnvsEditor,      { type EnvVar }         from './EnvsEditor.vue'
import VolumesTable,    { type VolumeMount, type Place } from './VolumesTable.vue'
import LabelsTable,     { type LabelEntry }     from './LabelsTable.vue'
import AdvancedSection, { type AdvancedConfig } from './AdvancedSection.vue'

type App = {
  id: string; name: string; image: string
  ports: PortMapping[]; envs: EnvVar[]; volumes: VolumeMount[]
  networkNames: string[]; labels: LabelEntry[]
  capAdd: string[]; capDrop: string[]
  restartPolicy: string
  hostname: string | null; user: string | null; command: string | null
  cpuLimit: number | null; memoryLimit: string | null
  status: string
}

const props = defineProps<{ editApp?: App | null }>()
const emit  = defineEmits<{
  close: []
  saved: [app: App]
}>()

type Tab = 'basic' | 'ports' | 'envs' | 'volumes' | 'networks' | 'labels' | 'advanced'
const tabs: { id: Tab; label: string }[] = [
  { id: 'basic',    label: 'Basic' },
  { id: 'ports',    label: 'Ports' },
  { id: 'envs',     label: 'Envs' },
  { id: 'volumes',  label: 'Volumes' },
  { id: 'networks', label: 'Networks' },
  { id: 'labels',   label: 'Labels' },
  { id: 'advanced', label: 'Advanced' },
]
const activeTab = ref<Tab>('basic')

function emptyForm() {
  return {
    name:          '',
    image:         '',
    ports:         [] as PortMapping[],
    envs:          [] as EnvVar[],
    volumes:       [] as VolumeMount[],
    networkNames:  [] as string[],
    labels:        [] as LabelEntry[],
    capAdd:        [] as string[],
    capDrop:       [] as string[],
    restartPolicy: 'no',
    hostname:      null as string | null,
    user:          null as string | null,
    command:       null as string | null,
    cpuLimit:      null as number | null,
    memoryLimit:   null as string | null,
  }
}

const form    = reactive(emptyForm())
const loading = ref(false)
const error   = ref('')

const places      = ref<Place[]>([])
const networkInput = ref('')

onMounted(async () => {
  try {
    places.value = await trpc.place.list.query() as Place[]
  } catch {}
})

watch(() => props.editApp, (app) => {
  if (app) {
    Object.assign(form, {
      name:          app.name,
      image:         app.image,
      ports:         [...app.ports],
      envs:          [...app.envs],
      volumes:       [...app.volumes],
      networkNames:  [...app.networkNames],
      labels:        [...app.labels],
      capAdd:        [...app.capAdd],
      capDrop:       [...app.capDrop],
      restartPolicy: app.restartPolicy,
      hostname:      app.hostname,
      user:          app.user,
      command:       app.command,
      cpuLimit:      app.cpuLimit,
      memoryLimit:   app.memoryLimit,
    })
  } else {
    Object.assign(form, emptyForm())
  }
  activeTab.value = 'basic'
  error.value = ''
}, { immediate: true })

const advanced = computed<AdvancedConfig>({
  get:  () => ({ capAdd: form.capAdd, capDrop: form.capDrop, restartPolicy: form.restartPolicy, hostname: form.hostname, user: form.user, command: form.command, cpuLimit: form.cpuLimit, memoryLimit: form.memoryLimit }),
  set:  (v) => { Object.assign(form, v) },
})

function addNetwork() {
  const n = networkInput.value.trim()
  if (n && !form.networkNames.includes(n)) form.networkNames.push(n)
  networkInput.value = ''
}

async function save() {
  error.value = ''
  loading.value = true
  try {
    const payload = {
      name:          form.name,
      image:         form.image,
      ports:         form.ports,
      envs:          form.envs,
      volumes:       form.volumes,
      networkNames:  form.networkNames,
      labels:        form.labels,
      capAdd:        form.capAdd,
      capDrop:       form.capDrop,
      restartPolicy: form.restartPolicy as any,
      hostname:      form.hostname,
      user:          form.user,
      command:       form.command,
      cpuLimit:      form.cpuLimit,
      memoryLimit:   form.memoryLimit,
    }
    let result: any
    if (props.editApp) {
      result = await trpc.container.app.update.mutate({ id: props.editApp.id, data: payload })
    } else {
      result = await trpc.container.app.create.mutate(payload)
    }
    emit('saved', result.app)
    emit('close')
  } catch (e: any) {
    error.value = e?.message ?? 'Failed to save'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <Teleport to="body">
    <div class="fixed inset-0 z-50 bg-black/60 backdrop-blur-sm flex items-center justify-center p-4" @click.self="emit('close')">
      <div class="bg-[#111120] border border-slate-700/60 rounded-2xl shadow-2xl w-full max-w-2xl max-h-[90vh] flex flex-col">

        <!-- Header -->
        <div class="flex items-center justify-between px-6 py-4 border-b border-slate-800">
          <h2 class="text-base font-semibold text-slate-100">
            {{ editApp ? 'Edit App' : 'New App' }}
          </h2>
          <button @click="emit('close')" class="text-slate-500 hover:text-slate-300 transition-colors">
            <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12"/>
            </svg>
          </button>
        </div>

        <!-- Tabs -->
        <div class="flex border-b border-slate-800 px-6 overflow-x-auto">
          <button
            v-for="tab in tabs" :key="tab.id"
            @click="activeTab = tab.id"
            :class="[
              'px-3 py-3 text-sm font-medium whitespace-nowrap border-b-2 transition-colors',
              activeTab === tab.id
                ? 'border-blue-500 text-blue-400'
                : 'border-transparent text-slate-500 hover:text-slate-300',
            ]"
          >{{ tab.label }}</button>
        </div>

        <!-- Content -->
        <div class="flex-1 overflow-y-auto px-6 py-5">

          <!-- Basic -->
          <div v-if="activeTab === 'basic'" class="space-y-4">
            <div class="space-y-1.5">
              <label class="text-xs font-medium text-slate-400 uppercase tracking-wide">Container name *</label>
              <input
                v-model="form.name" placeholder="my-app" :disabled="!!editApp"
                class="w-full bg-[#0a0a14] border border-slate-700/60 rounded-lg px-3 py-2 text-sm text-slate-200 focus:outline-none focus:border-blue-500/60 disabled:opacity-50"
              />
            </div>
            <div class="space-y-1.5">
              <label class="text-xs font-medium text-slate-400 uppercase tracking-wide">Image *</label>
              <input
                v-model="form.image" placeholder="nginx:alpine"
                class="w-full bg-[#0a0a14] border border-slate-700/60 rounded-lg px-3 py-2 text-sm font-mono text-slate-200 focus:outline-none focus:border-blue-500/60"
              />
            </div>
          </div>

          <!-- Ports -->
          <div v-else-if="activeTab === 'ports'">
            <PortsTable v-model="form.ports" />
          </div>

          <!-- Envs -->
          <div v-else-if="activeTab === 'envs'">
            <EnvsEditor v-model="form.envs" />
          </div>

          <!-- Volumes -->
          <div v-else-if="activeTab === 'volumes'">
            <VolumesTable v-model="form.volumes" :places="places" />
          </div>

          <!-- Networks -->
          <div v-else-if="activeTab === 'networks'" class="space-y-3">
            <p class="text-xs text-slate-500">Enter Docker network names to attach (e.g. <span class="font-mono">bridge</span>, <span class="font-mono">host</span>, or a custom network).</p>
            <div class="flex gap-2">
              <input
                v-model="networkInput" placeholder="network-name"
                @keydown.enter.prevent="addNetwork"
                class="flex-1 bg-[#0a0a14] border border-slate-700/60 rounded-lg px-2 py-1.5 text-sm font-mono text-slate-200 focus:outline-none focus:border-blue-500/60"
              />
              <button
                @click="addNetwork"
                class="px-3 py-1.5 bg-blue-600/20 text-blue-400 rounded-lg text-sm hover:bg-blue-600/30 transition-colors"
              >Add</button>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <span
                v-for="n in form.networkNames" :key="n"
                class="inline-flex items-center gap-1 text-xs bg-blue-600/15 text-blue-300 border border-blue-500/20 rounded px-2 py-0.5 font-mono"
              >
                {{ n }}
                <button @click="form.networkNames = form.networkNames.filter(x => x !== n)" class="hover:text-blue-100 ml-1">×</button>
              </span>
              <span v-if="form.networkNames.length === 0" class="text-xs text-slate-600">No networks attached.</span>
            </div>
          </div>

          <!-- Labels -->
          <div v-else-if="activeTab === 'labels'">
            <LabelsTable v-model="form.labels" />
          </div>

          <!-- Advanced -->
          <div v-else-if="activeTab === 'advanced'">
            <AdvancedSection v-model="advanced" />
          </div>

        </div>

        <!-- Footer -->
        <div class="px-6 py-4 border-t border-slate-800 flex items-center justify-between">
          <p v-if="error" class="text-sm text-red-400">{{ error }}</p>
          <div v-else />
          <div class="flex gap-2">
            <button
              @click="emit('close')"
              class="px-4 py-2 text-sm text-slate-400 hover:text-slate-200 transition-colors"
            >Cancel</button>
            <button
              @click="save" :disabled="loading || !form.name || !form.image"
              class="px-4 py-2 text-sm bg-blue-600 text-white rounded-lg hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              {{ loading ? 'Saving…' : 'Save' }}
            </button>
          </div>
        </div>

      </div>
    </div>
  </Teleport>
</template>
