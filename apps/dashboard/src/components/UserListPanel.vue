<script setup lang="ts">
import { ref, reactive, computed, onMounted } from 'vue'
import { trpc } from '../lib/trpc'
import { useAuth } from '../lib/auth'

type UserRole = { role: { id: string; name: string; isAdmin: boolean; permissions: { permission: { name: string } }[] } }
type User = {
  id: string
  username: string
  displayName: string | null
  linuxUsername: string | null
  createdAt: Date | string
  userRoles: UserRole[]
}

function matchesPerm(grants: string[], required: string): boolean {
  const [rNs] = required.split('.')
  return grants.some(g => g === required || g === '*.*' || (() => { const [ns, act] = g.split('.'); return ns === rNs && act === '*' })())
}
function userIsAdmin(u: User) { return u.userRoles.some(ur => ur.role.isAdmin) }
function userCanManage(u: User) {
  return userIsAdmin(u) || matchesPerm(u.userRoles.flatMap(ur => ur.role.permissions.map(rp => rp.permission.name)), 'users.manage')
}

const { canManageUsers, currentUserId } = useAuth()

const users      = ref<User[]>([])
const loading    = ref(true)
const loadError  = ref('')

// ── Add user ────────────────────────────────────────────────────────────────
const addingUser = ref(false)
const newUser    = reactive({ username: '', password: '', confirmPassword: '', displayName: '' })
const addError   = ref('')
const addLoading = ref(false)

// ── Edit user ────────────────────────────────────────────────────────────────
const editingUserId = ref<string | null>(null)
const editForm      = reactive({ displayName: '', linuxUsername: '' })
const editError     = ref('')
const editLoading   = ref(false)

const editingUser = computed(() => users.value.find(u => u.id === editingUserId.value) ?? null)


// ── Helpers ──────────────────────────────────────────────────────────────────
async function load() {
  loading.value = true
  loadError.value = ''
  try {
    users.value = (await trpc.user.list.query()) as User[]
  } catch {
    loadError.value = 'Failed to load users'
  } finally {
    loading.value = false
  }
}

function formatDate(d: Date | string) {
  return new Date(d).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' })
}

function getInitials(username: string) { return username.slice(0, 2).toUpperCase() }

const palette = [
  'from-blue-500 to-blue-700', 'from-violet-500 to-violet-700',
  'from-emerald-500 to-emerald-700', 'from-amber-500 to-amber-700',
  'from-rose-500 to-rose-700', 'from-cyan-500 to-cyan-700',
]
function avatarGradient(username: string) {
  let hash = 0
  for (const ch of username) hash = (hash * 31 + ch.charCodeAt(0)) % palette.length
  return palette[hash]
}

// ── Add user actions ─────────────────────────────────────────────────────────
function openAdd() {
  addingUser.value = true
  addError.value = ''
  Object.assign(newUser, { username: '', password: '', confirmPassword: '', displayName: '' })
}

function cancelAdd() { addingUser.value = false }

async function submitAdd() {
  addError.value = ''
  if (newUser.password !== newUser.confirmPassword) { addError.value = 'Passwords do not match'; return }
  addLoading.value = true
  try {
    await trpc.user.create.mutate({
      username: newUser.username.trim(),
      password: newUser.password,
      displayName: newUser.displayName.trim() || undefined,
    })
    addingUser.value = false
    await load()
  } catch (e: any) {
    addError.value = e?.message ?? 'Failed to create user'
  } finally {
    addLoading.value = false
  }
}

// ── Edit user actions ─────────────────────────────────────────────────────────
function openEdit(user: User) {
  editingUserId.value = user.id
  editError.value = ''
  Object.assign(editForm, {
    displayName:   user.displayName ?? '',
    linuxUsername: user.linuxUsername ?? '',
  })
}

function cancelEdit() { editingUserId.value = null }

async function submitEdit() {
  if (!editingUserId.value) return
  editError.value = ''
  editLoading.value = true
  try {
    await trpc.user.update.mutate({
      userId:        editingUserId.value,
      displayName:   editForm.displayName.trim() || null,
      linuxUsername: editForm.linuxUsername.trim() || null,
    })
    editingUserId.value = null
    await load()
  } catch (e: any) {
    editError.value = e?.message ?? 'Failed to update user'
  } finally {
    editLoading.value = false
  }
}

async function deleteUser(userId: string) {
  if (!confirm('Delete this user? This cannot be undone.')) return
  try {
    await trpc.user.delete.mutate({ userId })
    await load()
  } catch (e: any) {
    alert(e?.message ?? 'Failed to delete user')
  }
}


onMounted(load)
</script>

<template>
  <div class="space-y-6">

    <!-- ── Header ── -->
    <div class="flex items-center justify-between">
      <span v-if="!loading && !loadError" class="text-xs text-slate-600 tabular-nums">
        {{ users.length }} account{{ users.length !== 1 ? 's' : '' }}
      </span>
      <span v-else class="text-xs text-slate-700">Users</span>

      <button
        v-if="canManageUsers && !addingUser"
        @click="openAdd"
        class="flex items-center gap-1.5 px-2.5 py-1.5 bg-blue-600 hover:bg-blue-500 text-white text-xs font-medium rounded-lg transition-colors"
      >
        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5">
          <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4"/>
        </svg>
        Add user
      </button>
    </div>

    <!-- ── Add user form ── -->
    <div v-if="addingUser" class="border border-blue-500/30 bg-[#0d0d1f] rounded-xl p-4 space-y-3">
      <h4 class="text-xs font-semibold text-slate-300 uppercase tracking-widest">New user</h4>

      <div class="grid grid-cols-2 gap-2.5">
        <div>
          <label class="block text-xs text-slate-500 mb-1">Username <span class="text-red-400">*</span></label>
          <input v-model="newUser.username" placeholder="johndoe" autofocus
            class="w-full bg-[#111120] border border-slate-700/60 rounded-lg px-3 py-1.5 text-sm text-slate-200 placeholder-slate-600 focus:outline-none focus:border-blue-500/60"/>
        </div>
        <div>
          <label class="block text-xs text-slate-500 mb-1">Display name</label>
          <input v-model="newUser.displayName" placeholder="John Doe"
            class="w-full bg-[#111120] border border-slate-700/60 rounded-lg px-3 py-1.5 text-sm text-slate-200 placeholder-slate-600 focus:outline-none focus:border-blue-500/60"/>
        </div>
        <div>
          <label class="block text-xs text-slate-500 mb-1">Password <span class="text-red-400">*</span></label>
          <input v-model="newUser.password" type="password" placeholder="Min. 6 chars"
            class="w-full bg-[#111120] border border-slate-700/60 rounded-lg px-3 py-1.5 text-sm text-slate-200 placeholder-slate-600 focus:outline-none focus:border-blue-500/60"/>
        </div>
        <div>
          <label class="block text-xs text-slate-500 mb-1">Confirm password <span class="text-red-400">*</span></label>
          <input v-model="newUser.confirmPassword" type="password" placeholder="Repeat password"
            class="w-full bg-[#111120] border border-slate-700/60 rounded-lg px-3 py-1.5 text-sm text-slate-200 placeholder-slate-600 focus:outline-none focus:border-blue-500/60"/>
        </div>
      </div>

      <p v-if="addError" class="text-red-400 text-xs">{{ addError }}</p>

      <div class="flex items-center gap-2">
        <button @click="submitAdd" :disabled="addLoading || !newUser.username || !newUser.password"
          class="px-3 py-1.5 bg-blue-600 hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed text-white text-sm font-medium rounded-lg transition-colors">
          {{ addLoading ? 'Creating…' : 'Create user' }}
        </button>
        <button @click="cancelAdd" class="px-3 py-1.5 text-slate-500 hover:text-slate-200 text-sm transition-colors">
          Cancel
        </button>
      </div>
    </div>

    <!-- ── Loading ── -->
    <div v-if="loading" class="flex items-center gap-2 text-slate-500 text-sm py-4">
      <svg class="w-4 h-4 animate-spin shrink-0" fill="none" viewBox="0 0 24 24">
        <circle class="opacity-20" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"/>
      </svg>
      Loading users…
    </div>

    <!-- ── Error ── -->
    <div v-else-if="loadError" class="flex items-center gap-2 text-red-400 text-sm py-4">
      <svg class="w-4 h-4 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
        <path stroke-linecap="round" stroke-linejoin="round" d="M12 9v2m0 4h.01M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/>
      </svg>
      {{ loadError }}
    </div>

    <!-- ── User table ── -->
    <div v-else class="rounded-xl border border-slate-800 overflow-hidden">
      <table class="w-full text-sm">
        <thead>
          <tr class="bg-[#111120] text-left text-xs uppercase tracking-wider text-slate-500">
            <th class="px-5 py-3 font-medium">User</th>
            <th class="px-5 py-3 font-medium">Roles</th>
            <th class="px-5 py-3 font-medium">Linux user</th>
            <th class="px-5 py-3 font-medium">Created</th>
            <th v-if="canManageUsers" class="px-4 py-3 font-medium w-16"></th>
          </tr>
        </thead>
        <tbody class="divide-y divide-slate-800/60">
          <template v-for="user in users" :key="user.id">
            <!-- User row -->
            <tr class="bg-[#0f0f1a] hover:bg-[#13132a] transition-colors">
              <!-- Username + badges -->
              <td class="px-5 py-3.5">
                <div class="flex items-center gap-3">
                  <div :class="['w-7 h-7 rounded-full bg-gradient-to-br flex items-center justify-center text-white text-xs font-bold shrink-0', avatarGradient(user.username)]">
                    {{ getInitials(user.username) }}
                  </div>
                  <div class="min-w-0">
                    <div class="flex items-center gap-1.5 flex-wrap">
                      <span class="text-slate-200 font-medium">{{ user.username }}</span>
                      <span v-if="user.id === currentUserId" class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-slate-700/60 text-slate-400">you</span>
                      <span v-if="userIsAdmin(user)" class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-blue-500/15 text-blue-400">admin</span>
                      <span v-if="!userIsAdmin(user) && userCanManage(user)" class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-violet-500/15 text-violet-400">manager</span>
                    </div>
                    <div v-if="user.displayName" class="text-xs text-slate-500 truncate">{{ user.displayName }}</div>
                  </div>
                </div>
              </td>

              <!-- Roles -->
              <td class="px-5 py-3.5">
                <div class="flex flex-wrap gap-1">
                  <span v-for="ur in user.userRoles" :key="ur.role.id"
                    class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-violet-500/15 text-violet-400">
                    {{ ur.role.name }}
                  </span>
                  <span v-if="user.userRoles.length === 0" class="text-slate-600 text-xs italic">none</span>
                </div>
              </td>

              <!-- Linux user -->
              <td class="px-5 py-3.5">
                <span class="font-mono text-xs" :class="user.linuxUsername ? 'text-slate-300' : 'text-slate-600 italic'">
                  {{ user.linuxUsername ?? '—' }}
                </span>
              </td>

              <!-- Created -->
              <td class="px-5 py-3.5 text-slate-500 font-mono text-xs">{{ formatDate(user.createdAt) }}</td>

              <!-- Actions -->
              <td v-if="canManageUsers" class="px-4 py-3.5">
                <div class="flex items-center gap-1 justify-end">
                  <button
                    v-if="editingUserId !== user.id"
                    @click="openEdit(user)"
                    title="Edit user"
                    class="p-1.5 rounded text-slate-600 hover:text-slate-200 hover:bg-slate-800 transition-colors"
                  >
                    <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                      <path stroke-linecap="round" stroke-linejoin="round" d="M15.232 5.232l3.536 3.536m-2.036-5.036a2.5 2.5 0 113.536 3.536L6.5 21.036H3v-3.572L16.732 3.732z"/>
                    </svg>
                  </button>
                  <button
                    v-if="user.id !== currentUserId"
                    @click="deleteUser(user.id)"
                    title="Delete user"
                    class="p-1.5 rounded text-slate-600 hover:text-red-400 hover:bg-red-900/20 transition-colors"
                  >
                    <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                      <path stroke-linecap="round" stroke-linejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                    </svg>
                  </button>
                </div>
              </td>
            </tr>

            <!-- Edit form row (expands inline below the row) -->
            <tr v-if="editingUserId === user.id" :key="user.id + '-edit'">
              <td :colspan="canManageUsers ? 5 : 4" class="px-5 py-4 bg-[#0d0d1f] border-t border-blue-500/20">
                <div class="space-y-3">
                  <h5 class="text-xs font-semibold text-slate-400 uppercase tracking-widest">
                    Editing {{ editingUser?.username }}
                  </h5>

                  <div class="grid grid-cols-2 gap-2.5">
                    <div>
                      <label class="block text-xs text-slate-500 mb-1">Display name</label>
                      <input v-model="editForm.displayName" placeholder="Full name"
                        class="w-full bg-[#111120] border border-slate-700/60 rounded-lg px-3 py-1.5 text-sm text-slate-200 placeholder-slate-600 focus:outline-none focus:border-blue-500/60"/>
                    </div>
                    <div>
                      <label class="block text-xs text-slate-500 mb-1">Linux username</label>
                      <input v-model="editForm.linuxUsername" placeholder="linux_user" class="font-mono
                        w-full bg-[#111120] border border-slate-700/60 rounded-lg px-3 py-1.5 text-sm text-slate-200 placeholder-slate-600 focus:outline-none focus:border-blue-500/60"/>
                    </div>
                  </div>

                  <p v-if="editError" class="text-red-400 text-xs">{{ editError }}</p>

                  <div class="flex items-center gap-2">
                    <button @click="submitEdit" :disabled="editLoading"
                      class="px-3 py-1.5 bg-blue-600 hover:bg-blue-500 disabled:opacity-40 text-white text-sm font-medium rounded-lg transition-colors">
                      {{ editLoading ? 'Saving…' : 'Save' }}
                    </button>
                    <button @click="cancelEdit" class="px-3 py-1.5 text-slate-500 hover:text-slate-200 text-sm transition-colors">
                      Cancel
                    </button>
                  </div>
                </div>
              </td>
            </tr>
          </template>
        </tbody>
      </table>
    </div>

  </div>
</template>
