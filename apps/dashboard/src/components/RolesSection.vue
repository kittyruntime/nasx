<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { trpc } from '../lib/trpc'
import RoleEditor from './RoleEditor.vue'

type Role = {
  id: string
  name: string
  isAdmin: boolean
  createdAt: string
  userRoles: { userId: string }[]
  permissions: { permission: { name: string } }[]
}
type User = {
  id: string
  username: string
  displayName?: string | null
  userRoles: { role: { id: string } }[]
}

const roles        = ref<Role[]>([])
const users        = ref<User[]>([])
const selectedRole = ref<Role | null>(null)
const newRoleName  = ref('')
const createError  = ref('')

const usernames  = computed(() => new Set(users.value.map(u => u.username)))
function isPersonal(role: Role) { return usernames.value.has(role.name) }

async function load() {
  const [r, u] = await Promise.all([trpc.role.list.query(), trpc.user.list.query()])
  roles.value = r as Role[]
  users.value = u as User[]
  // Keep selectedRole in sync with fresh data
  if (selectedRole.value) {
    selectedRole.value = roles.value.find(r => r.id === selectedRole.value!.id) ?? null
  }
}

async function createRole() {
  const name = newRoleName.value.trim()
  if (!name) return
  createError.value = ''
  try {
    await trpc.role.create.mutate({ name })
    newRoleName.value = ''
    await load()
  } catch (e: any) {
    createError.value = e?.message ?? 'Failed to create role'
  }
}

function openEditor(role: Role) {
  selectedRole.value = role
}

function onBack() {
  selectedRole.value = null
}

onMounted(load)
</script>

<template>
  <div>

    <!-- ── Role editor ────────────────────────────────────────────────────── -->
    <RoleEditor
      v-if="selectedRole"
      :role="selectedRole"
      :users="users"
      @back="onBack"
      @reload="load"
    />

    <!-- ── Role list ──────────────────────────────────────────────────────── -->
    <section v-else class="space-y-5">

      <div class="flex items-center justify-between px-0.5">
        <h3 class="text-xs font-medium uppercase tracking-widest text-slate-500">Roles</h3>
        <span class="text-xs text-slate-700">{{ roles.length }} total</span>
      </div>

      <!-- List -->
      <div class="space-y-1.5">
        <div v-if="roles.length === 0" class="text-sm text-slate-600 italic px-1">No roles yet.</div>

        <div
          v-for="role in roles"
          :key="role.id"
          class="flex items-center gap-3 px-4 py-3 bg-[#111120] border border-slate-800/60 rounded-xl"
        >
          <!-- Name + badges -->
          <div class="flex-1 min-w-0 flex items-center gap-2">
            <span class="text-sm font-medium text-slate-200 truncate">{{ role.name }}</span>
            <span
              v-if="role.isAdmin"
              class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-blue-500/15 text-blue-400 shrink-0"
            >admin</span>
            <span
              v-if="isPersonal(role)"
              class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-slate-700/60 text-slate-500 shrink-0"
            >personal</span>
          </div>

          <!-- Meta + Edit -->
          <div class="flex items-center gap-3 shrink-0">
            <span class="text-xs text-slate-700 tabular-nums hidden sm:block">
              {{ role.userRoles.length }}m · {{ role.permissions.length }}p
            </span>
            <button
              @click="openEditor(role)"
              class="text-xs px-2.5 py-1 rounded-lg border border-slate-700/50 text-slate-500
                     hover:border-blue-500/40 hover:text-blue-400 transition-colors"
            >Edit</button>
          </div>
        </div>
      </div>

      <!-- Create role -->
      <form @submit.prevent="createRole" class="flex gap-2 pt-1">
        <input
          v-model="newRoleName"
          placeholder="New role name…"
          class="flex-1 bg-[#111120] border border-slate-700/60 rounded-lg px-3 py-1.5 text-sm text-slate-200
                 placeholder-slate-600 focus:outline-none focus:border-blue-500/60"
        />
        <button
          type="submit"
          :disabled="!newRoleName.trim()"
          class="px-4 py-1.5 bg-blue-600 hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed
                 text-white text-sm font-medium rounded-lg transition-colors"
        >Add</button>
      </form>
      <p v-if="createError" class="text-red-400 text-xs px-0.5">{{ createError }}</p>

    </section>
  </div>
</template>
