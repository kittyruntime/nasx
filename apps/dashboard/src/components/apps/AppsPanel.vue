<script setup lang="ts">
import { useAuth } from '../../lib/auth'
import AppList from './AppList.vue'

const { isAdmin } = useAuth()
</script>

<template>
  <div class="flex h-full">
    <div v-if="!isAdmin" class="flex items-center justify-center w-full text-slate-500 text-sm">
      Administrator access required.
    </div>
    <AppList v-else class="h-full w-full" />
  </div>
</template>
