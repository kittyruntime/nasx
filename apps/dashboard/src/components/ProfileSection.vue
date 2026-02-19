<script setup lang="ts">
import { ref, reactive, computed, onMounted } from 'vue'
import { trpc } from '../lib/trpc'
import { useAuth } from '../lib/auth'

type Me = {
  id: string
  username: string
  displayName: string | null
  linuxUsername: string | null
  userRoles: { role: { id: string; name: string; isAdmin: boolean; permissions: { permission: { name: string } }[] } }[]
}

function matchesPerm(grants: string[], required: string): boolean {
  const [rNs] = required.split('.')
  return grants.some(g => g === required || g === '*.*' || (() => { const [ns, act] = g.split('.'); return ns === rNs && act === '*' })())
}
const meIsAdmin = computed(() => !!me.value && me.value.userRoles.some(ur => ur.role.isAdmin))
const meCanManage = computed(() => {
  if (!me.value) return false
  const grants = me.value.userRoles.flatMap(ur => ur.role.permissions.map(rp => rp.permission.name))
  return meIsAdmin.value || matchesPerm(grants, 'users.manage')
})

useAuth()

const me      = ref<Me | null>(null)
const loading = ref(true)

// ── Display name ──────────────────────────────────────────────────────────────
const editingName  = ref(false)
const nameValue    = ref('')
const nameLoading  = ref(false)
const nameError    = ref('')
const nameSuccess  = ref(false)

function startEditName() {
  nameValue.value  = me.value?.displayName ?? ''
  nameError.value  = ''
  nameSuccess.value = false
  editingName.value = true
}

async function saveName() {
  nameError.value = ''
  nameLoading.value = true
  try {
    const updated = await trpc.user.updateSelf.mutate({ displayName: nameValue.value.trim() || null })
    me.value = { ...me.value!, displayName: (updated as any).displayName }
    editingName.value = false
    nameSuccess.value = true
    setTimeout(() => { nameSuccess.value = false }, 3000)
  } catch (e: any) {
    nameError.value = e?.message ?? 'Failed to update'
  } finally {
    nameLoading.value = false
  }
}

// ── Change password ───────────────────────────────────────────────────────────
const pwOpen    = ref(false)
const pwForm    = reactive({ current: '', next: '', confirm: '' })
const pwError   = ref('')
const pwSuccess = ref(false)
const pwLoading = ref(false)

function openPassword() {
  pwSuccess.value = false
  pwError.value   = ''
  Object.assign(pwForm, { current: '', next: '', confirm: '' })
  pwOpen.value = true
}

async function submitPassword() {
  pwError.value   = ''
  pwSuccess.value = false
  if (pwForm.next !== pwForm.confirm) { pwError.value = 'Passwords do not match'; return }
  if (pwForm.next.length < 6)         { pwError.value = 'New password must be at least 6 characters'; return }
  pwLoading.value = true
  try {
    await trpc.user.changePassword.mutate({ currentPassword: pwForm.current, newPassword: pwForm.next })
    pwSuccess.value = true
    Object.assign(pwForm, { current: '', next: '', confirm: '' })
  } catch (e: any) {
    pwError.value = e?.message ?? 'Failed to change password'
  } finally {
    pwLoading.value = false
  }
}

// ── Init ──────────────────────────────────────────────────────────────────────
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

onMounted(async () => {
  try { me.value = (await trpc.user.me.query()) as Me }
  finally { loading.value = false }
})
</script>

<template>
  <div class="space-y-8">

    <!-- Loading -->
    <div v-if="loading" class="flex items-center gap-2 text-slate-500 text-sm py-4">
      <svg class="w-4 h-4 animate-spin shrink-0" fill="none" viewBox="0 0 24 24">
        <circle class="opacity-20" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"/>
      </svg>
      Loading…
    </div>

    <template v-else-if="me">

      <!-- ── Identity card ── -->
      <div class="flex items-center gap-4">
        <!-- Avatar -->
        <div :class="['w-14 h-14 rounded-2xl bg-gradient-to-br flex items-center justify-center text-white text-lg font-bold shrink-0 select-none', avatarGradient(me.username)]">
          {{ me.username.slice(0, 2).toUpperCase() }}
        </div>

        <!-- Name + badges -->
        <div class="min-w-0">
          <div class="flex items-center gap-2 flex-wrap">
            <span class="text-slate-100 text-lg font-semibold leading-tight">
              {{ me.displayName || me.username }}
            </span>
            <span v-if="me.displayName" class="text-slate-500 text-sm">{{ me.username }}</span>
            <span v-if="meIsAdmin" class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-blue-500/15 text-blue-400">admin</span>
            <span v-if="!meIsAdmin && meCanManage" class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-violet-500/15 text-violet-400">manager</span>
          </div>
          <!-- Roles -->
          <div class="flex flex-wrap gap-1 mt-1.5">
            <span v-for="ur in me.userRoles.filter(ur => ur.role.name !== me!.username)" :key="ur.role.id"
              class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-violet-500/10 text-violet-400">
              {{ ur.role.name }}
            </span>
            <span v-if="me.linuxUsername" class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono bg-slate-800 text-slate-400">
              {{ me.linuxUsername }}
            </span>
          </div>
        </div>
      </div>

      <!-- ── Display name ── -->
      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <h4 class="text-xs font-semibold uppercase tracking-widest text-slate-500">Display name</h4>
          <button v-if="!editingName" @click="startEditName"
            class="text-xs text-slate-600 hover:text-slate-300 transition-colors">
            Edit
          </button>
        </div>

        <div v-if="!editingName" class="bg-[#111120] border border-slate-800 rounded-xl px-4 py-3 flex items-center justify-between">
          <span :class="me.displayName ? 'text-slate-200 text-sm' : 'text-slate-600 text-sm italic'">
            {{ me.displayName || 'Not set' }}
          </span>
          <span v-if="nameSuccess" class="text-xs text-green-400">Saved</span>
        </div>

        <div v-else class="bg-[#0d0d1f] border border-blue-500/30 rounded-xl p-4 space-y-3">
          <input
            v-model="nameValue"
            placeholder="Your full name"
            autofocus
            @keydown.enter="saveName"
            @keydown.escape="editingName = false"
            class="w-full bg-[#111120] border border-slate-700/60 rounded-lg px-3 py-1.5 text-sm text-slate-200 placeholder-slate-600 focus:outline-none focus:border-blue-500/60"
          />
          <p v-if="nameError" class="text-red-400 text-xs">{{ nameError }}</p>
          <div class="flex gap-2">
            <button @click="saveName" :disabled="nameLoading"
              class="px-3 py-1.5 bg-blue-600 hover:bg-blue-500 disabled:opacity-40 text-white text-sm font-medium rounded-lg transition-colors">
              {{ nameLoading ? 'Saving…' : 'Save' }}
            </button>
            <button @click="editingName = false"
              class="px-3 py-1.5 text-slate-500 hover:text-slate-200 text-sm transition-colors">
              Cancel
            </button>
          </div>
        </div>
      </div>

      <!-- ── Change password ── -->
      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <h4 class="text-xs font-semibold uppercase tracking-widest text-slate-500">Password</h4>
          <button v-if="!pwOpen" @click="openPassword"
            class="text-xs text-slate-600 hover:text-slate-300 transition-colors">
            Change
          </button>
        </div>

        <div v-if="!pwOpen" class="bg-[#111120] border border-slate-800 rounded-xl px-4 py-3">
          <span class="text-slate-600 text-sm tracking-widest select-none">••••••••</span>
        </div>

        <div v-else class="bg-[#0d0d1f] border border-blue-500/30 rounded-xl p-4 space-y-3">
          <div v-if="pwSuccess" class="flex items-center gap-2 text-green-400 text-sm py-1">
            <svg class="w-4 h-4 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
            </svg>
            Password updated successfully.
          </div>

          <template v-else>
            <div>
              <label class="block text-xs text-slate-500 mb-1">Current password</label>
              <input v-model="pwForm.current" type="password" placeholder="••••••••" autofocus
                class="w-full bg-[#111120] border border-slate-700/60 rounded-lg px-3 py-1.5 text-sm text-slate-200 placeholder-slate-600 focus:outline-none focus:border-blue-500/60"/>
            </div>
            <div class="grid grid-cols-2 gap-2.5">
              <div>
                <label class="block text-xs text-slate-500 mb-1">New password</label>
                <input v-model="pwForm.next" type="password" placeholder="Min. 6 chars"
                  class="w-full bg-[#111120] border border-slate-700/60 rounded-lg px-3 py-1.5 text-sm text-slate-200 placeholder-slate-600 focus:outline-none focus:border-blue-500/60"/>
              </div>
              <div>
                <label class="block text-xs text-slate-500 mb-1">Confirm</label>
                <input v-model="pwForm.confirm" type="password" placeholder="Repeat"
                  @keydown.enter="submitPassword"
                  class="w-full bg-[#111120] border border-slate-700/60 rounded-lg px-3 py-1.5 text-sm text-slate-200 placeholder-slate-600 focus:outline-none focus:border-blue-500/60"/>
              </div>
            </div>
            <p v-if="pwError" class="text-red-400 text-xs">{{ pwError }}</p>
            <div class="flex gap-2">
              <button @click="submitPassword" :disabled="pwLoading || !pwForm.current || !pwForm.next"
                class="px-3 py-1.5 bg-blue-600 hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed text-white text-sm font-medium rounded-lg transition-colors">
                {{ pwLoading ? 'Saving…' : 'Update password' }}
              </button>
              <button @click="pwOpen = false"
                class="px-3 py-1.5 text-slate-500 hover:text-slate-200 text-sm transition-colors">
                Cancel
              </button>
            </div>
          </template>
        </div>
      </div>

    </template>
  </div>
</template>
