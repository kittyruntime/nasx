<script setup lang="ts">
type Entry = { name: string; path: string; type: 'dir' | 'file'; size: number | null; mtime: string }

const props = defineProps<{
  entries: Entry[]
  selected: Set<string>
  renamingPath: string | null
  renameValue: string
}>()

const emit = defineEmits<{
  rowClick: [entry: Entry, event: MouseEvent]
  selectEntry: [entry: Entry, event: MouseEvent]
  startRename: [entry: Entry]
  commitRename: []
  cancelRename: []
  'update:renameValue': [value: string]
  selectAll: []
  clearSelection: []
}>()

function formatSize(bytes: number | null): string {
  if (bytes === null) return '—'
  if (bytes === 0)    return '0 B'
  if (bytes < 1024)   return bytes + ' B'
  if (bytes < 1024 ** 2) return (bytes / 1024).toFixed(1) + ' KB'
  if (bytes < 1024 ** 3) return (bytes / 1024 ** 2).toFixed(1) + ' MB'
  return (bytes / 1024 ** 3).toFixed(2) + ' GB'
}

function formatDate(mtime: string): string {
  return new Date(mtime).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' })
}

function fileExt(name: string): string {
  return name.includes('.') ? name.split('.').pop()!.toUpperCase() : ''
}
</script>

<template>
  <table class="w-full text-sm">
    <thead class="sticky top-0 bg-[#0f0f1a] border-b border-slate-800/60 z-10">
      <tr class="text-left text-xs uppercase tracking-wider text-slate-600">
        <th class="pl-3 pr-1 py-2.5 w-7">
          <input type="checkbox"
            :checked="selected.size === entries.length && entries.length > 0"
            :indeterminate="selected.size > 0 && selected.size < entries.length"
            @change="selected.size > 0 ? emit('clearSelection') : emit('selectAll')"
            class="w-3.5 h-3.5 rounded accent-blue-500 cursor-pointer opacity-40 hover:opacity-90 transition-opacity"
          />
        </th>
        <th class="px-3 py-2.5 font-medium">Name</th>
        <th class="px-3 py-2.5 font-medium text-right">Size</th>
        <th class="px-3 py-2.5 font-medium text-right">Modified</th>
      </tr>
    </thead>
    <tbody class="divide-y divide-slate-800/40">
      <tr
        v-for="entry in entries"
        :key="entry.path"
        @click.stop="emit('rowClick', entry, $event)"
        @mousedown.shift.prevent
        :class="['group transition-colors',
          entry.type === 'dir' ? 'cursor-pointer hover:bg-slate-800/40' : 'cursor-default hover:bg-slate-800/20',
          selected.has(entry.path) ? 'bg-blue-600/10' : '']"
      >
        <!-- Checkbox -->
        <td class="pl-3 pr-1 py-2.5 w-7" @click.stop>
          <div
            @click="emit('selectEntry', entry, $event)"
            :class="['w-4 h-4 rounded border flex items-center justify-center transition-all cursor-pointer',
              selected.has(entry.path)
                ? 'bg-blue-500 border-blue-500 opacity-100'
                : 'border-slate-600 bg-transparent opacity-0 group-hover:opacity-50']">
            <svg v-if="selected.has(entry.path)" class="w-2.5 h-2.5 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="3">
              <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
            </svg>
          </div>
        </td>

        <!-- Name -->
        <td class="px-3 py-2.5">
          <div class="flex items-center gap-2.5">
            <svg v-if="entry.type === 'dir'" class="w-4 h-4 text-blue-400 shrink-0" fill="currentColor" viewBox="0 0 20 20">
              <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z"/>
            </svg>
            <svg v-else class="w-4 h-4 text-slate-600 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
              <path stroke-linecap="round" stroke-linejoin="round" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/>
            </svg>

            <template v-if="renamingPath === entry.path">
              <input
                :value="renameValue"
                @input="emit('update:renameValue', ($event.target as HTMLInputElement).value)"
                @click.stop
                @keydown.enter="emit('commitRename')"
                @keydown.escape="emit('cancelRename')"
                @blur="emit('cancelRename')"
                @focus="($event.target as HTMLInputElement).select()"
                autofocus
                class="bg-[#1a1a2e] border border-blue-500/60 rounded px-2 py-0.5 text-sm text-slate-200 focus:outline-none flex-1 min-w-0"
              />
            </template>
            <template v-else>
              <span
                @dblclick.stop="emit('startRename', entry)"
                :title="entry.name"
                :class="['transition-colors truncate select-none',
                  entry.type === 'dir'
                    ? 'text-slate-200 hover:text-white'
                    : 'text-slate-400 hover:text-slate-200']">
                {{ entry.name }}
              </span>
              <span v-if="entry.type === 'file' && fileExt(entry.name)" class="text-slate-600 text-[10px] font-mono shrink-0">
                {{ fileExt(entry.name) }}
              </span>
            </template>
          </div>
        </td>

        <td class="px-3 py-2.5 text-right text-slate-500 font-mono text-xs tabular-nums">{{ formatSize(entry.size) }}</td>
        <td class="px-3 py-2.5 text-right text-slate-500 text-xs tabular-nums">{{ formatDate(entry.mtime) }}</td>
      </tr>
    </tbody>
  </table>
</template>
