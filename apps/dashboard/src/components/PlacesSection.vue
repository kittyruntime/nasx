<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { trpc } from '../lib/trpc'

type Place = { id: string; name: string; path: string }
type Role  = { id: string; name: string; userRoles: { userId: string }[] }
type User  = { id: string; username: string; userRoles: { role: { isAdmin: boolean } }[] }
type Perm  = { id: string; placeId: string; subjectType: string; subjectId: string; canRead: boolean; canWrite: boolean; canDelete: boolean }

const places       = ref<Place[]>([])
const roles        = ref<Role[]>([])
const users        = ref<User[]>([])
const permsByPlace = ref<Record<string, Perm[]>>({})
const expandedPlace = ref<string | null>(null)
const loading      = ref(true)
const adding       = ref(false)
const newName      = ref('')
const newPath      = ref('')
const addError     = ref('')
const addLoading   = ref(false)

function userIsAdmin(u: User) { return u.userRoles.some(ur => ur.role.isAdmin) }

// Hide personal roles from the matrix (users are already listed individually)
const visibleRoles = computed(() => {
  const usernames = new Set(users.value.map(u => u.username))
  return roles.value.filter(r => !usernames.has(r.name))
})

async function load() {
  const [p, r, u] = await Promise.all([
    trpc.place.list.query(),
    trpc.role.list.query(),
    trpc.user.list.query(),
  ])
  places.value = p as Place[]
  roles.value  = r as Role[]
  users.value  = u as User[]
}

async function addPlace() {
  addError.value  = ''
  addLoading.value = true
  try {
    const created = await trpc.place.create.mutate({ name: newName.value.trim(), path: newPath.value.trim() })
    places.value.push(created as Place)
    newName.value = ''
    newPath.value = ''
    adding.value  = false
  } catch (e: any) {
    addError.value = e?.message ?? 'Failed to add place'
  } finally {
    addLoading.value = false
  }
}

async function deletePlace(id: string) {
  await trpc.place.delete.mutate({ id })
  places.value = places.value.filter(p => p.id !== id)
  if (expandedPlace.value === id) expandedPlace.value = null
  delete permsByPlace.value[id]
}

async function loadPerms(placeId: string) {
  permsByPlace.value[placeId] = (await trpc.permission.listForPlace.query({ placeId })) as Perm[]
}

async function togglePlace(placeId: string) {
  if (expandedPlace.value === placeId) { expandedPlace.value = null; return }
  expandedPlace.value = placeId
  await loadPerms(placeId)
}

function getPerm(placeId: string, subjectType: string, subjectId: string): Perm | undefined {
  return permsByPlace.value[placeId]?.find(p => p.subjectType === subjectType && p.subjectId === subjectId)
}

async function togglePerm(
  placeId: string,
  subjectType: 'user' | 'role',
  subjectId: string,
  field: 'canRead' | 'canWrite' | 'canDelete',
) {
  const current = getPerm(placeId, subjectType, subjectId)
  const next = {
    canRead:   current?.canRead   ?? false,
    canWrite:  current?.canWrite  ?? false,
    canDelete: current?.canDelete ?? false,
  }
  next[field] = !next[field]
  if (!next.canRead && !next.canWrite && !next.canDelete) {
    await trpc.permission.remove.mutate({ placeId, subjectType, subjectId })
  } else {
    await trpc.permission.upsert.mutate({ placeId, subjectType, subjectId, ...next })
  }
  await loadPerms(placeId)
}

onMounted(async () => {
  try { await load() } finally { loading.value = false }
})
</script>

<template>
  <section>
    <div class="flex items-center justify-between mb-3 px-1">
      <h3 class="text-xs font-medium uppercase tracking-widest text-slate-500">Places</h3>
      <button
        v-if="!adding"
        @click="adding = true"
        class="flex items-center gap-1 text-xs text-blue-400 hover:text-blue-300 transition-colors"
      >
        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5">
          <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4"/>
        </svg>
        Add
      </button>
    </div>

    <!-- Loading -->
    <div v-if="loading" class="text-slate-600 text-sm px-1">Loading…</div>

    <template v-else>
      <!-- Add form -->
      <div v-if="adding" class="rounded-xl border border-blue-500/30 bg-[#111120] p-4 mb-3">
        <div class="flex gap-3 mb-3">
          <div class="flex-1">
            <label class="block text-xs text-slate-500 mb-1">Name</label>
            <input v-model="newName" type="text" placeholder="Media"
              class="w-full bg-[#0a0a14] border border-slate-700 rounded-lg px-3 py-2 text-sm text-slate-100
                     focus:outline-none focus:border-blue-500 transition-colors placeholder-slate-600"/>
          </div>
          <div class="flex-[2]">
            <label class="block text-xs text-slate-500 mb-1">Path</label>
            <input v-model="newPath" type="text" placeholder="/mnt/data"
              class="w-full bg-[#0a0a14] border border-slate-700 rounded-lg px-3 py-2 text-sm text-slate-100
                     font-mono focus:outline-none focus:border-blue-500 transition-colors placeholder-slate-600"/>
          </div>
        </div>
        <div v-if="addError" class="text-red-400 text-xs mb-2">{{ addError }}</div>
        <div class="flex gap-2">
          <button @click="addPlace" :disabled="addLoading || !newName.trim() || !newPath.trim()"
            class="px-3 py-1.5 bg-blue-600 hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed
                   text-white text-sm rounded-lg transition-colors">
            {{ addLoading ? 'Adding…' : 'Add Place' }}
          </button>
          <button @click="adding = false; addError = ''"
            class="px-3 py-1.5 text-slate-400 hover:text-slate-200 text-sm transition-colors">
            Cancel
          </button>
        </div>
      </div>

      <!-- Empty state -->
      <div v-if="places.length === 0 && !adding" class="rounded-xl border border-slate-800 bg-[#111120] px-5 py-4">
        <p class="text-sm text-slate-600 italic">No places configured yet.</p>
      </div>

      <!-- Places list -->
      <div v-else-if="places.length > 0" class="space-y-2">
        <div
          v-for="place in places"
          :key="place.id"
          class="bg-[#111120] border border-slate-800/60 rounded-xl overflow-hidden"
        >
          <!-- Place row -->
          <div class="flex items-center gap-3 px-4 py-3 group">
            <button @click="togglePlace(place.id)" class="flex-1 flex items-center gap-3 text-left min-w-0">
              <svg class="w-4 h-4 text-blue-500 shrink-0" fill="currentColor" viewBox="0 0 20 20">
                <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z"/>
              </svg>
              <div class="flex-1 min-w-0">
                <span class="text-sm text-slate-200">{{ place.name }}</span>
                <span class="text-slate-600 text-xs font-mono ml-3">{{ place.path }}</span>
              </div>
              <!-- Expand chevron -->
              <svg :class="['w-3.5 h-3.5 text-slate-600 shrink-0 transition-transform', expandedPlace === place.id ? 'rotate-180' : '']"
                fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7"/>
              </svg>
            </button>
            <button @click="deletePlace(place.id)"
              class="opacity-0 group-hover:opacity-100 p-1 rounded text-slate-600 hover:text-red-400
                     hover:bg-red-900/20 transition-all shrink-0"
              title="Remove">
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12"/>
              </svg>
            </button>
          </div>

          <!-- Permissions matrix (expanded) -->
          <div v-if="expandedPlace === place.id" class="border-t border-slate-800/40">
            <div class="px-4 py-2 bg-[#0d0d1e]">
              <span class="text-[10px] font-semibold uppercase tracking-widest text-slate-600">Permissions</span>
            </div>
            <table class="w-full text-xs">
              <thead>
                <tr class="text-slate-600 uppercase tracking-wider border-b border-slate-800/40 bg-[#0d0d1e]">
                  <th class="px-4 py-2 text-left font-medium">Subject</th>
                  <th class="px-3 py-2 text-center font-medium w-16">Read</th>
                  <th class="px-3 py-2 text-center font-medium w-16">Write</th>
                  <th class="px-3 py-2 text-center font-medium w-16">Delete</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-slate-800/30">
                <!-- Roles (personal roles hidden — users are listed individually below) -->
                <tr v-for="role in visibleRoles" :key="'role-' + role.id">
                  <td class="px-4 py-2.5">
                    <div class="flex items-center gap-1.5">
                      <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-violet-500/15 text-violet-400">role</span>
                      <span class="text-slate-300">{{ role.name }}</span>
                    </div>
                  </td>
                  <td v-for="field in (['canRead', 'canWrite', 'canDelete'] as const)" :key="field" class="px-3 py-2.5 text-center">
                    <input type="checkbox"
                      :checked="getPerm(place.id, 'role', role.id)?.[field] ?? false"
                      @change="togglePerm(place.id, 'role', role.id, field)"
                      class="w-3.5 h-3.5 rounded accent-blue-500 cursor-pointer"/>
                  </td>
                </tr>

                <!-- Users (skip admins — they always have full access) -->
                <tr v-for="user in users.filter(u => !userIsAdmin(u))" :key="'user-' + user.id">
                  <td class="px-4 py-2.5">
                    <div class="flex items-center gap-1.5">
                      <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-slate-700/60 text-slate-400">user</span>
                      <span class="text-slate-300">{{ user.username }}</span>
                    </div>
                  </td>
                  <td v-for="field in (['canRead', 'canWrite', 'canDelete'] as const)" :key="field" class="px-3 py-2.5 text-center">
                    <input type="checkbox"
                      :checked="getPerm(place.id, 'user', user.id)?.[field] ?? false"
                      @change="togglePerm(place.id, 'user', user.id, field)"
                      class="w-3.5 h-3.5 rounded accent-blue-500 cursor-pointer"/>
                  </td>
                </tr>

                <tr v-if="visibleRoles.length === 0 && !users.some(u => !userIsAdmin(u))">
                  <td colspan="4" class="px-4 py-3 text-slate-600 italic">No roles or users to assign.</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </template>
  </section>
</template>
