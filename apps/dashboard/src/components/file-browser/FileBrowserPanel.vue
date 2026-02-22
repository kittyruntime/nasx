<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { trpc } from '../../lib/trpc'
import { useAuth } from '../../lib/auth'
import { useNotifications } from '../../lib/notifications'
import { useClipboard } from '../../lib/clipboard'
import { useUploads } from '../../lib/uploads'
import FilePermissionsDialog from '../FilePermissionsDialog.vue'
import PlacesSidebar from './PlacesSidebar.vue'
import FileToolbar from './FileToolbar.vue'
import FileListView from './FileListView.vue'
import FileGridView from './FileGridView.vue'

type Entry = { name: string; path: string; type: 'dir' | 'file'; size: number | null; mtime: string }
type Place = { id: string; name: string; path: string }
interface Crumb { label: string; path: string; clickable: boolean }

const { isAdmin, token }    = useAuth()
const { track, trackBatch } = useNotifications()
const { clipboard, copy: clipCopy, cut: clipCut, clear: clipClear } = useClipboard()
const uploads = useUploads()

const BASE_URL   = (import.meta.env.VITE_API_URL ?? 'http://localhost:9001/trpc').replace(/\/trpc$/, '')
const CHUNK_SIZE = 2 * 1024 * 1024

// ── state ────────────────────────────────────────────────────────────────────
const currentPath     = ref<string | null>(null)
const entries         = ref<Entry[]>([])
const dbPlaces        = ref<Place[]>([])
const viewMode        = ref<'list' | 'grid'>('list')
const loading         = ref(false)
const error           = ref('')
const selected        = ref<Set<string>>(new Set())
const selectionAnchor = ref<string | null>(null)
const renamingPath    = ref<string | null>(null)
const renameValue     = ref('')
const permDialogPath  = ref<string | null>(null)
const activePlaceId   = ref<string | null>(null)
const dragOver        = ref(false)
let   dragDepth = 0
const fileInput = ref<HTMLInputElement | null>(null)

// ── places ───────────────────────────────────────────────────────────────────
const VIRTUAL_ROOT: Place = { id: '__root__', name: 'Root', path: '/' }

const allPlaces = computed((): Place[] =>
  isAdmin.value ? [VIRTUAL_ROOT, ...dbPlaces.value] : dbPlaces.value
)

const activePlace = computed(() =>
  activePlaceId.value ? allPlaces.value.find(p => p.id === activePlaceId.value) ?? null : null
)

// ── breadcrumbs ──────────────────────────────────────────────────────────────
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

// ── navigation ───────────────────────────────────────────────────────────────
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

// ── selection ────────────────────────────────────────────────────────────────
function selectEntry(entry: Entry, e: MouseEvent) {
  e.stopPropagation()

  if (e.shiftKey && selectionAnchor.value !== null) {
    const paths = entries.value.map(en => en.path)
    const fromIdx = paths.indexOf(selectionAnchor.value)
    const toIdx   = paths.indexOf(entry.path)
    if (fromIdx !== -1) {
      const [lo, hi] = fromIdx <= toIdx ? [fromIdx, toIdx] : [toIdx, fromIdx]
      const next = new Set(selected.value)
      for (let i = lo; i <= hi; i++) next.add(paths[i]!)
      selected.value = next
    }
  } else {
    const next = new Set(selected.value)
    if (next.has(entry.path)) next.delete(entry.path)
    else next.add(entry.path)
    selected.value = next
    selectionAnchor.value = entry.path
  }
}

function handleRowClick(entry: Entry, e: MouseEvent) {
  if (e.shiftKey || e.ctrlKey || e.metaKey) selectEntry(entry, e)
  else if (entry.type === 'dir') navigate(entry.path)
}

function handleGridCardClick(entry: Entry, e: MouseEvent) {
  if (e.shiftKey || e.ctrlKey || e.metaKey) selectEntry(entry, e)
  else if (entry.type === 'dir') navigate(entry.path)
  else selectEntry(entry, e)
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

function openPermissions() {
  if (selected.value.size !== 1) return
  permDialogPath.value = [...selected.value][0]!
}

// ── rename ───────────────────────────────────────────────────────────────────
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

// ── upload ───────────────────────────────────────────────────────────────────
async function uploadFiles(files: FileList | File[]) {
  if (!currentPath.value) return
  const dest = currentPath.value

  for (const file of Array.from(files)) {
    const id = crypto.randomUUID?.() ?? Array.from(
      crypto.getRandomValues(new Uint8Array(16)),
      b => b.toString(16).padStart(2, '0')
    ).join('').replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5')

    const totalChunks = Math.max(1, Math.ceil(file.size / CHUNK_SIZE))
    const ac = new AbortController()

    uploads.register({ id, name: file.name, destDir: dest, totalChunks, sentChunks: 0, totalBytes: file.size, sentBytes: 0, bytesPerSec: 0, status: 'uploading' })
    uploads.setAbortController(id, ac)

    try {
      for (let i = 0; i < totalChunks; i++) {
        while (uploads.isPaused(id)) await new Promise(r => setTimeout(r, 200))
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
        uploads.updateProgress(id, i + 1, Math.min(CHUNK_SIZE, file.size - i * CHUNK_SIZE))
      }

      uploads.setStatus(id, 'done')
      if (currentPath.value === dest) refresh()
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

// ── init ─────────────────────────────────────────────────────────────────────
onMounted(async () => {
  dbPlaces.value = (await trpc.place.list.query()) as Place[]
})
</script>

<template>
  <div class="flex h-full" @click="clearSelection">

    <PlacesSidebar
      :places="allPlaces"
      :active-place-id="activePlaceId"
      @select="selectPlace"
    />

    <div class="flex-1 flex flex-col min-w-0">

      <FileToolbar
        :current-path="currentPath"
        :breadcrumbs="breadcrumbs"
        :can-go-up="canGoUp"
        :selected-count="selected.size"
        :selected-entries="selectedEntries"
        :clipboard="clipboard"
        :view-mode="viewMode"
        @go-up="goUp"
        @navigate="navigate"
        @clear-selection="clearSelection"
        @copy="doCopy"
        @cut="doCut"
        @start-rename="startRename"
        @download="downloadSelected"
        @open-permissions="openPermissions"
        @delete="doDelete"
        @create-folder="createFolder"
        @upload-click="fileInput?.click()"
        @paste="doPaste"
        @refresh="refresh"
        @update:view-mode="viewMode = $event"
      />

      <!-- Content area -->
      <div
        class="flex-1 overflow-auto relative"
        @dragenter="handleDragEnter"
        @dragleave="handleDragLeave"
        @dragover.prevent
        @drop.prevent="handleDrop"
      >
        <!-- Drag overlay -->
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

        <!-- Grid view -->
        <FileGridView
          v-else-if="viewMode === 'grid'"
          :entries="entries"
          :selected="selected"
          :renaming-path="renamingPath"
          :rename-value="renameValue"
          @card-click="handleGridCardClick"
          @select-entry="selectEntry"
          @start-rename="startRename"
          @commit-rename="commitRename"
          @cancel-rename="cancelRename"
          @update:rename-value="renameValue = $event"
        />

        <!-- List view -->
        <FileListView
          v-else
          :entries="entries"
          :selected="selected"
          :renaming-path="renamingPath"
          :rename-value="renameValue"
          @row-click="handleRowClick"
          @select-entry="selectEntry"
          @start-rename="startRename"
          @commit-rename="commitRename"
          @cancel-rename="cancelRename"
          @update:rename-value="renameValue = $event"
          @select-all="selectAll"
          @clear-selection="clearSelection"
        />
      </div>
    </div>
  </div>

  <input ref="fileInput" type="file" multiple class="hidden" @change="handleFileInput" />

  <FilePermissionsDialog
    v-if="permDialogPath"
    :path="permDialogPath"
    @close="permDialogPath = null"
  />
</template>
