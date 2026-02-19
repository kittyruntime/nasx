<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { trpc } from '../lib/trpc'
import { useAuth } from '../lib/auth'
import { useNotifications } from '../lib/notifications'
import { useClipboard } from '../lib/clipboard'
import { useUploads } from '../lib/uploads'
import FilePermissionsDialog from './FilePermissionsDialog.vue'

type Entry = { name: string; path: string; type: 'dir' | 'file'; size: number | null; mtime: string }
type Place = { id: string; name: string; path: string }

const { isAdmin, token }       = useAuth()
const { track, trackBatch }    = useNotifications()
const { clipboard, copy: clipCopy, cut: clipCut, clear: clipClear } = useClipboard()
const uploads = useUploads()

// ── constants ──────────────────────────────────────────────────────────────
const BASE_URL   = (import.meta.env.VITE_API_URL ?? 'http://localhost:9001/trpc').replace(/\/trpc$/, '')
const CHUNK_SIZE = 2 * 1024 * 1024   // 2 MB

// ── state ──────────────────────────────────────────────────────────────────
const currentPath   = ref<string | null>(null)
const entries       = ref<Entry[]>([])
const dbPlaces      = ref<Place[]>([])
const viewMode      = ref<'list' | 'grid'>('list')
const loading       = ref(false)
const error         = ref('')
const selected          = ref<Set<string>>(new Set())
const selectionAnchor   = ref<string | null>(null)
const renamingPath  = ref<string | null>(null)
const renameValue   = ref('')
const permDialogPath = ref<string | null>(null)
const activePlaceId = ref<string | null>(null)

// ── upload state ────────────────────────────────────────────────────────────
const dragOver  = ref(false)
let   dragDepth = 0
const fileInput = ref<HTMLInputElement | null>(null)

// ── places ─────────────────────────────────────────────────────────────────
const VIRTUAL_ROOT: Place = { id: '__root__', name: 'Root', path: '/' }
const allPlaces = computed((): Place[] =>
  isAdmin.value ? [VIRTUAL_ROOT, ...dbPlaces.value] : dbPlaces.value
)
const activePlace = computed(() =>
  activePlaceId.value ? allPlaces.value.find(p => p.id === activePlaceId.value) ?? null : null
)

// ── breadcrumbs ─────────────────────────────────────────────────────────────
interface Crumb { label: string; path: string; clickable: boolean }
const breadcrumbs = computed((): Crumb[] => {
  if (!currentPath.value || !activePlace.value) return []
  const place = activePlace.value

  if (place.id === '__root__') {
    const segments = currentPath.value.split('/').filter(Boolean)
    const crumbs: Crumb[] = [{ label: '/', path: '/', clickable: segments.length > 0 }]
    let acc = ''
    for (let i = 0; i < segments.length; i++) {
      acc += '/' + segments[i]
      crumbs.push({ label: segments[i]!, path: acc, clickable: i < segments.length - 1 })
    }
    return crumbs
  }

  const relative = currentPath.value.slice(place.path.length).split('/').filter(Boolean)
  const crumbs: Crumb[] = [{ label: place.name, path: place.path, clickable: relative.length > 0 }]
  let acc = place.path
  for (let i = 0; i < relative.length; i++) {
    acc += '/' + relative[i]
    crumbs.push({ label: relative[i]!, path: acc, clickable: i < relative.length - 1 })
  }
  return crumbs
})

// ── navigation ──────────────────────────────────────────────────────────────
function selectPlace(place: Place) {
  activePlaceId.value = place.id
  selected.value = new Set()
  navigate(place.path)
}

const canGoUp = computed(() => {
  if (!currentPath.value || !activePlace.value) return false
  if (activePlace.value.id === '__root__') return currentPath.value !== '/'
  return currentPath.value !== activePlace.value.path
})

async function navigate(path: string) {
  loading.value = true
  error.value = ''
  selected.value = new Set()
  selectionAnchor.value = null
  try {
    entries.value = (await trpc.fs.list.query({ path })) as Entry[]
    currentPath.value = path
  } catch (e: any) {
    error.value = e?.message ?? 'Failed to read directory'
  } finally {
    loading.value = false
  }
}

function goUp() {
  if (!currentPath.value || !activePlace.value) return
  const parent = currentPath.value.substring(0, currentPath.value.lastIndexOf('/')) || '/'
  if (!isAdmin.value && parent.length < activePlace.value.path.length) return
  navigate(parent)
}

function refresh() {
  if (currentPath.value) navigate(currentPath.value)
}

// ── selection ───────────────────────────────────────────────────────────────

// Core selection handler — respects Shift (range) and Ctrl/Meta (toggle).
function selectEntry(entry: Entry, e: MouseEvent) {
  e.stopPropagation()

  if (e.shiftKey && selectionAnchor.value !== null) {
    // Range: extend from anchor to this entry, keep existing selection
    const paths = entries.value.map(en => en.path)
    const fromIdx = paths.indexOf(selectionAnchor.value)
    const toIdx   = paths.indexOf(entry.path)
    if (fromIdx !== -1) {
      const [lo, hi] = fromIdx <= toIdx ? [fromIdx, toIdx] : [toIdx, fromIdx]
      const next = new Set(selected.value)
      for (let i = lo; i <= hi; i++) next.add(paths[i]!)
      selected.value = next
    }
    // anchor stays fixed during range extension
  } else {
    // Ctrl/Meta or plain checkbox click: toggle individual item
    const next = new Set(selected.value)
    if (next.has(entry.path)) next.delete(entry.path)
    else next.add(entry.path)
    selected.value = next
    selectionAnchor.value = entry.path
  }
}

// Row click: selection when modifier held, otherwise default action.
function handleRowClick(entry: Entry, e: MouseEvent) {
  if (e.shiftKey || e.ctrlKey || e.metaKey) {
    selectEntry(entry, e)
  } else if (entry.type === 'dir') {
    navigate(entry.path)
  }
}

// Grid card click: same as row but plain click on files also toggles.
function handleGridCardClick(entry: Entry, e: MouseEvent) {
  if (e.shiftKey || e.ctrlKey || e.metaKey) {
    selectEntry(entry, e)
  } else if (entry.type === 'dir') {
    navigate(entry.path)
  } else {
    selectEntry(entry, e)
  }
}

function selectAll() {
  selected.value = new Set(entries.value.map(e => e.path))
  selectionAnchor.value = null
}

function clearSelection() {
  selected.value = new Set()
  selectionAnchor.value = null
}

const selectedEntries = computed(() =>
  entries.value.filter(e => selected.value.has(e.path))
)

// ── file operations ──────────────────────────────────────────────────────────
async function createFolder() {
  if (!currentPath.value) return
  await track('Creating folder', async () => {
    await trpc.fs.mkdir.mutate({ parentPath: currentPath.value!, name: 'New Folder' })
  })
  refresh()
}

// ── upload ───────────────────────────────────────────────────────────────────
async function uploadFiles(files: FileList | File[]) {
  if (!currentPath.value) return
  const dest = currentPath.value

  for (const file of Array.from(files)) {
    const id = crypto.randomUUID?.() ?? Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join('').replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5')
    const totalChunks = Math.max(1, Math.ceil(file.size / CHUNK_SIZE))
    const ac = new AbortController()

    uploads.register({ id, name: file.name, destDir: dest, totalChunks, sentChunks: 0, status: 'uploading' })
    uploads.setAbortController(id, ac)

    try {
      for (let i = 0; i < totalChunks; i++) {
        // Spin-wait while paused
        while (uploads.isPaused(id)) {
          await new Promise(r => setTimeout(r, 200))
        }
        // Abort check (may have been cancelled during pause wait)
        if (ac.signal.aborted) throw new DOMException('Cancelled', 'AbortError')

        const resp = await fetch(`${BASE_URL}/files/upload/chunk`, {
          method: 'POST',
          signal: ac.signal,
          headers: {
            'Authorization':  `Bearer ${token.value}`,
            'Content-Type':   'application/octet-stream',
            'X-Upload-Id':    id,
            'X-Chunk-Index':  String(i),
            'X-Total-Chunks': String(totalChunks),
            'X-File-Name':    encodeURIComponent(file.name),
            'X-Dest-Dir':     encodeURIComponent(dest),
          },
          body: file.slice(i * CHUNK_SIZE, (i + 1) * CHUNK_SIZE),
        })
        if (!resp.ok) throw new Error(await resp.text())
        uploads.updateProgress(id, i + 1)
      }

      uploads.setStatus(id, 'done')
      refresh()
      setTimeout(() => uploads.remove(id), 3000)
    } catch (e: any) {
      const isAbort = e instanceof DOMException && e.name === 'AbortError'
      if (isAbort) {
        uploads.setStatus(id, 'cancelled')
        fetch(`${BASE_URL}/files/upload/cancel`, {
          method: 'DELETE',
          headers: { 'Authorization': `Bearer ${token.value}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ uploadId: id }),
        }).catch(() => {})
        setTimeout(() => uploads.remove(id), 2500)
      } else {
        uploads.setStatus(id, 'error', e.message)
      }
    } finally {
      uploads.cleanup(id)
    }
  }
}

function handleFileInput(e: Event) {
  const files = (e.target as HTMLInputElement).files
  if (files?.length) uploadFiles(files)
  ;(e.target as HTMLInputElement).value = ''
}

function handleDragEnter() { dragDepth++; dragOver.value = true }
function handleDragLeave() { if (--dragDepth === 0) dragOver.value = false }
function handleDrop(e: DragEvent) {
  dragDepth = 0; dragOver.value = false
  if (e.dataTransfer?.files?.length) uploadFiles(e.dataTransfer.files)
}

// ── download ──────────────────────────────────────────────────────────────────
function downloadSelected() {
  const entry = selectedEntries.value[0]
  if (!entry || entry.type !== 'file') return
  const url = `${BASE_URL}/files/download?path=${encodeURIComponent(entry.path)}&token=${encodeURIComponent(token.value ?? '')}`
  const a = document.createElement('a')
  a.href = url
  a.download = entry.name
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
}

function doCopy() {
  if (!selected.value.size) return
  clipCopy([...selected.value])
}

function doCut() {
  if (!selected.value.size) return
  clipCut([...selected.value])
}

async function doPaste() {
  if (!clipboard.value || !currentPath.value) return
  const { paths, mode } = clipboard.value
  const dst = currentPath.value

  await trackBatch(
    mode === 'copy' ? `Copying ${paths.length} item(s)` : `Moving ${paths.length} item(s)`,
    paths.map(src => async () => {
      if (mode === 'copy') await trpc.fs.copy.mutate({ src, dstDir: dst })
      else                 await trpc.fs.move.mutate({ src, dstDir: dst })
    })
  )

  if (mode === 'cut') clipClear()
  clearSelection()
  refresh()
}

async function doDelete() {
  if (!selected.value.size) return
  const paths = [...selected.value]

  await trackBatch(
    `Deleting ${paths.length} item(s)`,
    paths.map(p => () => trpc.fs.delete.mutate({ path: p }))
  )
  clearSelection()
  refresh()
}

// ── rename ──────────────────────────────────────────────────────────────────
function startRename(entry: Entry) {
  renamingPath.value = entry.path
  renameValue.value  = entry.name
}

async function commitRename() {
  if (!renamingPath.value || !renameValue.value.trim()) { cancelRename(); return }
  const path = renamingPath.value
  const name = renameValue.value.trim()
  renamingPath.value = null
  await track(`Renaming to "${name}"`, () =>
    trpc.fs.rename.mutate({ path, newName: name })
  )
  refresh()
}

function cancelRename() {
  renamingPath.value = null
  renameValue.value  = ''
}

// ── permissions dialog ───────────────────────────────────────────────────────
function openPermissions() {
  if (selected.value.size !== 1) return
  permDialogPath.value = [...selected.value][0]!
}

// ── display helpers ──────────────────────────────────────────────────────────
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

// ── init ─────────────────────────────────────────────────────────────────────
onMounted(async () => {
  dbPlaces.value = (await trpc.place.list.query()) as Place[]
})
</script>

<template>
  <div class="flex h-full" @click="clearSelection">

    <!-- ── LEFT: places sidebar ─────────────────────────────────────────── -->
    <aside class="w-44 flex-shrink-0 border-r border-slate-800/50 bg-[#080812] flex flex-col">
      <div class="px-3 pt-3.5 pb-2 text-[10px] font-semibold uppercase tracking-widest text-slate-600 select-none">
        Places
      </div>
      <nav class="flex flex-col gap-0.5 px-2 pb-3 overflow-y-auto flex-1">
        <button
          v-for="place in allPlaces"
          :key="place.id"
          @click.stop="selectPlace(place)"
          :class="[
            'flex items-center gap-2.5 w-full px-2.5 py-2 rounded-lg text-left text-sm transition-colors',
            activePlace?.id === place.id
              ? 'bg-blue-600/15 text-blue-300'
              : 'text-slate-400 hover:bg-slate-800/60 hover:text-slate-200',
          ]"
        >
          <svg v-if="place.id === '__root__'" class="w-3.5 h-3.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.75">
            <path stroke-linecap="round" stroke-linejoin="round" d="M5.25 14.25h13.5m-13.5 0a3 3 0 01-3-3m3 3a3 3 0 100 6h13.5a3 3 0 100-6m-13.5 0v-1.5m13.5 1.5v-1.5m0-10.5a3 3 0 00-3-3H9.75a3 3 0 00-3 3m9.75 0a3 3 0 01-3 3h-3a3 3 0 01-3-3m9.75 0H4.5m15 0h.008v.008H19.5v-.008z"/>
          </svg>
          <svg v-else class="w-3.5 h-3.5 shrink-0" fill="currentColor" viewBox="0 0 20 20">
            <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z"/>
          </svg>
          <span class="truncate">{{ place.name }}</span>
        </button>
        <p v-if="allPlaces.length === 0" class="text-xs text-slate-600 italic px-2.5 py-2">No places configured.</p>
      </nav>
    </aside>

    <!-- ── RIGHT: file browser ────────────────────────────────────────────── -->
    <div class="flex-1 flex flex-col min-w-0">

      <!-- ── Toolbar ───────────────────────────────────────────────────── -->
      <div class="flex items-center gap-1.5 px-3 py-2 border-b border-slate-800/60 bg-[#0a0a14]/40 flex-shrink-0 min-h-[42px]" @click.stop>

        <!-- Back / Up -->
        <button v-if="canGoUp" @click="goUp" title="Go up"
          class="p-1.5 rounded-lg text-slate-500 hover:text-slate-200 hover:bg-slate-800 transition-colors flex-shrink-0">
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5">
            <path stroke-linecap="round" stroke-linejoin="round" d="M10 19l-7-7m0 0l7-7m-7 7h18"/>
          </svg>
        </button>

        <!-- Breadcrumb -->
        <nav v-if="currentPath" class="flex items-center gap-0.5 text-sm flex-1 min-w-0 overflow-x-auto">
          <template v-for="(crumb, i) in breadcrumbs" :key="i">
            <span v-if="i > 0" class="text-slate-700 select-none mx-0.5 flex-shrink-0">›</span>
            <button v-if="crumb.clickable" @click="navigate(crumb.path)"
              class="px-1 py-0.5 text-slate-400 hover:text-slate-200 rounded hover:bg-slate-800/60 transition-colors whitespace-nowrap flex-shrink-0">
              {{ crumb.label }}
            </button>
            <span v-else class="px-1 text-slate-200 whitespace-nowrap flex-shrink-0 truncate">{{ crumb.label }}</span>
          </template>
        </nav>
        <div v-else class="flex-1" />

        <!-- Right-side toolbar -->
        <div class="flex items-center gap-0.5 flex-shrink-0 ml-auto">

          <!-- ── Selection context actions (inline, no layout shift) ── -->
          <template v-if="selected.size > 0">
            <span class="text-xs tabular-nums text-slate-500 select-none pl-1 pr-0.5">{{ selected.size }} sel.</span>
            <button @click="clearSelection" title="Clear selection"
              class="p-1 rounded text-slate-600 hover:text-slate-300 transition-colors">
              <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5">
                <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12"/>
              </svg>
            </button>
            <div class="w-px h-3.5 bg-slate-800 mx-0.5 flex-shrink-0" />

            <button @click="doCopy" title="Copy" class="sel-btn">
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/>
              </svg>
            </button>
            <button @click="doCut" title="Cut" class="sel-btn">
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M14.121 14.121L19 19m-7-7l7-7m-7 7l-2.879 2.879M12 12L9.121 9.121m0 5.758a3 3 0 10-4.243 4.243 3 3 0 004.243-4.243zm0-5.758a3 3 0 10-4.243-4.243 3 3 0 004.243 4.243z"/>
              </svg>
            </button>
            <template v-if="selected.size === 1">
              <button @click="startRename(selectedEntries[0]!)" title="Rename" class="sel-btn">
                <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M15.232 5.232l3.536 3.536m-2.036-5.036a2.5 2.5 0 113.536 3.536L6.5 21.036H3v-3.572L16.732 3.732z"/>
                </svg>
              </button>
              <button v-if="selectedEntries[0]?.type === 'file'" @click="downloadSelected" title="Download" class="sel-btn">
                <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/>
                </svg>
              </button>
              <button @click="openPermissions" title="Permissions" class="sel-btn">
                <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
                </svg>
              </button>
            </template>
            <button @click="doDelete" title="Delete" class="sel-btn sel-btn-danger">
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
              </svg>
            </button>
            <div class="w-px h-3.5 bg-slate-800 mx-0.5 flex-shrink-0" />
          </template>

          <!-- New Folder -->
          <button v-if="currentPath" @click="createFolder" title="New Folder"
            class="flex items-center gap-1 px-2 py-1.5 rounded-lg text-slate-500 hover:text-slate-200 hover:bg-slate-800 transition-colors text-xs">
            <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M9 13h6m-3-3v6m-9 1V7a2 2 0 012-2h6l2 2h6a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/>
            </svg>
            New folder
          </button>

          <!-- Upload -->
          <button v-if="currentPath" @click="fileInput?.click()" title="Upload files"
            class="flex items-center gap-1 px-2 py-1.5 rounded-lg text-slate-500 hover:text-slate-200 hover:bg-slate-800 transition-colors text-xs">
            <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"/>
            </svg>
            Upload
          </button>
          <input ref="fileInput" type="file" multiple class="hidden" @change="handleFileInput" />

          <!-- Paste -->
          <button v-if="clipboard && currentPath" @click.stop="doPaste" title="Paste"
            :class="['flex items-center gap-1 px-2 py-1.5 rounded-lg text-xs transition-colors',
              clipboard.mode === 'cut'
                ? 'bg-amber-500/15 text-amber-400 hover:bg-amber-500/25'
                : 'bg-blue-500/15 text-blue-400 hover:bg-blue-500/25']">
            <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"/>
            </svg>
            Paste {{ clipboard.mode === 'cut' ? '(move)' : '' }} {{ clipboard.paths.length > 1 ? clipboard.paths.length + ' items' : '' }}
          </button>

          <!-- Divider -->
          <div v-if="currentPath" class="w-px h-4 bg-slate-800 mx-1" />

          <!-- View toggle -->
          <div class="flex items-center gap-0.5 bg-slate-800/60 rounded-lg p-0.5">
            <button @click="viewMode = 'list'" title="List view"
              :class="['p-1.5 rounded-md transition-colors', viewMode === 'list' ? 'bg-slate-700 text-slate-100' : 'text-slate-500 hover:text-slate-300']">
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M4 6h16M4 10h16M4 14h16M4 18h16"/>
              </svg>
            </button>
            <button @click="viewMode = 'grid'" title="Grid view"
              :class="['p-1.5 rounded-md transition-colors', viewMode === 'grid' ? 'bg-slate-700 text-slate-100' : 'text-slate-500 hover:text-slate-300']">
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M4 5a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1V5zM14 5a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1V5zM4 15a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1v-4zM14 15a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1v-4z"/>
              </svg>
            </button>
          </div>
        </div>
      </div>

      <!-- ── Content area ───────────────────────────────────────────────── -->
      <div class="flex-1 overflow-auto relative"
        @dragenter="handleDragEnter"
        @dragleave="handleDragLeave"
        @dragover.prevent
        @drop.prevent="handleDrop">

        <!-- Drag-and-drop overlay -->
        <div v-if="dragOver && currentPath"
          class="absolute inset-0 z-40 flex flex-col items-center justify-center gap-3 bg-blue-950/60 border-2 border-dashed border-blue-400/50 rounded pointer-events-none select-none">
          <svg class="w-10 h-10 text-blue-400 opacity-80" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
            <path stroke-linecap="round" stroke-linejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"/>
          </svg>
          <span class="text-sm text-blue-300 font-medium">Drop to upload</span>
        </div>

        <!-- Loading -->
        <div v-if="loading" class="flex items-center gap-2 text-slate-500 text-sm p-6">
          <svg class="w-4 h-4 animate-spin shrink-0" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-20" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"/>
          </svg>
          Loading…
        </div>

        <!-- Error -->
        <div v-else-if="error" class="flex items-center gap-2 text-red-400 text-sm p-6">
          <svg class="w-4 h-4 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
            <path stroke-linecap="round" stroke-linejoin="round" d="M12 9v2m0 4h.01M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/>
          </svg>
          {{ error }}
        </div>

        <!-- No place selected -->
        <div v-else-if="!currentPath" class="flex items-center justify-center h-full text-slate-700 select-none">
          <div class="text-center space-y-2">
            <svg class="w-10 h-10 mx-auto opacity-20" fill="currentColor" viewBox="0 0 20 20">
              <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z"/>
            </svg>
            <p class="text-sm">Select a place</p>
          </div>
        </div>

        <!-- Empty directory -->
        <div v-else-if="entries.length === 0" class="flex items-center justify-center h-full text-slate-700 select-none">
          <p class="text-sm">Empty directory</p>
        </div>

        <!-- ── GRID VIEW ── -->
        <div v-else-if="viewMode === 'grid'" class="p-3 grid gap-1"
          style="grid-template-columns: repeat(auto-fill, minmax(108px, 1fr))">
          <div
            v-for="entry in entries"
            :key="entry.path"
            @click.stop="handleGridCardClick(entry, $event)"
            @mousedown.shift.prevent
            :class="[
              'group relative flex flex-col items-center gap-1.5 px-2 pt-3 pb-2.5 rounded-xl transition-colors cursor-pointer select-none',
              selected.has(entry.path) ? 'bg-blue-600/20 ring-1 ring-blue-500/40' : 'hover:bg-slate-800/50',
            ]"
          >
            <!-- Checkbox -->
            <div
              @click.stop="selectEntry(entry, $event)"
              :class="['absolute top-1.5 left-1.5 w-4 h-4 rounded border flex items-center justify-center transition-all',
                selected.has(entry.path)
                  ? 'opacity-100 bg-blue-500 border-blue-500'
                  : 'opacity-0 group-hover:opacity-60 border-slate-600 bg-slate-900/80']">
              <svg v-if="selected.has(entry.path)" class="w-2.5 h-2.5 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="3">
                <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
              </svg>
            </div>

            <svg v-if="entry.type === 'dir'" class="w-11 h-11 text-blue-400 shrink-0" fill="currentColor" viewBox="0 0 24 24">
              <path d="M19.5 21a3 3 0 003-3v-4.5a3 3 0 00-3-3h-15a3 3 0 00-3 3V18a3 3 0 003 3h15zM1.5 10.146V6a3 3 0 013-3h5.379a2.25 2.25 0 011.59.659l2.122 2.121c.14.141.331.22.53.22H19.5a3 3 0 013 3v1.146A4.483 4.483 0 0019.5 9h-15a4.483 4.483 0 00-3 1.146z"/>
            </svg>
            <div v-else class="w-11 h-11 relative flex items-center justify-center flex-shrink-0">
              <svg class="w-9 h-11 text-slate-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.25">
                <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z"/>
              </svg>
              <span v-if="fileExt(entry.name)" class="absolute bottom-0.5 text-[8px] font-bold text-slate-500 bg-[#0f0f1a] px-1 rounded leading-tight">
                {{ fileExt(entry.name) }}
              </span>
            </div>

            <!-- Name: click to rename -->
            <template v-if="renamingPath === entry.path">
              <input
                v-model="renameValue"
                @click.stop
                @keydown.enter="commitRename"
                @keydown.escape="cancelRename"
                @blur="cancelRename"
                @focus="($event.target as HTMLInputElement).select()"
                autofocus
                class="text-xs bg-[#1a1a2e] border border-blue-500/60 rounded px-1.5 py-0.5 text-slate-200 focus:outline-none w-full text-center"
              />
            </template>
            <template v-else>
              <span
                @dblclick.stop="startRename(entry)"
                class="text-xs leading-tight text-slate-300 w-full text-center truncate px-1 hover:text-white transition-colors"
                :title="entry.name">
                {{ entry.name }}
              </span>
            </template>
          </div>
        </div>

        <!-- ── LIST VIEW ── -->
        <table v-else class="w-full text-sm">
          <thead class="sticky top-0 bg-[#0f0f1a] border-b border-slate-800/60 z-10">
            <tr class="text-left text-xs uppercase tracking-wider text-slate-600">
              <th class="pl-3 pr-1 py-2.5 w-7">
                <input type="checkbox"
                  :checked="selected.size === entries.length && entries.length > 0"
                  :indeterminate="selected.size > 0 && selected.size < entries.length"
                  @change="selected.size > 0 ? clearSelection() : selectAll()"
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
              @click.stop="handleRowClick(entry, $event)"
              @mousedown.shift.prevent
              :class="['group transition-colors',
                entry.type === 'dir' ? 'cursor-pointer hover:bg-slate-800/40' : 'cursor-default hover:bg-slate-800/20',
                selected.has(entry.path) ? 'bg-blue-600/10' : '']"
            >
              <!-- Checkbox: hidden until row hover, always shown when selected -->
              <td class="pl-3 pr-1 py-2.5 w-7" @click.stop>
                <div
                  @click="selectEntry(entry, $event)"
                  :class="['w-4 h-4 rounded border flex items-center justify-center transition-all cursor-pointer',
                    selected.has(entry.path)
                      ? 'bg-blue-500 border-blue-500 opacity-100'
                      : 'border-slate-600 bg-transparent opacity-0 group-hover:opacity-50']">
                  <svg v-if="selected.has(entry.path)" class="w-2.5 h-2.5 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="3">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
                  </svg>
                </div>
              </td>

              <!-- Name: click to rename -->
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
                      v-model="renameValue"
                      @click.stop
                      @keydown.enter="commitRename"
                      @keydown.escape="cancelRename"
                      @blur="cancelRename"
                      @focus="($event.target as HTMLInputElement).select()"
                      autofocus
                      class="bg-[#1a1a2e] border border-blue-500/60 rounded px-2 py-0.5 text-sm text-slate-200 focus:outline-none flex-1 min-w-0"
                    />
                  </template>
                  <template v-else>
                    <span
                      @dblclick.stop="startRename(entry)"
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

      </div>
    </div>

  </div>

  <!-- Permissions dialog -->
  <FilePermissionsDialog
    v-if="permDialogPath"
    :path="permDialogPath"
    @close="permDialogPath = null"
  />
</template>

<style scoped>
@reference "tailwindcss";

.sel-btn {
  @apply p-1.5 rounded-lg text-slate-500 hover:text-slate-200 hover:bg-slate-800 transition-colors;
}
.sel-btn-danger {
  @apply hover:bg-red-900/30 hover:text-red-400;
}
</style>
