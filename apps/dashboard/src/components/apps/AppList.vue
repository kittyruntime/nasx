<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { trpc } from '../../lib/trpc'
import AppFormModal from './AppFormModal.vue'

type App = {
  id: string; name: string; image: string; status: string
  ports: Array<{ hostPort: number; containerPort: number; protocol: string }>
  envs: any[]; volumes: any[]; networkNames: string[]; labels: any[]
  capAdd: string[]; capDrop: string[]; restartPolicy: string
  hostname: string | null; user: string | null; command: string | null
  cpuLimit: number | null; memoryLimit: string | null
}

const apps     = ref<App[]>([])
const loading  = ref(true)
const showModal = ref(false)
const editApp   = ref<App | null>(null)
const actionLoading = ref<Record<string, string>>({})  // id → action

async function load() {
  loading.value = true
  try {
    apps.value = await trpc.container.app.list.query() as App[]
  } catch (e: any) {
    console.error('Failed to load apps:', e.message)
  } finally {
    loading.value = false
  }
}

onMounted(load)

function statusColor(status: string) {
  switch (status) {
    case 'running': return 'bg-emerald-500'
    case 'stopped': return 'bg-slate-500'
    case 'error':   return 'bg-red-500'
    default:        return 'bg-amber-500'
  }
}

function portsSummary(app: App): string {
  if (!app.ports.length) return '—'
  return app.ports.slice(0, 3).map(p => `${p.hostPort}:${p.containerPort}`).join(', ')
    + (app.ports.length > 3 ? ` +${app.ports.length - 3}` : '')
}

async function runAction(id: string, action: 'start' | 'stop' | 'restart' | 'delete') {
  actionLoading.value[id] = action
  try {
    if (action === 'delete') {
      if (!confirm('Delete this app? The container will be removed.')) return
      await trpc.container.app.delete.mutate({ id })
      apps.value = apps.value.filter(a => a.id !== id)
      return
    }
    await (trpc.container.app[action as 'start' | 'stop' | 'restart'] as any).mutate({ id })
    // Optimistic status
    const app = apps.value.find(a => a.id === id)
    if (app) {
      app.status = action === 'start' ? 'running' : action === 'stop' ? 'stopped' : 'unknown'
    }
  } catch (e: any) {
    alert(e.message ?? `Failed: ${action}`)
  } finally {
    delete actionLoading.value[id]
  }
}

function openNew() {
  editApp.value = null
  showModal.value = true
}

function openEdit(app: App) {
  editApp.value = app
  showModal.value = true
}

function onSaved(app: App) {
  const idx = apps.value.findIndex(a => a.id === app.id)
  if (idx !== -1) apps.value[idx] = app
  else apps.value.push(app)
}
</script>

<template>
  <div class="flex flex-col h-full">
    <!-- Toolbar -->
    <div class="flex items-center justify-between px-6 py-4 border-b border-slate-800/50">
      <h3 class="text-sm font-semibold text-slate-200">Apps</h3>
      <button
        @click="openNew"
        class="flex items-center gap-1.5 px-3 py-1.5 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-500 transition-colors"
      >
        <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4"/>
        </svg>
        New App
      </button>
    </div>

    <!-- Table -->
    <div class="flex-1 overflow-y-auto">
      <div v-if="loading" class="flex items-center justify-center h-full text-slate-500 text-sm">Loading…</div>

      <div v-else-if="apps.length === 0" class="flex flex-col items-center justify-center h-full gap-3 text-slate-600">
        <svg class="w-12 h-12 opacity-30" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1">
          <path stroke-linecap="round" stroke-linejoin="round" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10"/>
        </svg>
        <p class="text-sm">No apps yet. Create one to get started.</p>
      </div>

      <table v-else class="w-full text-sm">
        <thead>
          <tr class="border-b border-slate-800/50">
            <th class="text-left px-6 py-2.5 text-xs font-medium text-slate-500 uppercase tracking-wide w-4">Status</th>
            <th class="text-left px-3 py-2.5 text-xs font-medium text-slate-500 uppercase tracking-wide">Name</th>
            <th class="text-left px-3 py-2.5 text-xs font-medium text-slate-500 uppercase tracking-wide">Image</th>
            <th class="text-left px-3 py-2.5 text-xs font-medium text-slate-500 uppercase tracking-wide">Ports</th>
            <th class="px-6 py-2.5 text-xs font-medium text-slate-500 uppercase tracking-wide text-right">Actions</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-slate-800/40">
          <tr v-for="app in apps" :key="app.id" class="hover:bg-slate-800/20 transition-colors">
            <!-- Status -->
            <td class="px-6 py-3">
              <span :class="['inline-block w-2 h-2 rounded-full', statusColor(app.status)]" :title="app.status" />
            </td>
            <!-- Name -->
            <td class="px-3 py-3">
              <span class="font-mono text-slate-200">{{ app.name }}</span>
            </td>
            <!-- Image -->
            <td class="px-3 py-3 text-slate-400 font-mono text-xs">{{ app.image }}</td>
            <!-- Ports -->
            <td class="px-3 py-3 text-slate-400 font-mono text-xs">{{ portsSummary(app) }}</td>
            <!-- Actions -->
            <td class="px-6 py-3">
              <div class="flex items-center justify-end gap-1">
                <!-- Start -->
                <button
                  @click="runAction(app.id, 'start')"
                  :disabled="!!actionLoading[app.id]"
                  title="Start"
                  class="p-1.5 text-slate-500 hover:text-emerald-400 disabled:opacity-40 transition-colors rounded-lg hover:bg-slate-800/70"
                >
                  <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M5 3l14 9-14 9V3z"/>
                  </svg>
                </button>
                <!-- Stop -->
                <button
                  @click="runAction(app.id, 'stop')"
                  :disabled="!!actionLoading[app.id]"
                  title="Stop"
                  class="p-1.5 text-slate-500 hover:text-amber-400 disabled:opacity-40 transition-colors rounded-lg hover:bg-slate-800/70"
                >
                  <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <rect x="6" y="6" width="12" height="12" rx="1" stroke-linecap="round" stroke-linejoin="round"/>
                  </svg>
                </button>
                <!-- Restart -->
                <button
                  @click="runAction(app.id, 'restart')"
                  :disabled="!!actionLoading[app.id]"
                  title="Restart"
                  class="p-1.5 text-slate-500 hover:text-blue-400 disabled:opacity-40 transition-colors rounded-lg hover:bg-slate-800/70"
                >
                  <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                  </svg>
                </button>
                <!-- Edit -->
                <button
                  @click="openEdit(app)"
                  title="Edit"
                  class="p-1.5 text-slate-500 hover:text-slate-200 transition-colors rounded-lg hover:bg-slate-800/70"
                >
                  <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/>
                  </svg>
                </button>
                <!-- Delete -->
                <button
                  @click="runAction(app.id, 'delete')"
                  :disabled="!!actionLoading[app.id]"
                  title="Delete"
                  class="p-1.5 text-slate-500 hover:text-red-400 disabled:opacity-40 transition-colors rounded-lg hover:bg-slate-800/70"
                >
                  <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                  </svg>
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <AppFormModal
    v-if="showModal"
    :edit-app="editApp"
    @close="showModal = false"
    @saved="onSaved"
  />
</template>
