import { ref, readonly } from 'vue'

export type UploadStatus = 'uploading' | 'paused' | 'done' | 'error' | 'cancelled'

export interface UploadTask {
  id: string
  name: string
  destDir: string
  totalChunks: number
  sentChunks: number
  status: UploadStatus
  error?: string
}

// Module-level — shared across every component that calls useUploads()
const tasks = ref<UploadTask[]>([])
const pausedIds = new Set<string>()
const abortControllers = new Map<string, AbortController>()

export function useUploads() {
  function register(task: UploadTask) {
    tasks.value.push(task)
  }

  function setStatus(id: string, status: UploadStatus, error?: string) {
    const t = tasks.value.find(x => x.id === id)
    if (t) { t.status = status; if (error !== undefined) t.error = error }
  }

  function updateProgress(id: string, sentChunks: number) {
    const t = tasks.value.find(x => x.id === id)
    if (t) t.sentChunks = sentChunks
  }

  function remove(id: string) {
    const i = tasks.value.findIndex(x => x.id === id)
    if (i >= 0) tasks.value.splice(i, 1)
    pausedIds.delete(id)
    abortControllers.delete(id)
  }

  function pause(id: string) {
    pausedIds.add(id)
    setStatus(id, 'paused')
  }

  function resume(id: string) {
    pausedIds.delete(id)
    setStatus(id, 'uploading')
  }

  /** Abort the upload. The chunk loop's catch block sets status to 'cancelled'. */
  function cancel(id: string) {
    pausedIds.delete(id)
    abortControllers.get(id)?.abort()
  }

  function isPaused(id: string) { return pausedIds.has(id) }

  function setAbortController(id: string, ac: AbortController) {
    abortControllers.set(id, ac)
  }

  /** Called in the chunk loop's finally block to release internal refs. */
  function cleanup(id: string) {
    pausedIds.delete(id)
    abortControllers.delete(id)
  }

  return {
    tasks: readonly(tasks),
    register,
    setStatus,
    updateProgress,
    remove,
    pause,
    resume,
    cancel,
    isPaused,
    setAbortController,
    cleanup,
  }
}
