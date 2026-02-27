<script setup lang="ts">
export interface LabelEntry { key: string; value: string }

const props = defineProps<{ modelValue: LabelEntry[] }>()
const emit  = defineEmits<{ 'update:modelValue': [v: LabelEntry[]] }>()

function add()                { emit('update:modelValue', [...props.modelValue, { key: '', value: '' }]) }
function remove(i: number)    { emit('update:modelValue', props.modelValue.filter((_, idx) => idx !== i)) }
function update(i: number, field: 'key' | 'value', val: string) {
  emit('update:modelValue', props.modelValue.map((e, idx) => idx === i ? { ...e, [field]: val } : e))
}
</script>

<template>
  <div class="space-y-2">
    <div v-if="modelValue.length === 0" class="text-sm text-slate-500 py-2">No labels.</div>
    <div v-for="(lbl, i) in modelValue" :key="i" class="flex items-center gap-2">
      <input
        :value="lbl.key" placeholder="label.key"
        @input="update(i, 'key', ($event.target as HTMLInputElement).value)"
        class="flex-1 bg-[#0a0a14] border border-slate-700/60 rounded-lg px-2 py-1.5 text-sm font-mono text-slate-200 focus:outline-none focus:border-blue-500/60"
      />
      <span class="text-slate-500 text-sm">=</span>
      <input
        :value="lbl.value" placeholder="value"
        @input="update(i, 'value', ($event.target as HTMLInputElement).value)"
        class="flex-1 bg-[#0a0a14] border border-slate-700/60 rounded-lg px-2 py-1.5 text-sm font-mono text-slate-200 focus:outline-none focus:border-blue-500/60"
      />
      <button @click="remove(i)" class="p-1.5 text-slate-500 hover:text-red-400 transition-colors">
        <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12"/>
        </svg>
      </button>
    </div>
    <button
      @click="add"
      class="flex items-center gap-1.5 text-sm text-blue-400 hover:text-blue-300 transition-colors"
    >
      <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
        <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4"/>
      </svg>
      Add label
    </button>
  </div>
</template>
