<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { useRouter } from 'vue-router'
import { useAuth } from '../lib/auth'
import { useUploads } from '../lib/uploads'
import { useNotifications } from '../lib/notifications'
import SettingsPanel from '../components/SettingsPanel.vue'
import FileBrowserPanel from '../components/file-browser/FileBrowserPanel.vue'
import NotificationsContainer from '../components/NotificationsContainer.vue'
import NotificationMenu from '../components/NotificationMenu.vue'

const router = useRouter()
const { currentUsername, isAdmin, logout } = useAuth()
const uploads = useUploads()
const { notifications } = useNotifications()

const activeApp      = ref<string>('settings')
const notifMenuOpen  = ref(false)
const userMenuOpen   = ref(false)

const badgeCount = computed(() =>
  uploads.tasks.value.filter(t => t.status === 'uploading' || t.status === 'paused').length
  + notifications.value.length
)

const bellRef     = ref<HTMLButtonElement | null>(null)
const notifPos    = ref({ bottom: 16, left: 72 })
const avatarRef   = ref<HTMLButtonElement | null>(null)
const dropdownPos = ref({ bottom: 16, left: 72 })

const initials = computed(() =>
  (currentUsername.value ?? 'U').slice(0, 2).toUpperCase()
)

const activeAppLabel = computed(() => {
  if (activeApp.value === 'files') return 'Files'
  if (activeApp.value === 'settings') return 'Settings'
  return 'Overview'
})

function selectApp(id: string) {
  activeApp.value = id
  userMenuOpen.value = false
  notifMenuOpen.value = false
}

function isActive(id: string) {
  return activeApp.value === id
}

function toggleNotifMenu() {
  if (bellRef.value) {
    const rect = bellRef.value.getBoundingClientRect()
    notifPos.value = {
      bottom: window.innerHeight - rect.bottom,
      left:   rect.right + 8,
    }
  }
  notifMenuOpen.value = !notifMenuOpen.value
  userMenuOpen.value = false
}

function toggleUserMenu() {
  if (!userMenuOpen.value && avatarRef.value) {
    const rect = avatarRef.value.getBoundingClientRect()
    dropdownPos.value = {
      bottom: window.innerHeight - rect.bottom,
      left:   rect.right + 8,
    }
  }
  userMenuOpen.value = !userMenuOpen.value
  notifMenuOpen.value = false
}

function handleLogout() {
  logout()
  router.push('/login')
}

function closeUserMenu() {
  userMenuOpen.value = false
}

onMounted(() => document.addEventListener('click', closeUserMenu))
onUnmounted(() => document.removeEventListener('click', closeUserMenu))
</script>

<template>
  <div class="flex h-screen w-screen bg-[#0f0f1a]">

    <!-- Sidebar: 64px -->
    <aside class="flex flex-col items-center w-16 bg-[#080812] border-r border-slate-800/50 py-4 flex-shrink-0">

      <!-- Brand mark -->
      <div class="w-8 h-8 rounded-lg bg-blue-600 flex items-center justify-center text-white text-[10px] font-bold mb-5 tracking-wider select-none">
        NX
      </div>

      <div class="w-8 border-t border-slate-800 mb-3" />

      <!-- App nav -->
      <nav class="flex flex-col items-stretch gap-1 flex-1 w-full">

        <!-- Files -->
        <div class="relative flex justify-center py-0.5">
          <span
            v-if="isActive('files')"
            class="absolute left-0 top-1/2 -translate-y-1/2 w-0.5 h-6 bg-blue-500 rounded-r-full"
          />
          <button
            @click="selectApp('files')"
            title="Files"
            :class="[
              'w-10 h-10 rounded-xl flex items-center justify-center transition-all duration-150',
              isActive('files')
                ? 'bg-blue-600/15 text-blue-400'
                : 'text-slate-500 hover:bg-slate-800/70 hover:text-slate-200',
            ]"
          >
            <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.75">
              <path stroke-linecap="round" stroke-linejoin="round" d="M3 7a2 2 0 012-2h3.586a1 1 0 01.707.293L11 7h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2V7z"/>
            </svg>
          </button>
        </div>

        <!-- Settings -->
        <div class="relative flex justify-center py-0.5">
          <span
            v-if="isActive('settings')"
            class="absolute left-0 top-1/2 -translate-y-1/2 w-0.5 h-6 bg-blue-500 rounded-r-full"
          />
          <button
            @click="selectApp('settings')"
            title="Settings"
            :class="[
              'w-10 h-10 rounded-xl flex items-center justify-center transition-all duration-150',
              isActive('settings')
                ? 'bg-blue-600/15 text-blue-400'
                : 'text-slate-500 hover:bg-slate-800/70 hover:text-slate-200',
            ]"
          >
            <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.75">
              <path stroke-linecap="round" stroke-linejoin="round" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
              <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
            </svg>
          </button>
        </div>

      </nav>

      <!-- Notifications bell -->
      <button
        ref="bellRef"
        @click="toggleNotifMenu"
        title="Activity"
        class="relative w-10 h-10 rounded-xl flex items-center justify-center transition-all duration-150 mb-2"
        :class="notifMenuOpen
          ? 'bg-blue-600/15 text-blue-400'
          : 'text-slate-500 hover:bg-slate-800/70 hover:text-slate-200'"
      >
        <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.75">
          <path stroke-linecap="round" stroke-linejoin="round" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"/>
        </svg>
        <span
          v-if="badgeCount > 0"
          class="absolute top-1.5 right-1.5 min-w-[14px] h-3.5 px-0.5 bg-blue-500 rounded-full text-[8px] font-bold text-white flex items-center justify-center tabular-nums leading-none"
        >{{ badgeCount > 9 ? '9+' : badgeCount }}</span>
      </button>

      <!-- User avatar -->
      <button
        ref="avatarRef"
        @click="toggleUserMenu"
        title="Account"
        class="w-9 h-9 rounded-full bg-gradient-to-br from-blue-500 to-violet-600 flex items-center
               justify-center text-white text-xs font-bold select-none transition-all duration-150"
        :class="userMenuOpen
          ? 'ring-2 ring-blue-400/60 ring-offset-2 ring-offset-[#080812]'
          : 'hover:ring-2 hover:ring-slate-600/80 hover:ring-offset-2 hover:ring-offset-[#080812]'"
      >
        {{ initials }}
      </button>
    </aside>

    <!-- User dropdown -->
    <Teleport to="body">
      <Transition name="menu">
        <div
          v-if="userMenuOpen"
          @click.stop
          class="fixed z-50 bg-[#111120] border border-slate-700/60 rounded-xl shadow-2xl overflow-hidden"
          :style="{
            bottom: dropdownPos.bottom + 'px',
            left: dropdownPos.left + 'px',
            minWidth: '200px',
          }"
        >
          <div class="flex items-center gap-3 px-4 py-3.5 border-b border-slate-800">
            <div class="w-8 h-8 rounded-full bg-gradient-to-br from-blue-500 to-violet-600 flex items-center justify-center text-white text-xs font-bold shrink-0">
              {{ initials }}
            </div>
            <div class="min-w-0">
              <div class="text-slate-200 text-sm font-medium truncate">{{ currentUsername }}</div>
              <div class="text-slate-500 text-xs">{{ isAdmin ? 'Administrator' : 'User' }}</div>
            </div>
          </div>
          <div class="p-1.5">
            <button
              @click="handleLogout"
              class="w-full flex items-center gap-2.5 px-3 py-2 text-sm text-slate-300
                     hover:bg-slate-800/80 rounded-lg transition-colors text-left"
            >
              <svg class="w-4 h-4 text-slate-400 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1" />
              </svg>
              Sign out
            </button>
          </div>
        </div>
      </Transition>
    </Teleport>

    <!-- Main area -->
    <main class="flex-1 flex flex-col overflow-hidden">

      <!-- Top bar -->
      <header class="h-11 flex items-center px-6 border-b border-slate-800/50 flex-shrink-0 bg-[#0a0a14]/60 backdrop-blur-sm">
        <span class="text-sm font-medium text-slate-300">{{ activeAppLabel }}</span>
      </header>

      <!-- Content -->
      <div :class="['flex-1', activeApp !== 'overview' ? 'overflow-hidden' : 'overflow-auto']">
        <FileBrowserPanel v-if="activeApp === 'files'" class="h-full" />
        <SettingsPanel v-else-if="activeApp === 'settings'" class="h-full" />
        <div v-else class="flex items-center justify-center h-full text-slate-700 select-none">
          <div class="text-center space-y-3">
            <svg class="w-12 h-12 mx-auto opacity-20" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1">
              <path stroke-linecap="round" stroke-linejoin="round" d="M9 17V7m0 10a2 2 0 01-2 2H5a2 2 0 01-2-2V7a2 2 0 012-2h2a2 2 0 012 2m0 10a2 2 0 002 2h2a2 2 0 002-2M9 7a2 2 0 012-2h2a2 2 0 012 2m0 10V7m0 10a2 2 0 002 2h2a2 2 0 002-2V7a2 2 0 00-2-2h-2a2 2 0 00-2 2" />
            </svg>
            <p class="text-sm">Select an app from the sidebar</p>
          </div>
        </div>
      </div>

    </main>
  </div>

  <NotificationsContainer />
  <NotificationMenu
    :open="notifMenuOpen"
    :pos="notifPos"
    @close="notifMenuOpen = false"
  />
</template>

<style scoped>
.menu-enter-active,
.menu-leave-active {
  transition: opacity 0.15s ease, transform 0.15s ease;
}
.menu-enter-from,
.menu-leave-to {
  opacity: 0;
  transform: translateY(6px);
}
</style>
