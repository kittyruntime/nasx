<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { trpc } from '../lib/trpc'
import { useAuth } from '../lib/auth'

type Role = {
  id: string
  name: string
  isAdmin: boolean
  createdAt: string
  userRoles: { userId: string }[]
  permissions: { permission: { name: string } }[]
}
type User = { id: string; username: string; userRoles: { role: { id: string } }[] }

const SUGGESTIONS = ['*.*', 'users.manage', 'users.*', 'places.manage', 'places.*', 'files.*', 'files.read', 'files.write', 'files.delete']

const { currentUserId, isAdmin } = useAuth()

const roles       = ref<Role[]>([])
const users       = ref<User[]>([])
const expanded    = ref<Set<string>>(new Set())
const newRoleName = ref('')
const error       = ref('')
const permInputs  = ref<Record<string, string>>({})

const usernames = computed(() => new Set(users.value.map(u => u.username)))
function isPersonal(role: Role) { return usernames.value.has(role.name) }

function toggle(id: string) {
  if (expanded.value.has(id)) expanded.value.delete(id)
  else expanded.value.add(id)
  expanded.value = new Set(expanded.value) // trigger reactivity
}
function isExpanded(id: string) { return expanded.value.has(id) }

async function load() {
  const [r, u] = await Promise.all([trpc.role.list.query(), trpc.user.list.query()])
  roles.value = r as Role[]
  users.value = u as User[]
}

async function createRole() {
  const name = newRoleName.value.trim()
  if (!name) return
  error.value = ''
  try {
    await trpc.role.create.mutate({ name })
    newRoleName.value = ''
    await load()
  } catch (e: any) {
    error.value = e?.message ?? 'Failed to create role'
  }
}

async function deleteRole(id: string) {
  await trpc.role.delete.mutate({ id })
  expanded.value.delete(id)
  expanded.value = new Set(expanded.value)
  await load()
}

async function toggleAdmin(role: Role) {
  await trpc.role.update.mutate({ id: role.id, isAdmin: !role.isAdmin })
  await load()
}

async function addPermission(role: Role) {
  const name = (permInputs.value[role.id] ?? '').trim()
  if (!name) return
  await trpc.role.addPermission.mutate({ roleId: role.id, permissionName: name })
  permInputs.value[role.id] = ''
  await load()
}

async function removePermission(role: Role, permName: string) {
  await trpc.role.removePermission.mutate({ roleId: role.id, permissionName: permName })
  await load()
}

function userHasRole(user: User, roleId: string) {
  return user.userRoles.some(ur => ur.role.id === roleId)
}

async function toggleMember(userId: string, roleId: string, has: boolean) {
  if (has) await trpc.role.removeUser.mutate({ userId, roleId })
  else     await trpc.role.assignUser.mutate({ userId, roleId })
  await load()
}

onMounted(load)
</script>

<template>
  <section class="space-y-4">

    <div class="flex items-center justify-between px-1">
      <h3 class="text-xs font-medium uppercase tracking-widest text-slate-500">Roles</h3>
      <span class="text-xs text-slate-700">{{ roles.length }} total</span>
    </div>

    <p v-if="error" class="text-red-400 text-sm px-1">{{ error }}</p>

    <!-- Role cards -->
    <div class="space-y-2">
      <div v-if="roles.length === 0" class="text-sm text-slate-600 italic px-1">No roles yet.</div>

      <div
        v-for="role in roles"
        :key="role.id"
        class="bg-[#111120] border border-slate-800/60 rounded-xl overflow-hidden"
      >
        <!-- ── Card header ── -->
        <div class="flex items-center gap-3 px-4 py-3">
          <!-- Expand toggle (left side) -->
          <button
            @click="toggle(role.id)"
            class="flex items-center gap-2.5 flex-1 min-w-0 text-left"
          >
            <svg
              :class="['w-3.5 h-3.5 text-slate-600 shrink-0 transition-transform', isExpanded(role.id) ? 'rotate-90' : '']"
              fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/>
            </svg>

            <span class="text-sm font-medium text-slate-200 truncate">{{ role.name }}</span>

            <!-- Badges -->
            <span v-if="role.isAdmin" class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-blue-500/15 text-blue-400 shrink-0">admin</span>
            <span v-if="isPersonal(role)" class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-slate-700/60 text-slate-500 shrink-0">personal</span>
          </button>

          <!-- Meta + actions (right side) -->
          <div class="flex items-center gap-3 shrink-0">
            <span class="text-xs text-slate-700 tabular-nums hidden sm:block">
              {{ role.userRoles.length }}m · {{ role.permissions.length }}p
            </span>

            <!-- Admin toggle (admin-only) -->
            <button
              v-if="isAdmin"
              @click.stop="toggleAdmin(role)"
              :title="role.isAdmin ? 'Revoke admin' : 'Grant admin'"
              :class="[
                'text-[11px] px-2 py-0.5 rounded border transition-colors',
                role.isAdmin
                  ? 'border-blue-500/40 text-blue-400 hover:bg-red-900/20 hover:text-red-400 hover:border-red-500/40'
                  : 'border-slate-700/50 text-slate-600 hover:border-blue-500/40 hover:text-blue-400',
              ]"
            >
              {{ role.isAdmin ? 'admin ✓' : '+admin' }}
            </button>

            <!-- Delete -->
            <button
              v-if="isAdmin"
              @click.stop="deleteRole(role.id)"
              title="Delete role"
              class="p-1 rounded text-slate-700 hover:text-red-400 hover:bg-red-900/20 transition-colors"
            >
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
              </svg>
            </button>
          </div>
        </div>

        <!-- ── Expanded body ── -->
        <div v-if="isExpanded(role.id)" class="border-t border-slate-800/40 divide-y divide-slate-800/30">

          <!-- Permissions subsection -->
          <div class="px-4 py-3 space-y-2">
            <span class="text-[10px] font-semibold uppercase tracking-widest text-slate-600">Permissions</span>

            <div class="flex flex-wrap gap-1.5">
              <span
                v-for="rp in role.permissions"
                :key="rp.permission.name"
                class="inline-flex items-center gap-1 pl-2 pr-1 py-0.5 rounded-md text-[11px] font-mono
                       bg-emerald-500/10 text-emerald-400 border border-emerald-500/20"
              >
                {{ rp.permission.name }}
                <button
                  v-if="isAdmin"
                  @click="removePermission(role, rp.permission.name)"
                  class="w-3.5 h-3.5 flex items-center justify-center rounded hover:bg-red-500/20 hover:text-red-400 transition-colors leading-none"
                  title="Revoke"
                >×</button>
              </span>

              <span v-if="role.permissions.length === 0" class="text-xs text-slate-700 italic">
                {{ role.isAdmin ? 'Implicit — admin has all permissions' : 'No permissions granted' }}
              </span>
            </div>

            <!-- Add permission (admin-only) -->
            <div v-if="isAdmin" class="flex gap-1.5 pt-1">
              <input
                v-model="permInputs[role.id]"
                :list="`perm-${role.id}`"
                placeholder="e.g. users.manage, files.*, *.*"
                @keydown.enter.prevent="addPermission(role)"
                class="flex-1 bg-[#0a0a14] border border-slate-700/50 rounded-lg px-2.5 py-1 text-xs font-mono
                       text-slate-300 placeholder-slate-700 focus:outline-none focus:border-emerald-500/50"
              />
              <datalist :id="`perm-${role.id}`">
                <option v-for="s in SUGGESTIONS" :key="s" :value="s"/>
              </datalist>
              <button
                @click="addPermission(role)"
                :disabled="!(permInputs[role.id] ?? '').trim()"
                class="px-3 py-1 bg-emerald-700/30 hover:bg-emerald-700/50 disabled:opacity-30
                       disabled:cursor-not-allowed text-emerald-300 text-xs font-medium rounded-lg transition-colors"
              >
                Grant
              </button>
            </div>
          </div>

          <!-- Members subsection -->
          <div class="px-4 py-3 space-y-2">
            <span class="text-[10px] font-semibold uppercase tracking-widest text-slate-600">Members</span>

            <div class="flex flex-wrap gap-1.5">
              <button
                v-for="user in users"
                :key="user.id"
                :disabled="user.id === currentUserId"
                @click="user.id !== currentUserId && toggleMember(user.id, role.id, userHasRole(user, role.id))"
                :title="user.id === currentUserId ? 'Cannot change your own role membership' : undefined"
                :class="[
                  'inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-xs font-medium border transition-colors',
                  userHasRole(user, role.id)
                    ? 'bg-blue-600/20 border-blue-500/40 text-blue-300 hover:bg-red-900/20 hover:border-red-500/30 hover:text-red-400'
                    : 'bg-transparent border-slate-700/50 text-slate-500 hover:border-slate-500 hover:text-slate-300',
                  user.id === currentUserId ? 'opacity-40 cursor-not-allowed' : 'cursor-pointer',
                ]"
              >
                <svg v-if="userHasRole(user, role.id)" class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
                </svg>
                {{ user.username }}
              </button>

              <span v-if="users.length === 0" class="text-xs text-slate-700 italic">No users</span>
            </div>
          </div>

        </div>
      </div>
    </div>

    <!-- Add role -->
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
      >
        Add
      </button>
    </form>

  </section>
</template>
